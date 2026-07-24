# Bare-metal k8s cluster

A real `kubeadm` Kubernetes cluster running on nested libvirt/KVM VMs on
this host — not `kind`, not a managed cloud cluster. This is the final,
currently-running infrastructure that the learning roadmap in
[`exercises/`](exercises/README.md) built up incrementally and now runs
on top of: Actions Runner Controller CI, Kata Containers microVMs, and
GitOps via ArgoCD all target this cluster.

For the story of how it got here — the step-by-step roadmap, the
findings, the benchmarks, the disaster drills — see
[`exercises/README.md`](exercises/README.md). This file is about the
cluster itself: what's running, how to operate it, how to rebuild it.

## Topology

| Node | Role | IP | vCPU/RAM |
|---|---|---|---|
| `ci-cp1` | control-plane | `192.168.122.140` | 2 / 4GB |
| `ci-cp2` | control-plane | `192.168.122.74` | 2 / 4GB |
| `ci-cp3` | control-plane | `192.168.122.126` | 2 / 4GB |
| `ci-worker1` | worker (`node-role=isolated-ci`) | `192.168.122.102` | 2 / 3GB |
| `ci-worker2` | worker (`node-role=isolated-ci`) | `192.168.122.109` | 2 / 3GB |

3-node etcd quorum (genuine HA, not a single control-plane node — see
[Project 5](docs/exercises/05-disaster-exercises.md)), fronted by an
HAProxy load balancer (`k8s-lb` Docker container on this host,
`:16443` → round-robin across all 3 API servers,
[`config`](exercises/05-disaster-exercises/haproxy.cfg)). VM disk
images live in `vm-images/` (`.gitignore`d — large binary runtime
state, not source). IPs are static via libvirt DHCP host reservations
(`virsh net-edit default`) — API server addresses and TLS certs are
pinned to these, so a stale DHCP lease will break the cluster after a
host reboot.

## What's installed

- **CNI**: Cilium (eBPF datapath, `kube-proxy` still in place alongside
  it), Hubble + Hubble UI for flow observability.
