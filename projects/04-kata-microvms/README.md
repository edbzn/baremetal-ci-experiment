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

### Step 4: benchmarks — Kata (`kata-qemu`) vs plain `runc`

All numbers below measured directly on Project 3's real cluster (3
libvirt VMs, 2 vCPU / 3GB RAM workers), not estimated. Scripts in
`benchmarks/`.

| Dimension | runc | Kata (`kata-qemu`) | Delta |
|---|---|---|---|
| Pod cold-start (creation→Ready, 5-run avg) | ~0.90s | ~3.2s | **~3.5x slower** |
| Host-side memory overhead per pod | ~1MB (bare `sleep` process RSS) | ~314MB (QEMU ~264MB + shim ~45MB + 2×virtiofsd ~6MB) | **~300x more** |
| Disk write throughput (200MB `dd`) | 3.8 GB/s | 116 MB/s | **~33x slower** |
| Disk read throughput (200MB `dd`, cached) | 20.9 GB/s | 2.4 GB/s | **~9x slower** |
| Network throughput (iperf3, same-node) | 67.5 Gbit/s | 3.8 Gbit/s | **~18x slower** |
| Failure detection/recovery semantics | Standard kubelet container-exit event | **Identical** — shim reports sandbox failure through the same CRI path | No practical difference |

**Cold start**: measured via `kubectl wait --for=condition=Ready`,
5 runs each. Kata's absolute number (~3.2s) is higher but still
sub-4-second — not the "many seconds/minutes" some assume, though real
enough to matter for a CI system running many short jobs per minute.

**Memory overhead**: measured directly via host-side `ps`/`ctr task ps`
RSS on the same node, both pods pinned there for a fair comparison. The
`kata-qemu` RuntimeClass ships with `overhead.podFixed: {cpu: 250m,
memory: 320Mi}` already configured (by kata-deploy, not something we had
to add) — closely matching the measured ~314MB, confirming the
scheduler's accounting is realistic, not just a nominal placeholder.

**Peak parallelism — the actual constraining resource was CPU, not
memory**: scaled a `kata-qemu` Deployment on the 2 isolated-ci nodes
(2 vCPU / 3GB RAM each) up to 20 replicas. 14 scheduled successfully, 6
stayed `Pending` with `FailedScheduling: ... Insufficient cpu` (not
insufficient memory) — the `250m` CPU overhead per pod against 2 vCPUs
per node hits its ceiling (~8 pods/node) before the ~320Mi memory
overhead does (~9 pods/node on the smaller-memory node observed with real
`free -h` numbers: 175MB/110MB free after 5 pods each). Both resources
matter, but CPU overhead is the tighter constraint on this particular
node shape — a different node's CPU:memory ratio could easily flip which
one binds first, so this is a "measure your own nodes" finding, not a
universal rule.

**Disk I/O — the single largest, most CI-relevant number here**: a
33x write-throughput regression through virtio-fs is the most consequential
finding for actual CI build workloads (checkout, dependency install,
compilation, layer export are all I/O-heavy). This is the concrete,
measured version of the roadmap's own "guest-image management" and
virtio-fs overhead concern — not a vague caveat, a specific multiplier
to weigh against the isolation benefit for any I/O-heavy job class.

**Network I/O**: 18x throughput reduction, from traffic having to
traverse the guest's virtio-net device rather than host-level
veth/bridge/eBPF forwarding. Relevant for CI jobs that push large
artifacts/images or pull large dependencies over the network — directly
compounds with the registry-pull path evaluated in Project 3.

**Failure recovery — no meaningful difference, a genuinely reassuring
result**: killed the container's main process directly for `runc`, and
killed the actual host-side `qemu-system-x86_64` process (simulating a
hypervisor-level crash, not just an in-guest process crash) for Kata.
Both produced the exact same Kubernetes-visible outcome: a `Killing`
event, `Error` status, no restart (governed by `restartPolicy`, same as
any pod). The `containerd-shim-kata-v2` correctly translates a sandbox
failure into the same CRI-level signal kubelet already knows how to
handle — meaning Kata's isolation doesn't complicate the operational
failure-handling story at all, only the resource-cost one.

**Overall picture**: Kata's isolation is real and verified (step 2-3), and
its cost is concrete and now measured rather than assumed — roughly
3-4x on latency-sensitive dimensions (startup, network), an order of
magnitude or more on throughput-sensitive ones (disk, and by extension
anything I/O-bound), and ~300MB fixed memory + 250m fixed CPU per pod
regardless of workload size. None of these costs are prohibitive for a
small number of genuinely high-risk jobs; all of them compound badly if
applied by default to every CI job.

### Follow-up: swapping the hypervisor underneath — `kata-fc` (Firecracker)

