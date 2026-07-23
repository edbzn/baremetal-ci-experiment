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

### Step 1: 3-node kind cluster

- `kind-config.yaml`: 1 control-plane + 2 workers, plus a
  `containerdConfigPatches` block registering `ci-registry:5000` as a
  containerd registry mirror on every node — this lets pods pull
  `ci-registry:5000/...` images without any per-pod imagePullSecrets or
  insecure-registry flags, since containerd itself is configured to talk
  plain HTTP to that specific host.
- Cluster creation: `kind create cluster --config kind-config.yaml`.
- The local registry from Project 1 (`ci-registry`) needs to be reachable
  from cluster nodes by name. kind creates its own Docker network (`kind`);
  connect the registry container to it: `docker network connect kind
  ci-registry` (idempotent — kind may already auto-attach it in some
  versions, check first with `docker network inspect kind`).
- Verified: `kubectl run sample-app-test --image=ci-registry:5000/sample-app:v1
  ...` successfully pulled and ran the exact image built in Project 1,
  proving the two projects compose (build/registry from P1, scheduling from
  P2) rather than needing a separate image pipeline per project.
- Nodes take a few seconds after `kind create cluster` to go `Ready` (CNI
  install + node registration settling) — `NotReady` immediately after
  creation is expected, not a problem.

### Step 2: core Kubernetes objects

All manifests in `manifests/01-*.yaml` through `manifests/08-*.yaml`, applied
and torn down interactively; results below.

**Pods / Deployments / Jobs / CronJobs** — same image, four different
reconciliation behaviors:
- Bare Pod: deleting it just deletes it. Nothing recreates it — there is no
  controller watching a bare Pod.
- Deployment: deleting one of its pods, the ReplicaSet controller notices
  the replica count dropped below spec and creates a replacement within
  seconds. This *is* what "Kubernetes adds on top of containerd" means
  concretely — a continuous reconciliation loop, not a one-shot run.
- Job: runs to completion once, `backoffLimit` controls retries on failure,
  stays `Completed` afterward (not deleted, not recreated).
- CronJob: fired correctly on schedule (`*/2 * * * *`), created a new Job
  each time.

**Requests/limits/scheduling:**
- A Job requesting resources the cluster can't provide (`cpu: "500"`) sits
  `Pending` forever — not an error, not a crash. `kubectl describe pod`
  shows the precise reason via a `FailedScheduling` event: `0/3 nodes are
  available: 1 node(s) had untolerated taint(s), 2 Insufficient cpu`.
  Requests are what the *scheduler* checks for node fit; limits are what
  the *kernel/cgroup* enforces once running — two different mechanisms
  answering two different questions.

**Services/DNS:**
- ClusterIP Service's `Endpoints`/`EndpointSlice` correctly tracked both
  Deployment pod IPs via the label selector, live.
- `/etc/resolv.conf` inside a pod: `search ci.svc.cluster.local
  svc.cluster.local cluster.local <host-domain>`, `nameserver 10.96.0.10`
  (CoreDNS's ClusterIP), `ndots:5`. This is the literal mechanism behind
  short-name resolution — a bare `sample-app-svc` gets suffix-expanded
  through the search list until one resolves.
- Full loop confirmed: `curl http://echo-server-svc.ci/` → DNS resolves to
  the Service ClusterIP → kube-proxy/kindnet routes to a live pod → real
  HTTP response received.
- **CNI/kube-proxy note**: kind's default is `kindnet` (minimal CNI, pod
  networking only) + standard `kube-proxy`, not eBPF/Cilium. Worth
  remembering going into Project 3, where Cilium replaces this specifically
  so the datapath comparison is visible rather than assumed.

**ConfigMaps/Secrets/ServiceAccounts:**
- One Job demonstrated all three mechanisms at once: `env.valueFrom.
  configMapKeyRef` (env var), volume-mounted ConfigMap (file), volume-
  mounted Secret (file), and the automatically-projected ServiceAccount
  token at `/var/run/secrets/kubernetes.io/serviceaccount/` (`ca.crt`,
  `namespace`, `token`) — the last one is the actual mechanism behind
  in-cluster API access and, later, workload identity.

