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

### Step 3: minimal runner controller

`scripts/runner-controller.sh [queue-dir]`: polls a queue directory every 2s
for `*.task` files (each one a shell command), and for each one creates a
`batch/v1` Job — `backoffLimit: 0` (no retries, fail fast and visibly),
`ttlSecondsAfterFinished: 300` (auto-cleanup so a busy queue doesn't leave
hundreds of `Completed` Jobs around), labeled `app=ci-runner,task=<name>`
for observability. Processed task files move to `queue/.processed/` so a
restarted controller doesn't reprocess them.

This deliberately stands in for a real GitLab/GitHub Actions runner
controller — same fundamental pattern (external queue → one Job → one pod
→ observe result), just without the webhook/API integration a real one
would have.

**Test run:** two tasks queued simultaneously — one that succeeds, one that
`exit 1`s after printing output.
- Controller picked up both within one poll cycle, created
  `ci-job-task-a-<id>` and `ci-job-task-b-<id>`.
- `ci-job-task-a-*`: `STATUS Complete`, logs show `task A running` / `task A
  done`.
- `ci-job-task-b-*`: `STATUS Failed`, pod status `Error`, logs show `task B
  running` (then the `exit 1`). Job's events: `BackoffLimitExceeded` — with
  `backoffLimit: 0` it fails immediately and visibly rather than silently
  retrying, which is the right default for CI (a flaky retry-forever job
  hides real failures).
- Each task genuinely got its own pod, its own log stream, and an
  independent success/failure outcome — the core property this whole
  project is meant to establish before layering node pools, network policy,
  and (in Project 4) microVM isolation on top of the same pattern.

### Step 4: dedicated node pools via labels + taints

Node labeling/tainting itself was done in step 2 (`ci-learning-worker` =
`node-role=trusted-ci` + taint, `ci-learning-worker2` = `node-role=system`,
no taint) — cluster-scoped state, so it persists across namespace/manifest
changes. This step wires the runner controller to actually use it, rather
than leaving the taint/toleration mechanism as an isolated exercise.

- Added to every Job the runner controller creates: a toleration for
  `node-role=trusted-ci:NoSchedule`, a `requiredDuringScheduling`
  nodeAffinity for `node-role=trusted-ci`, and resource
  requests/limits (`100m`/`500m` CPU, `32Mi`/`128Mi` memory, `200Mi`
  ephemeral-storage limit).
- Verified: a queued task's pod landed specifically on
  `ci-learning-worker` (the trusted-ci node), confirmed via `kubectl get
  pods -o wide` and `kubectl describe job` showing the toleration.