Kata's `RuntimeClass` abstraction means the hypervisor is a config choice,
not a re-architecture: `kata-deploy` already installs the `kata-fc`
shim/RuntimeClass alongside `kata-qemu` in the same Helm chart. The
question worth answering with real numbers rather than assumption: does
swapping QEMU for Firecracker's much smaller virtual device model
(~5 virtio devices vs QEMU's broad emulated hardware) actually pay off in
CI-relevant terms, and what does it cost to get working.

**Real gap found and fixed: `kata-fc` needs a devicemapper snapshotter,
which kata-deploy does not provision.** Scheduling a `kata-fc` pod failed
immediately with `FailedCreatePodSandBox: ... snapshotter devmapper was
not found: not found`. Root cause: Firecracker (unlike QEMU) needs its
guest rootfs backed by a real block device, not overlayfs, so kata-deploy
configures containerd's `kata-fc` runtime with `snapshotter = "devmapper"`
— but only writes the containerd-side reference, not an actual pool.
Containerd's own `devmapper` plugin was present but reported `skip`
(config present, `pool_name`/`root_path` empty). Fixed by hand on both
`isolated-ci` workers: created a loopback-backed thin-pool
(`dmsetup create containerd-pool` over two sparse files, data + metadata,
matching containerd's own documented devmapper setup), then set
`root_path`/`pool_name`/`base_image_size` in `/etc/containerd/config.toml`
and restarted containerd (`ctr plugins ls` then shows `devmapper ... ok`).
This is a real, generally-applicable gap for anyone turning on `kata-fc`
from a stock kata-deploy install, not something specific to this cluster.

**Verified genuinely running on Firecracker, not just scheduled**: same
two-check pattern as `kata-qemu` — guest kernel `6.18.35` differs from the
host's `6.8.0-134-generic`, and a real `/firecracker --id ... --config-file
/fcConfig.json` process appears on the host node backing the pod
(`containerd-shim-kata-v2` bridging it into CRI, same as `kata-qemu`, but
notably **no `virtiofsd` processes** — Firecracker's devmapper-backed block
device doesn't need virtio-fs at all).

| Dimension | runc | `kata-qemu` | `kata-fc` | vs `kata-qemu` |
|---|---|---|---|---|
| Pod cold-start (creation→Ready, 5-run avg) | ~0.90s | ~3.2s | ~3.17s | **~roughly even** |
| Host-side memory overhead per pod | ~1MB | ~314MB (QEMU ~264MB + shim ~45MB + 2×virtiofsd ~6MB) | ~197MB (firecracker ~152.7MB + shim ~44.5MB, no virtiofsd) | **~37% less** |
| Disk write throughput (200MB `dd`) | 3.8 GB/s | 116 MB/s | 672 MB/s | **~5.8x faster** |
| Disk read throughput (200MB `dd`, cold) | — | — | 144.5 MB/s | (new measurement, not taken for `kata-qemu`) |
| Disk read throughput (200MB `dd`, cached) | 20.9 GB/s | 2.4 GB/s | ~20.2 GB/s | **~8.4x faster, matches runc** |
| Network throughput (iperf3, same-node) | 67.5 Gbit/s | 3.8 Gbit/s | 3.49 Gbit/s | **~roughly even** |

**Startup and network are a wash** — both are dominated by shared costs
(guest kernel boot time, virtio-net's path through the guest), not by the
device-model difference Firecracker is actually built to minimize.

**Disk and memory are where Firecracker's design pays off, and by a lot**:
the devmapper block-device path replaces virtio-fs's translation overhead
entirely, and cached reads land within measurement noise of bare
`runc` (~20.2 GB/s vs 20.9 GB/s) — a dramatically better result than
`kata-qemu`'s ~9x cached-read regression. Memory drops too, simply from
dropping the `virtiofsd` processes and QEMU's heavier device emulation in
favor of Firecracker's minimal VMM.

**Caveat, not yet measured**: this comparison used the same simple
single-file `dd` workload as the `kata-qemu` benchmark — real CI I/O
patterns (many small files, concurrent git checkouts, layer extraction)
could behave differently under devmapper's thin-provisioning than under
virtio-fs's pass-through-to-host-filesystem model. The devmapper pool
size here (10GB data / 512MB metadata over loopback) is also a lab-scale
setup, not tuned for production throughput or resilience (loopback files
add a layer of indirection a real backing block device wouldn't have).

**Revised takeaway**: for CI job classes that are I/O-heavy (checkout,
dependency install, layer export — flagged in the `kata-qemu` findings
above as the most consequential regression), `kata-fc` is a meaningfully
better default than `kata-qemu` *if* the devmapper snapshotter gap is
fixed first — it keeps Kata's genuine isolation boundary while
removing most of the disk-throughput tax that made `kata-qemu` a hard
sell for I/O-bound jobs specifically. It does not change the
startup/memory/network isolation-tax story in any dramatic way, so the
underlying "measure before defaulting to more isolation" conclusion from
the `kata-qemu` section still stands — this is an argument for *which*
Kata hypervisor to pick once you've decided isolation is warranted, not
an argument that isolation itself is now free.
