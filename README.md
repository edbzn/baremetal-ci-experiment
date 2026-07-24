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
  (`192.168.122.200:5000`, insecure/plain-HTTP), backed by a 10Gi
  `local-path` PVC — not `emptyDir` (previously lost its data at least
  3 separate times across this project's history; verified surviving a
  real pod deletion after the fix).
- **Metrics**: `metrics-server`, `--kubelet-insecure-tls` (stock
  kubeadm's self-signed kubelet serving certs have no IP SANs — the
  correct fix, `serverTLSBootstrap` + a CSR auto-approver, is real
  surgery on an already-running cluster not worth it for this lab).
  `kubectl top` and Headlamp's CPU/memory tiles both work now.
- **GitOps**: ArgoCD, auto-syncing [`cluster/gitops-demo/`](cluster/gitops-demo/)
  from this repo's `main` branch (`automated: {prune: true, selfHeal:
  true}` — pushes here take effect on the cluster automatically).
- **CI**: GitHub Actions Runner Controller, two runner-scale-set
  releases side by side — `arc-runner-set` (plain containerMode,
  `runner`: 500m/1Gi) and `arc-runner-set-dind` (dind mode, `runner`:
  500m/512Mi + a namespace-wide `LimitRange` covering the chart's
  auto-generated `dind`/`init-dind-externals` containers at 500m/1Gi
  each) — both ephemeral, scale-to-zero (`minRunners: 0`) on
  `isolated-ci` nodes. Auth via a narrowly-scoped GitHub App. Real
  memory requests on every container as of a load test that OOM'd a
  worker under concurrent load — see the gotchas below.
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

## UIs

Three web UIs, all reachable directly from this host via MetalLB
LoadBalancer IPs — no port-forwarding needed.

### ArgoCD

- **URL**: `https://192.168.122.201`
- **Login**: `admin` / `kubectl -n argocd get secret
  argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`
- GitOps state — shows the `gitops-demo` Application's live sync/health
  status and resource tree.

![ArgoCD: gitops-demo Application, synced and healthy](docs/screenshots/argocd-gitops-demo.png)

### Headlamp

- **URL**: `http://192.168.122.202`
- **Login**: ServiceAccount token, `cluster-admin`-scoped —
  `kubectl create token headlamp -n headlamp`
- General Kubernetes dashboard (pods, deployments, logs, resource
  usage, live editing) — the actively maintained sig-ui successor to
  the now-archived Kubernetes Dashboard project.

![Headlamp: cluster overview with warning events](docs/screenshots/headlamp-overview.png)

### Hubble UI

- **URL**: `http://192.168.122.203`
- **Login**: none
- Cilium's network-flow observability UI — pick a namespace from the
  dropdown to see live, real packet flows between pods, Services, and
  the outside world (`world`), with verdicts (forwarded/dropped) and
  L7 info where available.

![Hubble UI: live flows between ARC runner pods and the outside world](docs/screenshots/hubble-ui-flows.png)

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
  `NetworkPolicy` port rule** — confirmed the hard way four separate
  times while sweeping NetworkPolicy coverage across the cluster: (1)
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
  misbehaving`; (4) **`hubble-ui`'s backend needs `kube-apiserver`
  egress too**, missed on the first sweep entirely — its backend lists
  Namespaces directly to populate its own cluster/namespace picker, so
  without this the UI loads fine but the picker stays empty, with the
  actual cause (`failed to list *v1.Namespace: ... dial tcp
  10.96.0.1:443: i/o timeout`) visible only in the backend container's
  own logs, not surfaced anywhere in the UI itself. A stale Cilium
  policy revision on the already-running pods also meant the eventual
  correct fix needed a `kubectl rollout restart deployment
  coredns`/`hubble-ui` to actually take effect — re-applying the YAML
  alone wasn't enough, both times this came up.
- **A real concurrent CI load test genuinely OOM'd a worker node** —
  dispatched 20 workflow runs across all 4 workflows at once (both ARC
  scale-sets scaling to their `maxRunners: 3` cap, 6 concurrent
  `kata-fc` pods). Root cause: **every runner pod had zero memory
  requests/limits**, so the scheduler had no way to know 3 concurrent
  microVMs (each demanding real host RSS once a job actually runs, not
  just their ~200MB idle footprint) wouldn't fit on a 2.8GB
  `isolated-ci` worker — it kept stacking them until the node's kernel
  itself started thrashing (`load average: 114.56` *inside* the
  2-vCPU guest, `free -h` showing 83MB available out of 2.8GB, zero
  swap configured at all). The node went genuinely unresponsive —
  `NotReady`, SSH timing out, even the QEMU guest agent disappearing
  on the worse-hit node — and needed a hard `virsh reset`, after which
  containerd's devmapper thin-pool (ephemeral state, per the gotcha
  above) needed manually recreating again before kubelet would start.
  **Fixed at the root**: added real `resources.requests`/`limits` to
  every runner container (`arc-runner-set`'s `runner`: 500m/1Gi;
  `arc-runner-set-dind`'s `runner`: 500m/512Mi) plus a namespace-wide
  `LimitRange` in `arc-runners` (500m/1Gi default) covering the dind
  scale-set's auto-generated `dind`/`init-dind-externals` containers —
  which **cannot** receive `resources` via the chart's own
  `values.yaml` at all (confirmed: `gha-runner-scale-set` 0.14.2 only
  field-merges overrides for the `runner` container; any
  `dind`-named entry in `template.spec.containers`/`initContainers` is
  appended as a raw duplicate instead of merging, failing
  server-side-apply with `duplicate entries for key [name="dind"]` —
  a real, currently-open upstream bug/PR,
  `actions/actions-runner-controller#4567`). Re-ran the exact same
  20-dispatch wave afterward: jobs correctly queued/drained (never
  more than 2 running at once per node) instead of stacking, all 5
  nodes stayed `Ready` throughout, host load stayed under 5 instead of
  spiking past 11. See
  [`cluster/arc-runners-limitrange.yaml`](cluster/arc-runners-limitrange.yaml).

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
