# Project 4 — Kata Containers microVMs

## Goal

Introduce microVM isolation for higher-risk CI jobs without leaving the
Kubernetes pod API. Benchmark against plain `runc` to decide whether the
isolation is worth the operational cost for your workloads.

## Why Kata (and not Firecracker directly)

Kata Containers gives a clean `RuntimeClass` abstraction over multiple
hypervisors (QEMU, Cloud Hypervisor, Firecracker) and integrates with
containerd/Kubernetes as a normal pod. Firecracker-containerd exists but
requires more low-level integration work. Start with Kata; swap the
hypervisor underneath later if needed.

## Prerequisites

- Project 2 or 3 cluster running, containerd as the CRI.
- Nested virtualization available to the cluster nodes (if nodes are VMs
  themselves, they need `/dev/kvm` passed through — check
  `virt-host-validate` and nested KVM support on this host's AMD-V setup).

## Checkpoints before moving on

- What isolates a Kata/microVM pod from the host, concretely, that a plain
  container does not get (separate guest kernel, minimal virtio device
  model, hypervisor as the boundary instead of the host kernel).
- Where the overhead actually comes from (guest kernel boot, virtio-fs/9p
  for volumes, memory ballooning) — this is what the benchmarks in this
  project should make concrete instead of theoretical.

## Steps

1. Install Kata Containers on the worker nodes designated `node-role=isolated-ci`.
2. Add the RuntimeClass:

   ```yaml
   apiVersion: node.k8s.io/v1
   kind: RuntimeClass
   metadata:
     name: kata
   handler: kata
   ```

3. Run a CI Job with `spec.runtimeClassName: kata` and confirm it actually
   runs inside a VM (check for a guest kernel process, not just a container).
4. Benchmark against the same job on plain `runc`:
   - Cold start / pod startup time
   - Peak achievable parallelism (memory overhead per pod)
   - Build duration delta
   - Cache behavior (does the build cache still work well through
     virtio-fs/9p?)
   - Network throughput
   - Failure recovery behavior
5. Decide, in `docs/decisions.md`, which job classes actually warrant Kata
   vs. plain runc, based on the numbers above rather than defaulting to "more
   isolation is always better."
6. Optional: put a rootless BuildKit instance inside the Kata microVM itself
   for the most untrusted build jobs.

## Notes / findings

### Environment

- Built directly on Project 3's kubeadm cluster (3 real libvirt VMs:
  `ci-cp1`, `ci-worker1`, `ci-worker2`), not a fresh cluster.
- **Nested KVM confirmed working, not just enabled**: `/dev/kvm` exists
  and `kvm-ok` reports "KVM acceleration can be used" inside all 3 guest
  VMs (not just the host) — this is the hard prerequisite the roadmap
  flags, and it's real here: Kata's QEMU actually gets hardware
  acceleration two virtualization layers deep (host KVM -> libvirt VM ->
  Kata's own QEMU), not software emulation.
- Labeled `ci-worker1`/`ci-worker2` as `node-role=isolated-ci` per the
  roadmap's node-pool convention (no taint added yet — kata-deploy
  targets all matching nodes by default and doesn't need one).

### Step 1: install Kata Containers

- **Kata's install method changed since the roadmap's example
  (`kubectl apply` of a `kata-deploy.yaml` DaemonSet manifest) — that file
  no longer exists in the kata-containers repo.** Current method is a Helm
  chart: `helm install kata-deploy oci://ghcr.io/kata-containers/kata-deploy-charts/kata-deploy
  --version 4.0.0`. Worth noting since an initial attempt at
  `oci://quay.io/kata-containers/kata-deploy-chart` (a plausible-looking
  but wrong registry path from an AI research pass) 401'd — always verify
  an OCI chart reference against the project's own current docs
  (`kata-containers.github.io/kata-containers/installation/`) rather than
  trusting a remembered/inferred path.
- The chart creates **24 RuntimeClasses** covering every shim variant
  (QEMU, Cloud Hypervisor, Firecracker, Dragonball, plus confidential-
  computing variants for AMD SNP/Intel TDX/NVIDIA GPU passthrough) — only
  `kata-qemu` (the default) is relevant here; the rest are dead weight for
  this setup but harmless.
- **Confirmed direct, real compatibility with containerd 2.2.1's
  `conf.d`-based config**: kata-deploy's own logs showed `Found imports
  directive with /etc/containerd/conf.d in /etc/containerd/config.toml,
  will use conf.d auto-loading` and `Writing to
  "/etc/containerd/conf.d/kata-deploy.toml", pluginid="io.containerd.cri.v1.runtime"`
  — i.e. it correctly detected the same containerd 2.x config layout
  Project 3 had to work around manually for the insecure registry, and
  handled it natively via a drop-in file rather than needing any manual
  intervention. It also automatically restarted containerd and waited for
  the node to report `Ready` again before proceeding — a real, watched
  step, not a fire-and-forget restart.
- Both worker nodes ended up labeled `katacontainers.io/kata-runtime=true`
  by kata-deploy itself (confirmed via `kubectl get nodes --show-labels`)
  — this is the actual node-selector mechanism the `kata-qemu`
  RuntimeClass's default node affinity relies on, applied automatically,
  no manual labeling needed for it specifically.

### Step 2-3: RuntimeClass + verify real VM isolation

Ran a pod with `spec.runtimeClassName: kata-qemu` and proved — not
assumed — that it's genuinely running inside a hardware-accelerated VM,
via two independent, concrete checks:

1. **Guest kernel version mismatch**: the pod's `uname -a` reported
   `Linux kata-test 6.18.35 ...`, while the actual host node
   (`ci-worker1`) is running `6.8.0-134-generic`. A plain container always
   shares the host's exact kernel; a completely different kernel version
   inside the pod is only possible if it's a separate VM with its own
   guest kernel.
2. **Real QEMU process on the host, with hardware acceleration**:
   `ps aux` on the host node showed
   `/opt/kata/bin/qemu-system-x86_64 ... -machine q35,accel=kvm ... -kernel
   /opt/kata/share/kata-containers/vmlinux-6.18.35-200` (kernel version
   matching what the pod reported), plus a
   `containerd-shim-kata-v2` process bridging it into containerd/CRI, and
   two `virtiofsd` processes — the literal virtio-fs daemon handling the
   pod's shared filesystem, mentioned in this project's own checkpoint
   question about where microVM overhead comes from. `accel=kvm`
   specifically confirms hardware-accelerated virtualization, not QEMU's
   slow software TCG fallback — meaning the nested-KVM prerequisite
   genuinely paid off rather than silently degrading to emulation.
