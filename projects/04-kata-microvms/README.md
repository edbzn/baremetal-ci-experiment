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

(fill in as you go — benchmark numbers belong here)
