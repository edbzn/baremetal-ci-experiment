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

- [x] Project 1: local container CI
- [x] Project 2: conventional Kubernetes CI (kind/k3d)
- [x] Project 3: rebuild on simulated bare metal
- [x] Project 4: Kata Containers microVMs
- [x] Project 5: disaster exercises

See `projects/*/README.md` for the goal, steps, and checkpoints of each phase.

## Status: all 5 projects complete

The roadmap's core arc — trusted-by-default containers (Project 1) →
conventional Kubernetes CI (Project 2) → real bare-metal-style
infrastructure (Project 3) → microVM isolation for high-risk jobs
(Project 4) → operational credibility through actual failure drills
(Project 5) — is done, with concrete, measured findings at every step
rather than assumptions. Notable threads worth following up on:

- **containerd 2.x has real, non-obvious gaps** relative to older
  guidance (the CRI "transfer service" pull path ignoring `certs.d`
  insecure-registry overrides — see Project 3) — worth rechecking any
  containerd config against the actual running version, not memorized
  patterns.
- **Kata's cost is now measured, not assumed** (Project 4): ~3.5x
  cold-start, ~300MB/250m fixed overhead per pod, ~33x disk write
  slowdown — informs exactly which job classes warrant it.
- **HA control-plane retrofitting is genuinely harder than bootstrapping
  it correctly the first time** (Project 5) — worth deciding topology
  upfront on any future real deployment.
- **NetworkPolicy engines can have live-pod-tracking races** (kindnet in
  Project 2) that produce false negatives in naive tests — always verify
  against a genuinely long-lived pod, not a one-shot test pod.