- **LoadBalancer**: MetalLB, L2 mode.
- **Storage**: `rancher/local-path-provisioner` (dynamic `StorageClass`),
  plus a plain `registry:2` internal container registry
  (`192.168.122.200:5000`, insecure/plain-HTTP). **No longer
  `emptyDir`** — backed by a 10Gi `local-path` PVC as of this session;
  verified surviving a real pod deletion (previously lost its data at
  least 3 separate times across this project's history).
- **Metrics**: `metrics-server`, `--kubelet-insecure-tls` (stock
  kubeadm's self-signed kubelet serving certs have no IP SANs — the
  correct fix, `serverTLSBootstrap` + a CSR auto-approver, is real
  surgery on an already-running cluster not worth it for this lab).
  `kubectl top` and Headlamp's CPU/memory tiles both work now.
- **GitOps**: ArgoCD, auto-syncing [`cluster/gitops-demo/`](cluster/gitops-demo/)
  from this repo's `main` branch (`automated: {prune: true, selfHeal:
  true}` — pushes here take effect on the cluster automatically).
- **CI**: GitHub Actions Runner Controller, two runner-scale-set
  releases side by side — `arc-runner-set` (plain containerMode) and
  `arc-runner-set-dind` (dind mode) — both ephemeral, scale-to-zero
  (`minRunners: 0`) on `isolated-ci` nodes. Auth via a narrowly-scoped
  GitHub App.
- **Isolation**: Kata Containers (`kata-deploy`), `kata-qemu` and
  `kata-fc` (Firecracker) RuntimeClasses available and benchmarked.
  **Both ARC runner-scale-sets run their pods under `kata-fc`** —
  every real CI job gets microVM isolation, not just benchmark pods.
- **TLS/webhooks**: cert-manager (a dependency of the ARC controller's
  own internal webhook, unrelated to GitHub webhooks).
- **NetworkPolicy coverage**: `registry`, `headlamp`, and kube-system's
  5 pod-network workloads (`coredns`, `metrics-server`, `hubble-relay`,
  `hubble-ui`, `kata-deploy`) now have default-deny + explicit allow
  policies — previously zero coverage anywhere outside `arc-runners`
  and ArgoCD's own pods. Every `kube-apiserver`/ClusterIP/node-IP
  egress rule needed a `CiliumNetworkPolicy` with `toEntities`
  (`kube-apiserver`, `host`, `remote-node`) rather than a plain
  `NetworkPolicy` port rule — see the gotchas below.
- **Cluster UI**: [Headlamp](https://headlamp.dev) (the actively
  maintained sig-ui successor to the now-archived Kubernetes
  Dashboard), exposed via a MetalLB LoadBalancer at
  `http://192.168.122.202`, `cluster-admin`-scoped ServiceAccount
  token login (`kubectl create token headlamp -n headlamp`). ArgoCD's
  own UI is separately reachable at `https://192.168.122.201`
  (`admin`/`kubectl -n argocd get secret
  argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64
  -d`).

  ![ArgoCD: gitops-demo Application, synced and healthy](docs/screenshots/argocd-gitops-demo.png)
  *ArgoCD's own resource-tree view of the `gitops-demo` Application —
  synced to the exact commit that scaled it to 3 replicas earlier.*

  ![Headlamp: cluster overview with warning events](docs/screenshots/headlamp-overview.png)
  *Headlamp's cluster overview, genuinely useful the moment it's up:
  this capture's 42 warning events (liveness/readiness probe failures
  on `argocd-server`, `hubble-relay`, `metallb-controller`, a registry
  pod `BackOff`) all trace back to the VM restart earlier this session
  (~45min-old restart counts at capture time) — confirmed stale, not
  live, by checking `kubectl get pods -A` afterward and finding
  everything `Running`. Exactly the "leftover churn from a prior
  incident vs. new breakage" distinction flagged in
  [`docs/exercises/05-disaster-exercises.md`](docs/exercises/05-disaster-exercises.md)
  — worth re-checking directly rather than trusting an event list's
  age at a glance.*

## Operating the cluster

```bash
# start/stop all 5 VMs
sg libvirt -c "virsh start ci-cp1 ci-cp2 ci-cp3 ci-worker1 ci-worker2"
sg libvirt -c "virsh shutdown ci-cp1 ci-cp2 ci-cp3 ci-worker1 ci-worker2"

# kubectl/helm access
export KUBECONFIG=cluster/.kube/config   # fetched from a control-plane VM's /etc/kubernetes/admin.conf

# recreate the HAProxy load balancer if its container was removed
docker run -d --name k8s-lb --network host --restart unless-stopped \
  -v "$(pwd)/exercises/05-disaster-exercises/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro" \
  haproxy:2.9
```

Known gotchas, both real and previously hit:
- **Devicemapper thin-pool for `kata-fc` does not survive a VM
  reboot** (loopback + `dmsetup` state is ephemeral) — recreate from
  the still-intact `/var/lib/containerd/devmapper/{data,meta}` files on
  each worker, then `systemctl restart containerd`. See
  [`docs/exercises/04-kata-microvms.md`](docs/exercises/04-kata-microvms.md).
- **DiskPressure on the `isolated-ci` workers** was a recurring problem
  until the VM disks were grown 20GB→40GB (live `virsh blockresize` +
  `growpart`/`resize2fs`, no downtime needed). See
  [`docs/exercises/05-disaster-exercises.md`](docs/exercises/05-disaster-exercises.md).
- **A GitHub repo rename breaks ARC silently** — `githubConfigUrl` in
  the runner-scale-set Helm values has to match the repo's current
  name exactly, or every runner registration 404s and the listener pod
  crash-loops indefinitely with no scheduling failure surfaced
  anywhere else.