- Also fixed a real gap while doing this: the Job's `metadata.labels`
  (`app=ci-runner`) doesn't propagate to the pod unless it's *also* set on
  `spec.template.metadata.labels` — without that, `kubectl get pods -l
  app=ci-runner` finds nothing even though the pod exists and is healthy.
  Worth remembering generally: Job/Deployment/CronJob-level labels and
  pod-template labels are two separate label sets: the controller consults
  `spec.selector` (which must match the pod template's labels) to find its
  own pods; a label on the outer object alone is not visible on the pod.
- This is the concrete mechanism the roadmap's `node-role=system` /
  `trusted-ci` / `isolated-ci` / `large-build` pool design depends on: CI
  Jobs opt in to a pool via toleration+affinity, and nothing without both
  can land on (or accidentally starve) that pool's capacity.

### Step 5: default-deny egress + explicit CI egress

`manifests/09-ci-egress-policy.yaml`: `default-deny-egress` (blanket
`podSelector: {} / policyTypes: [Egress]`, no rules), plus two explicit
allows — DNS (`udp/tcp 53` to any namespace, needed for basically everything)
and the local registry (`ipBlock: 172.21.0.0/16 tcp/5000` — the kind Docker
network's actual subnet, since `ci-registry` is a Docker container outside
the cluster's pod network, not a Kubernetes Service, so it has to be
allowlisted by CIDR rather than podSelector/namespaceSelector).

**Debugging note — a real methodology trap, not just a result:** initial
tests using `kubectl run ... --restart=Never --command -- sh -c '...; echo
done'` (a pod that runs briefly then exits) showed egress *succeeding* even
under `default-deny-egress`, which looked exactly like "kindnet doesn't
enforce egress policy." That conclusion was wrong. Inspecting
kindnet's actual nftables table directly (`docker exec <node> nft list
table inet kindnet-network-policies`) showed the mechanism: the engine
tracks currently-live pod IPs in an nftables set (`podips-v4`/`podips-v6`)
and only queues packets to/from those IPs to its userspace policy decision
process; packets to/from IPs *not* in that set pass through untouched.
Short-lived pods can complete and exit before (or right around) their IP
being added to that live set, so the test request may go out before
enforcement is actually active for that pod — a race, not a policy gap.
Switching to a genuinely long-lived pod (`sleep 300`) and confirming its IP
was actually present in `podips-v4` before testing gave the correct,
consistent result every time.

**Sequence, tested with a long-lived pod and confirmed against the live
nftables state at each step:**
1. Baseline (no egress policy): pod reaches a cross-namespace test Service
   freely.
2. `default-deny-egress` applied: same request now times out (`curl` exit
   28, `http_code=000`) — confirmed against a pod whose IP was verified
   present in the enforcement set.
3. `allow-dns-egress` added: DNS resolution (`nslookup`) succeeds again;
   the registry request still blocked.
4. `allow-registry-egress` added: registry request succeeds
   (`http_code=200`); the original cross-namespace test Service — never
   allowlisted — stays blocked throughout.

**Takeaway for the roadmap's "default-deny and explicit egress paths"
principle:** it's real and enforceable on this stack, but verifying it
requires care — a short-lived CI job pod might genuinely race the policy
engine's own bookkeeping. Worth keeping in mind before trusting any
NetworkPolicy test that uses one-shot pods, and worth re-testing directly
against Kata microVM pods in Project 4, since the enforcement mechanism
(nftables/nfqueue on the host network namespace) interacts with microVM
networking differently than with plain container networking.

### Step 6: Prometheus + Grafana with CI metrics

Installed `kube-prometheus-stack` via Helm into its own `monitoring`
namespace (`monitoring-values.yaml` trims Alertmanager and sets small
resource requests/retention for a local kind cluster — this is a learning
box, not something needing durable long-term metrics storage).

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install kube-prom prometheus-community/kube-prometheus-stack \
  -n monitoring -f monitoring-values.yaml --wait --timeout 5m
```

**What's actually useful out of the box, without writing custom
exporters** — `kube-state-metrics` (Kubernetes object state) + kubelet's
own metrics (scraped automatically) already cover most of the roadmap's
CI-metrics list:

| Roadmap metric | Source | PromQL used |
|---|---|---|
| Failure rate by runner class | `kube_job_status_failed` / `kube_job_status_succeeded` | `sum(kube_job_status_failed{namespace="ci"})` |
| Job queue time | `kube_job_status_start_time - kube_job_created` | `kube_job_status_start_time{namespace="ci"} - on(job_name) kube_job_created{namespace="ci"}` |
| Job startup latency | `kubelet_pod_start_duration_seconds_bucket` (kubelet-reported, includes image pull + sandbox creation) | `histogram_quantile(0.95, sum(rate(kubelet_pod_start_duration_seconds_bucket[5m])) by (le))` |
| Pod scheduling delay | `kube_pod_status_scheduled_time` vs. pod creation | (available; not yet wired into the dashboard — see below) |
| Node disk/memory pressure | `kube_node_status_condition{condition="MemoryPressure"/"DiskPressure"}` | `sum(kube_node_status_condition{...}) by (node)` |

Verified with real data, not just applied-and-assumed: queued 6 jobs via
the runner controller (5 succeeding, 1 deliberately `exit 1`), then queried
Prometheus directly —
`sum(kube_job_status_succeeded{namespace="ci"})` → `5`,
`sum(kube_job_status_failed{namespace="ci"})` → `1`, matching exactly.
Queue time came back `0` for all — expected, since this cluster has far
more spare capacity than these jobs request, so there's no real scheduling
backlog to observe (the metric itself is real and correct; there's just
nothing interesting to see until the cluster is actually under
contention — worth revisiting during the step 7 break-it tests or
Project 3's heavier load).

**Dashboard**: `manifests/10-ci-dashboard-configmap.yaml` — a ConfigMap
labeled `grafana_dashboard: "1"`, auto-discovered by the
`grafana-sc-dashboard` sidecar (confirmed via its logs: `Writing
/tmp/dashboards/ci-jobs.json` → `Dashboards config reloaded`). Panels: job
outcomes, failure rate %, active job count, queue time, pod start duration
p50/p95, pending-pod count, node pressure conditions. Confirmed reachable
end-to-end: `GET /api/search?query=CI` finds it, and querying through
Grafana's own datasource proxy
(`/api/datasources/proxy/uid/prometheus/api/v1/query`) returns the same
real numbers seen directly against Prometheus.

**Access:**
```bash
kubectl port-forward -n monitoring svc/kube-prom-grafana 3000:80
# http://localhost:3000, admin / admin (set in monitoring-values.yaml —
# change this if this cluster is ever exposed beyond localhost)
```

**Gaps / things not done:** no ServiceMonitor was written for the runner
controller itself (it's a bash script, not something that exposes
Prometheus metrics) — the CI metrics here come entirely from Kubernetes
object state (kube-state-metrics) and kubelet, not from instrumenting the
runner. A real CI system (GitLab Runner, Actions Runner Controller, Tekton)
typically exposes its own `/metrics` endpoint with queue depth and
per-pipeline timing that this generic approach can't see. Also didn't wire
scheduling-delay specifically into the dashboard (the raw data
`kube_pod_status_scheduled_time` is there; just didn't build the panel) —
noted here rather than silently skipped.

### Step 7: break things on purpose (Kubernetes context)

Three specific tests from the roadmap, all in `manifests/11-*` through
`manifests/13-*.yaml`.

**Ephemeral storage fill:**
| Setup | Result |
|---|---|
| `resources.limits.ephemeral-storage: 100Mi`, write 500MB | `Warning Evicted — Pod ephemeral local storage usage exceeds the total limit of containers 100Mi`. Kubelet kills the container proactively; pod ends `Error`. Clean, bounded failure. |
| No ephemeral-storage limit at all, write 500MB | Succeeds silently, no eviction, no warning. Host disk usage confirmed via `df -h /` before/after — same underlying mechanism as Project 1 (overlay writable layer = real host disk), just now demonstrated with Kubernetes's own enforcement knob absent. |

Same conclusion as Project 1, now confirmed at the Kubernetes layer:
**ephemeral-storage limits are opt-in, not a default protection** — a CI
Job spec without them can genuinely fill a node's real disk.

**OOM:**
- `resources.limits.memory: 64Mi`, container grows memory past that via a
  `/dev/shm` write loop.
- Pod status: `OOMKilled`. Container `State: Terminated, Reason: OOMKilled,
  Exit Code: 137` — instant, cgroup-level kill, exactly like Docker's
  `--memory` in Project 1, now via `resources.limits.memory`.
- Job ends `Failed` (with `backoffLimit: 0`, no retry). Host `free -h`
  confirmed unaffected (~27Gi still available) — damage contained to the
  one container's cgroup.

**Privileged pod vs. admission policy — the most interesting result of
this step:**
- Re-enabled `pod-security.kubernetes.io/enforce=restricted` on the `ci`
  namespace (removed earlier after the step-2 exercise), then applied a
  Job whose pod template sets `securityContext.privileged: true`.
- **The Job itself was created successfully** — `kubectl apply` only
  printed a `Warning`, not a rejection. This is different from the bare-Pod
  case in step 2, where `kubectl run --overrides=...privileged` was
  rejected outright with an error. The difference: Pod Security admission
  validates **Pods**, and webhook admission review of a **Job** only
  produces an advisory warning about what its pod template *would*
  violate — it does not block Job creation.
- What actually happens: the Job controller then repeatedly tries to
  create the underlying Pod, and *each* attempt is rejected by admission
  (`Warning FailedCreate — pods "privileged-job-<x>" is forbidden: violates
  PodSecurity "restricted:latest": ...`). Observed 5 distinct rejected pod
  names in under 20 seconds, and it does not stop — confirmed the Job
  status stayed `Running 0/1` indefinitely, never transitioning to
  `Failed`, because **`backoffLimit` counts failed pod runs, not
  pod-creation admission rejections** — no pod ever actually starts, so
  there's nothing for `backoffLimit` to count against.
- **Practical implication:** a Job blocked entirely by admission policy
  looks like `STATUS Running, COMPLETIONS 0/1` in `kubectl get jobs` — easy
  to misread as "still working" rather than "permanently and completely
  blocked, retrying forever." The real signal is in `kubectl describe job`
  (`FailedCreate` events) or Prometheus's `kube_job_status_active` staying
  nonzero with `kube_job_status_succeeded`/`failed` never incrementing.
  Worth adding an alert on "Job active > N minutes with zero pod-starts"
  once this moves toward anything more production-like — a naive
  `job failure rate` dashboard panel (as built in step 6) would show
  **nothing wrong at all** for this exact failure mode, since it only
  counts `kube_job_status_failed`, which never gets set here.
