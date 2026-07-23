# Bare-metal CI with microVMs — learning roadmap

Goal: build a working intuition for CI-on-Kubernetes, then bare-metal
Kubernetes, then microVM isolation (Kata Containers) for untrusted CI jobs.
Firecracker/production bare metal come last, not first.

Guiding principle: build a boring, recoverable Kubernetes CI platform first;
add microVMs only to the runner classes that actually need the stronger
isolation boundary.

## Host environment (this machine)

- 32 cores, 60GB RAM, KVM available (AMD-V), 1.2TB free disk, Docker installed.
- Enough to run kind/k3d multi-node clusters, Kata Containers with QEMU, and
  even nested VMs for the "bare metal" simulation phase, all locally.

## Layout

```
projects/
  01-local-container-ci/     containerd/Docker CI runner + rootless BuildKit + registry
  02-kubernetes-ci/          kind/k3d multi-node cluster, ephemeral Job pods, RBAC, NetworkPolicy
  03-bare-metal-simulation/  same cluster rebuilt on "disposable machines" (nested VMs), Cilium, MetalLB, GitOps
  04-kata-microvms/          Kata Containers RuntimeClass, benchmarks vs runc
  05-disaster-exercises/     chaos drills: node loss, disk fill, etcd restore, credential rotation
docs/
  concepts.md                running notes on the "can you explain X" checkpoints
  decisions.md               lightweight ADRs as tools/approaches are chosen
```

## Study allocation (per the original plan)

| Area | Effort |
|---|---|
| Linux, networking, container internals | 25% |
| Kubernetes workloads, scheduling, security | 30% |
| Bare-metal operations | 20% |
| CI runner behavior and image building | 15% |
| MicroVMs and Kata | 10% |

## Progress

- [ ] Project 1: local container CI
- [ ] Project 2: conventional Kubernetes CI (kind/k3d)
- [ ] Project 3: rebuild on simulated bare metal
- [ ] Project 4: Kata Containers microVMs
- [ ] Project 5: disaster exercises

See `projects/*/README.md` for the goal, steps, and checkpoints of each phase.