**Volumes/StorageClasses/PVCs:**
- kind ships `standard` StorageClass (`rancher.io/local-path`,
  `volumeBindingMode: WaitForFirstConsumer`) by default.
- Concretely observed: a PVC created before any consuming pod exists stays
  `Pending` — not stuck/broken, just waiting, because
  `WaitForFirstConsumer` means the provisioner deliberately delays binding
  until it knows which node the pod lands on (so the volume can be
  colocated with it). It binds the instant the consuming Job's pod is
  scheduled. This exact behavior is a common source of "why is my PVC
  stuck" confusion in real clusters if you don't know to look for it.
- `emptyDir` (with `sizeLimit`) is the more relevant pattern for most CI
  jobs — ephemeral scratch space, no StorageClass/provisioner involved,
  gone when the pod is.

**RBAC:**
- A ServiceAccount bound only to a `Role` granting `get/list/watch` on
  `pods` in its own namespace: `kubectl auth can-i ... --as=system:
  serviceaccount:ci:ci-readonly-pods` confirmed `list pods` in `ci` → yes;
  `list pods` in `default` → no; `delete pods` in `ci` → no; `list secrets`
  in `ci` → no; `list nodes` (cluster-scoped) → no. Exactly the intended
  boundary, checked with the actual authorization API rather than assumed
  from the YAML.

**NetworkPolicy:**
- First had to verify kindnet actually *enforces* NetworkPolicy at all —
  historically it didn't (tracked for years in kind#842), until kindnetd
  embedded `sigs.k8s.io/kube-network-policies` as of kind v0.24.0. This
  cluster is on kind v0.32.0, so enforcement is live; confirmed directly
  rather than assumed:
  1. Baseline (no policy): client → target Service succeeds (`ok`).
  2. Apply `podSelector: {} / policyTypes: [Ingress]` (default-deny-all):
     same request times out (`curl` exit 28).
  3. Apply an additional policy allowing ingress from `role=client` pods
     specifically: request succeeds again.
  4. A *third* pod with a different label (`role=not-client`) is still
     blocked — proving the allow rule is genuinely selective, not
     accidentally reopening everything.
- Practical implication for Project 2 step 5 (default-deny + explicit CI
  egress): this mechanism is real and enforced on this cluster, so it's
  worth actually building, not just documenting as aspirational.

**Taints/tolerations/affinity:**
- Labeled/tainted nodes: `ci-learning-worker` got `node-role=trusted-ci`
  (label) + `node-role=trusted-ci:NoSchedule` (taint); `ci-learning-worker2`
  got `node-role=system` (label only, no taint).
- A Job with no toleration landed on `worker2` (the untainted node) —
  taints *repel* by default, no opt-in needed to be excluded.
- A Job with a matching toleration *and* a `nodeAffinity` requiring
  `node-role=trusted-ci` landed specifically on the tainted `worker` node.
  Toleration alone would only permit scheduling there, not force it —
  affinity is what actually pins it. This is the exact mechanism behind
  the roadmap's `node-role=trusted-ci` / `node-role=isolated-ci` pool
  design.

**Pod Security admission / RuntimeClass:**
- Labeling the namespace `pod-security.kubernetes.io/enforce=restricted`
  immediately flagged pre-existing non-compliant pods via an API warning
  (not a rejection — enforcement only applies to *new* pod creation
  attempts).
- A pod with `securityContext.privileged=true` was rejected outright at
  admission time (`403 Forbidden`, before ever reaching a node), with a
  precise per-field list of every violated constraint
  (`allowPrivilegeEscalation`, `capabilities.drop`, `runAsNonRoot`,
  `seccompProfile`).
- A pod setting all four required fields correctly was admitted and ran
  normally — confirming `restricted` is enforceable without breaking a
  correctly-configured trusted-CI-style workload.
- `RuntimeClass` (`node.k8s.io/v1`) API is available on this cluster with
  no instances defined yet — deliberately left as a forward pointer to
  Project 4, since defining a `kata` RuntimeClass with no Kata runtime
  installed would just fail at pod creation, not demonstrate anything.
