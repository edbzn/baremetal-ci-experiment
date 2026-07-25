# Monitoring, logging & alerting — Prometheus + Grafana + Loki (OSS)

Fully self-hosted, no external account/API key needed — the New Relic
OTel-based version considered earlier was replaced with this before
anything was applied, to keep the whole cluster free/self-hosted like
everything else in this project.

## Setup

Live on the cluster now. Installed via
[`cluster/scripts/install-monitoring.sh`](../cluster/scripts/install-monitoring.sh),
which runs three pinned-version Helm installs:

- **`kube-prometheus-stack`** (`cluster/kube-prometheus-stack-values.yaml`)
  — Prometheus, Grafana, Alertmanager, `kube-state-metrics`,
  `node-exporter`, bundled in one chart.
- **`loki`** (`cluster/loki-values.yaml`) — log storage, monolithic
  (`SingleBinary`) mode, filesystem storage on a `local-path` PVC (no
  object storage needed at this cluster's scale).
- **`alloy`** (`cluster/alloy-values.yaml`) — DaemonSet log shipper
  (the current, actively-maintained replacement for Promtail), tails
  every node's `/var/log/pods` and forwards to Loki.

### Node placement — a deliberate choice, not a default

Every component except `node-exporter` and `alloy` (which must run on
every node to be useful) is steered onto the **control-plane nodes**
(4GB RAM each) via a toleration for the `node-role.kubernetes.io/
control-plane:NoSchedule` taint plus a matching `nodeSelector` — not
left to the scheduler's default, and not placed on the `isolated-ci`
workers (2.8GB each, already the site of a real OOM incident under CI
load — see the top-level README's gotchas). This is cluster-infra, not
a CI workload, and shouldn't compete with CI job pods for the same
tight worker capacity.

**Caught during actual install, not assumed**: the
`prometheus-operator` subchart's own pod needs this placement
separately from the Prometheus/Alertmanager custom resources it
manages — it landed on `ci-worker2` the first time this was applied,
missed because only `prometheus.prometheusSpec`/`grafana`/
`alertmanager.alertmanagerSpec` had tolerations set, not
`prometheusOperator` itself. Fixed and now documented in the values
file's own comments.

### Known gotchas, all confirmed directly on this cluster, not guessed

1. **`deploymentMode: SingleBinary` must be set explicitly.** The
   chart's own default is `SimpleScalable`, and setting only
   `singleBinary.*` values without also setting this top-level key
   silently renders **zero actual Loki server workload** — confirmed
   directly: the chart rendered `read`/`write`/`backend` components at
   their default 0 replicas and no StatefulSet/Service for the real
   server existed at all, even though `helm upgrade` reported success.
2. **Loki's Memcached-based `chunksCache`/`resultsCache` and the
   `lokiCanary` are all enabled by default** and immediately failed to
   schedule (`Insufficient memory`) on this cluster's tight capacity.
   Disabled — not worth the memory cost at this log volume.
3. **`/var/log/pods` is root-owned** on this self-managed cluster
   (confirmed directly: `ls /var/log/pods` → `Permission denied` for a
   non-root user on a real worker node) — `alloy`'s
   `securityContext.runAsUser: 0` is required, not optional.
4. **`kubeScheduler`/`kubeControllerManager`/`kubeEtcd` ServiceMonitors
   don't work on this kubeadm cluster and are disabled**:
   - `kube-scheduler`/`kube-controller-manager` bind
     `--bind-address=127.0.0.1` in their static pod manifests
     (`/etc/kubernetes/manifests/`, confirmed directly) — the chart's
     default ServiceMonitors can never reach them from another pod.
   - `kube-etcd`'s scrape target came up `up=0` in Prometheus after a
     real install (confirmed via `up{job="kube-etcd"}`) — etcd's
     metrics listener (`:2381`) is reachable but the scrape itself
     fails, most likely a client-cert mismatch between what the
     chart's `ServiceMonitor` expects and what kubeadm's etcd static
     pod actually presents. Not yet root-caused or fixed — a real fix
     would mean comparing the `ServiceMonitor`'s `tlsConfig` against
     `/etc/kubernetes/pki/etcd/` on each control-plane node.

## Verified working

- Prometheus scrape targets confirmed `up=1` for `kubelet`/cAdvisor and
  Prometheus itself, queried directly
  (`up{job="kube-prometheus-stack-prometheus"}` etc.) rather than
  assumed from pod `Running` status alone.
- Grafana reachable via its MetalLB LoadBalancer IP
  (`http://192.168.122.204`, confirmed `302` redirect-to-login).
- All 5 cluster nodes stayed `Ready` and no other workload was
  disrupted through the full install — checked directly after each
  Helm upgrade, not assumed.

## Alert conditions to configure in Grafana (once dashboards exist)

These target the specific gaps this project has actually hit, not a
generic "alert on everything" list — expressed as PromQL since this is
now a Prometheus/Grafana-native stack, not NRQL:

1. **Worker node memory pressure** — the exact signal that would have
   caught the real OOM incident before it happened (see the top-level
   README's gotchas: `ci-worker2` hit `load average: 114` inside the
   guest with 83MB free out of 2.8GB before going fully unresponsive).
   ```promql
   (node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) < 0.20
   ```
   Scoped to `ci-worker1`/`ci-worker2` via the `instance` label. Alert
   on this being true for 2+ consecutive evaluation periods — catches
   the trend *before* the node goes `NotReady`, not after.

2. **ARC controller down** — a single-replica Deployment; if it dies,
   no new CI runners get created at all, silently, until something
   notices jobs aren't starting.
   ```promql
   kube_deployment_status_replicas_available{deployment="arc-gha-rs-controller"} < 1
   ```

3. **ArgoCD application-controller down** — same single-replica
   StatefulSet risk for GitOps sync.
   ```promql
   kube_statefulset_status_replicas_ready{statefulset="argocd-application-controller"} < 1
   ```

4. **Node NotReady** — direct signal for the exact failure mode this
   project hit (both `ci-worker1`/`ci-worker2` going `NotReady` under
   load, `ci-worker2` needing a hard `virsh reset` to recover).
   ```promql
   kube_node_status_condition{condition="Ready", status="true"} == 0
   ```

5. **Registry pod restarts / unavailability** — single point of
   failure for every job's image pulls.
   ```promql
   increase(kube_pod_container_status_restarts_total{namespace="registry"}[15m]) > 0
   ```

Not yet configured: queue-depth alerting (how many GitHub Actions jobs
are `queued` waiting for a free runner slot) — Prometheus/kube-state-
metrics don't see inside GitHub's own job queue; this needs a custom
metric exported from ARC or GitHub's own API polled separately. Worth
a follow-up once the above are live and proven useful.
