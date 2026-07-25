# Monitoring & alerting — OpenTelemetry → New Relic

## Setup

See [`cluster/scripts/install-monitoring.sh`](../cluster/scripts/install-monitoring.sh)
and the values files it references
(`cluster/kube-state-metrics-values.yaml`,
`cluster/otel-collector-daemonset-values.yaml`,
`cluster/otel-collector-cluster-values.yaml`). Staged, not yet applied
— needs a real New Relic license key first (copy
`cluster/newrelic-license-secret.yaml.example` to
`cluster/newrelic-license-secret.yaml`, fill in the key, gitignored so
it never gets committed).

Architecture: two `open-telemetry/opentelemetry-collector` Helm
releases (vendor-neutral chart, not New Relic's own `nri-bundle`, so
this stays swappable to any other OTLP backend later) —

- **`otel-collector-node`** (DaemonSet): kubelet/cAdvisor metrics
  (`kubeletMetrics` preset) + pod logs (`logsCollection` preset, a
  `filelog` receiver watching `/var/log/pods`).
- **`otel-collector-cluster`** (Deployment, 1 replica): scrapes
  `kube-state-metrics` for object-level state (Deployment/ReplicaSet
  health, pod scheduling state) the kubelet-only view can't see.

Both export via OTLP/HTTP to `otlp.nr-data.net` (US) or
`otlp.eu01.nr-data.net` (EU — confirm account region before
deploying), `api-key` header carrying the license key.

**Known gotcha, already accounted for in the daemonset values**: the
`filelog` receiver needs root to read `/var/log/pods` on a self-managed
cluster — confirmed directly (`ls /var/log/pods` returns `Permission
denied` for a non-root user on our own worker nodes) — hence
`securityContext.runAsUser: 0` in
`otel-collector-daemonset-values.yaml`.

## Alert conditions to configure in New Relic (NRQL, once data is flowing)

These target the specific gaps this project has actually hit, not a
generic "alert on everything" list:

1. **Worker node memory pressure** — the exact signal that would have
   caught the real OOM incident before it happened (see the top-level
   README's gotchas: `ci-worker2` hit `load average: 114` inside the
   guest with 83MB free out of 2.8GB before going fully unresponsive).
   ```sql
   SELECT average(k8s.node.memory.available) FROM Metric
   WHERE k8s.node.name IN ('ci-worker1', 'ci-worker2')
   FACET k8s.node.name
   ```
   Alert threshold: falling below ~20% of allocatable for 2+ consecutive
   evaluation periods — catches the trend *before* the node goes
   `NotReady`, not after.

2. **ARC controller down** — a single-replica Deployment; if it dies,
   no new CI runners get created at all, silently, until something
   notices jobs aren't starting.
   ```sql
   SELECT latest(k8s.deployment.available) FROM Metric
   WHERE k8s.deployment.name = 'arc-gha-rs-controller'
   ```
   Alert: `available < 1`.

3. **ArgoCD application-controller down** — same single-replica
   StatefulSet risk for GitOps sync.
   ```sql
   SELECT latest(k8s.statefulset.ready_replicas) FROM Metric
   WHERE k8s.statefulset.name = 'argocd-application-controller'
   ```
   Alert: `ready_replicas < 1`.

4. **Node NotReady** — direct signal for the exact failure mode this
   project hit (both `ci-worker1`/`ci-worker2` going `NotReady` under
   load, `ci-worker2` needing a hard `virsh reset` to recover).
   ```sql
   SELECT latest(k8s.node.condition.ready) FROM Metric
   FACET k8s.node.name
   ```
   Alert: condition != `True` for any `isolated-ci` node.

5. **Registry pod restarts / unavailability** — single point of
   failure for every job's image pulls.
   ```sql
   SELECT sum(k8s.pod.restarts) FROM Metric
   WHERE k8s.namespace.name = 'registry'
   ```

Not yet configured: queue-depth alerting (how many GitHub Actions jobs
are `queued` waiting for a free runner slot) — this needs a custom
metric exported from ARC or GitHub's own API polled separately; OTel's
Kubernetes-native metrics don't see inside GitHub's job queue. Worth a
follow-up once the above are live and proven useful.