- **`kata-fc`'s `EmptyDir` volumes default to a tiny (~400MB) RAM-backed
  guest tmpfs, not real disk** — Firecracker has no virtio-fs support,
  so Kata's default `emptydir_mode="shared-fs"` silently falls back
  instead of erroring. Any pod with real `EmptyDir` needs (e.g. ARC's
  `dind` containerMode) fails with `No space left on device`. Fix:
  `emptydir_mode="block-plain"` in `configuration-fc.toml` on each
  worker, plus a pod-level `securityContext.fsGroup` matching the
  container's UID (the fresh block device mounts root-only otherwise).
  See [`docs/exercises/04-kata-microvms.md`](docs/exercises/04-kata-microvms.md).
- **ARC's listener pod can hang silently on a transient network
  blip** — no crash, no restart, `1/1 Ready` throughout, but it stops
  polling GitHub for jobs entirely, so every dispatched job sits
  `queued` forever. The container ships with no
  liveness/readiness probe at all. Fix: `kubectl delete pod` on the
  listener (its Deployment recreates it immediately). See
  [`docs/exercises/06-github-actions-arc.md`](docs/exercises/06-github-actions-arc.md).
- **Any NetworkPolicy egress rule aimed at a ClusterIP or a real node
  IP needs `CiliumNetworkPolicy` + `toEntities`, not a plain
  `NetworkPolicy` port rule** — confirmed the hard way three times
  while sweeping NetworkPolicy coverage across the cluster: (1)
  `kube-apiserver` access (`10.96.0.1:443`) is DNAT'd before standard
  port-matching runs, so a `namespaceSelector`/port rule silently
  matches nothing; (2) kubelet-scrape traffic to real node IPs
  (`metrics-server` → `:10250`) is classified by Cilium's identity
  model as in-cluster and isn't matched by a plain `ipBlock:
  0.0.0.0/0` either — needs `toEntities: [host, remote-node]`; (3)
  **CoreDNS's own upstream-forwarder egress is easy to forget
  entirely** — a `namespaceSelector: {}` DNS-egress rule only covers
  in-cluster queries, breaking *all* external-name resolution
  cluster-wide (`api.github.com`, etc.) the moment it's applied,
  surfaced as `ARC` failing to reach `api.github.com` with `server
  misbehaving`. A stale Cilium policy revision on the already-running
  CoreDNS pods also meant the eventual correct fix needed a
  `kubectl rollout restart deployment coredns` to actually take
  effect — re-applying the YAML alone wasn't enough.

## Rebuilding from scratch

```bash
cluster/scripts/provision-vms.sh ci-cp1 ci-cp2 ci-cp3 ci-worker1 ci-worker2
cluster/scripts/install-k8s-prereqs.sh   # containerd + kubeadm/kubelet/kubectl, run over SSH
# kubeadm init / kubeadm join, then:
cluster/scripts/configure-insecure-registry.sh 192.168.122.200:5000
cluster/scripts/etcd-snapshot.sh 192.168.122.140   # periodic backup, see docs/exercises/05-disaster-exercises.md
```

Full step-by-step provisioning detail (cloud-init, kubeadm preflight
gaps, Cilium/MetalLB install, HA retrofit) is in
[`docs/exercises/03-bare-metal-simulation.md`](docs/exercises/03-bare-metal-simulation.md)
and [`docs/exercises/05-disaster-exercises.md`](docs/exercises/05-disaster-exercises.md).

## Docs

- [`exercises/README.md`](exercises/README.md) — the full learning
  roadmap this cluster grew out of, exercise by exercise.
- [`docs/concepts.md`](docs/concepts.md) — checkpoint questions
  (isolation boundaries, packet paths, VM-vs-container security).
- [`docs/decisions.md`](docs/decisions.md) — lightweight ADRs for every
  non-obvious call made along the way.
- [`docs/exercises/`](docs/exercises/) — full per-project write-ups:
  findings, benchmarks, evidence.
