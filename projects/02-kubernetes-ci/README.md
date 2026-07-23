# Project 2 — Conventional Kubernetes CI (kind/k3d)

## Goal

Run one ephemeral pod per CI job on a multi-node local cluster using plain
`runc`, and understand scheduling and failure isolation before touching
microVMs at all.

## Checkpoints before moving on

You should be able to explain:

- What Kubernetes adds on top of containerd (scheduling, API objects,
  reconciliation loops, kubelet/CRI).
- Where packets travel when one pod connects to another (CNI, kube-proxy or
  eBPF datapath, Service ClusterIP, DNS resolution via CoreDNS).
- What happens when a CI job fills the disk, consumes all memory, or runs
  privileged code, in a Kubernetes context specifically (ephemeral-storage
  limits, OOMKill, eviction, node pressure).

## Steps

1. Stand up a 3-node cluster with `kind` (or `k3d`) — 1 control-plane, 2+
   workers.
2. Learn/exercise in roughly this order:
   - Pods, Deployments, Jobs, CronJobs
   - Requests, limits, scheduling
   - Services, DNS, Ingress
   - ConfigMaps, Secrets, service accounts
   - Volumes, StorageClasses, PVCs
   - RBAC
   - NetworkPolicy
   - Taints, tolerations, affinity, topology spread
   - Pod security / admission control / RuntimeClasses (sets up Project 4)
3. Build a tiny "runner controller": watches a queue (or just a script) and
   creates one Job per CI task, each in its own ephemeral pod.
4. Add resource requests/limits and dedicated node pools via labels+taints:
   `node-role=system`, `node-role=trusted-ci`.
5. Add a default-deny NetworkPolicy plus explicit egress for what CI jobs
   actually need.
6. Add Prometheus + Grafana; track job queue time, startup latency, job
   duration, failure rate, pod scheduling delay.
7. Break things on purpose: a job that fills ephemeral storage, a job that
   OOMs, a job that requests `privileged: true` against an admission policy
   that should reject it.

## Notes / findings

(fill in as you go)
