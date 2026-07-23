# Bare-metal CI with microVMs — learning roadmap

A hands-on progression from trusted-by-default container CI, through
conventional Kubernetes CI, to real bare-metal-style infrastructure,
microVM isolation for high-risk jobs, real GitHub Actions integration, and
operational credibility through actual destructive drills. Every finding
below was measured or reproduced directly on real infrastructure (real
libvirt VMs, a real kubeadm cluster, a real GitHub repo) rather than
assumed — see each project's README for the full evidence.

**Guiding principle:** build a boring, recoverable Kubernetes CI platform
first; add microVM isolation only to the runner classes that actually need
the stronger boundary; and never trust "should work" — verify.

## Layout

```
projects/
  01-local-container-ci/     rootless BuildKit + registry, DinD/DooD security comparison
  02-kubernetes-ci/           kind cluster: scheduling, RBAC, NetworkPolicy, metrics
  03-bare-metal-simulation/   kubeadm on real libvirt VMs, Cilium, MetalLB, GitOps
  04-kata-microvms/           Kata Containers RuntimeClass, measured vs. runc
  05-disaster-exercises/      HA control plane + destructive chaos drills
  06-github-actions-arc/      real GitHub Actions CI on the cluster + a security drill
docs/
  concepts.md                 the "can you explain X" checkpoint questions
  decisions.md                lightweight ADRs for non-obvious choices made along the way
```

## Project 1 — Local container CI

[`projects/01-local-container-ci/`](projects/01-local-container-ci/README.md)

Rootless BuildKit + a local OCI registry, wired into a minimal CI runner
script ([`scripts/run-ci-job.sh`](projects/01-local-container-ci/scripts/run-ci-job.sh)):
build → registry-cache import/export → locked-down smoke test → artifact
record. Then a deliberate "break it" pass (disk fill, OOM, privileged vs.
default capabilities) and a side-by-side [DinD vs. DooD vs. rootless
BuildKit security comparison](projects/01-local-container-ci/dind-experiment/README.md).

**Know this:**
- Rootless BuildKit needs a genuinely relaxed `kernel.apparmor_restrict_unprivileged_userns`
  sysctl on modern Ubuntu — the commonly-cited host AppArmor-profile fix
  does **not** apply to containerized processes (see
  [`docs/decisions.md`](docs/decisions.md)).
- **Docker-outside-of-Docker (mounting the host's `docker.sock`) was
  proven to grant full host filesystem access with zero special container
  flags** — a live, reproduced demonstration, not a theoretical warning.
- Docker-in-Docker is genuinely isolated from the host's real containers,
  but still requires the same `--privileged` grant that hands out full
  host device/capability access — it doesn't solve the isolation problem
  on its own.

## Project 2 — Conventional Kubernetes CI

[`projects/02-kubernetes-ci/`](projects/02-kubernetes-ci/README.md)

A 3-node `kind` cluster wired to Project 1's registry. Works through
Pods/Deployments/Jobs/CronJobs, scheduling, Services/DNS, RBAC,
NetworkPolicy, taints/tolerations, Pod Security admission, a
[queue-driven runner controller](projects/02-kubernetes-ci/scripts/runner-controller.sh),
a default-deny egress policy, and Prometheus/Grafana CI metrics
([`monitoring-values.yaml`](projects/02-kubernetes-ci/monitoring-values.yaml)).

**Know this:**
- **kindnet's NetworkPolicy engine tracks live pod IPs and only enforces
  against tracked ones** — a short-lived test pod can race the engine's
  own bookkeeping and produce a false "policy doesn't work" result.
  Always verify against a genuinely long-lived pod.
- A Job blocked entirely by Pod Security admission shows as `STATUS
  Running, COMPLETIONS 0/1` **forever**, retrying pod creation
  indefinitely — `backoffLimit` never fires because it counts failed pod
  *runs*, not admission rejections. A naive failure-rate dashboard panel
  would show nothing wrong at all for this exact failure mode.

## Project 3 — Bare-metal simulation (real VMs, not containers)

[`projects/03-bare-metal-simulation/`](projects/03-bare-metal-simulation/README.md)

A real `kubeadm` cluster on 3 (later 5, see Project 5) libvirt/KVM VMs —
provisioned via [`scripts/provision-vms.sh`](projects/03-bare-metal-simulation/scripts/provision-vms.sh) +
[cloud-init](projects/03-bare-metal-simulation/cloud-init/user-data.tmpl.yaml).
Adds Cilium ([`cilium-values.yaml`](projects/03-bare-metal-simulation/cilium-values.yaml)),
MetalLB L2 mode ([`metallb-config.yaml`](projects/03-bare-metal-simulation/metallb-config.yaml)),
an internal container registry ([`registry.yaml`](projects/03-bare-metal-simulation/registry.yaml)),
a real etcd snapshot/restore drill, and Argo CD GitOps
([`argocd-application.yaml`](projects/03-bare-metal-simulation/argocd-application.yaml)).

**Know this:**
- **containerd 2.x's CRI "transfer service" pull path silently ignores
  `certs.d`/`hosts.toml` insecure-HTTP registry overrides** — `ctr` pulls
  directly work fine, but kubelet/`crictl` pulls keep forcing HTTPS
  regardless. Fix: `use_local_image_pull = true` under
  `[plugins.'io.containerd.cri.v1.images']`, reverting to the classic
  resolver (see [`scripts/configure-insecure-registry.sh`](projects/03-bare-metal-simulation/scripts/configure-insecure-registry.sh)).
  Most existing guidance predates containerd 2.x and will hit this
  silently.
- Killing a real node (`virsh destroy` + `undefine`) and replacing it is
  routine with the same scripts used for initial provisioning — but the
  registry's data was **permanently lost**, because it used `emptyDir`,
  not a PVC. A concrete, not theoretical, argument for persistent storage
  on anything meant to survive node loss.
- etcd snapshot/restore was verified with before/after marker
  ConfigMaps, not just "the cluster came back up" — proving the restore
  rolled back to *exactly* the snapshot's point in time.

## Project 4 — Kata Containers microVMs

[`projects/04-kata-microvms/`](projects/04-kata-microvms/README.md)

Kata installed via the current Helm-based `kata-deploy` method (the
roadmap's original `kubectl apply` DaemonSet example no longer exists —
Kata's install process changed). Verified genuine VM isolation (a
`kata-qemu` pod reports a completely different kernel than its host node,
and the host process list shows a real `qemu-system-x86_64 -machine
q35,accel=kvm` process), then benchmarked against `runc` with a
[startup-time script](projects/04-kata-microvms/benchmarks/measure-startup.sh).

**Know this — the actual measured cost, not an assumption:**

| Dimension | runc | Kata (`kata-qemu`) |
|---|---|---|
| Cold start | ~0.9s | ~3.2s (**~3.5x**) |
| Memory overhead / pod | ~1MB | ~314MB (**~300x**) |
| Disk write throughput | 3.8 GB/s | 116 MB/s (**~33x slower**) |
| Network throughput | 67.5 Gbit/s | 3.8 Gbit/s (**~18x slower**) |
| Failure recovery | standard | **identical** — no practical difference |

- The actual parallelism ceiling on 2-vCPU nodes was **CPU overhead**
  (`250m` fixed per pod), not memory — the opposite of the naive
  assumption. Measure your own nodes; don't assume which resource binds
  first.
- Decision recorded in [`docs/decisions.md`](docs/decisions.md): `runc`
  stays the default; Kata is reserved for a narrow class of genuinely
  high-risk jobs, based on this measured cost.

**Follow-up: swapped the hypervisor underneath Kata — `kata-fc`
(Firecracker) vs `kata-qemu`.** Same `RuntimeClass` abstraction, same
`containerd-shim-kata-v2`, just a different VMM underneath — kata-deploy
already installs `kata-fc` alongside `kata-qemu` in one Helm chart.
Verified genuinely running on Firecracker the same way (distinct guest
kernel, a real `/firecracker` host process, no `virtiofsd` needed at
all), then re-ran the same benchmark comparison:

| Dimension | `kata-qemu` | `kata-fc` |
|---|---|---|
| Cold start | ~3.2s | ~3.17s (**roughly even**) |
| Memory overhead / pod | ~314MB | ~197MB (**~37% less**) |
| Disk write throughput | 116 MB/s | 672 MB/s (**~5.8x faster**) |
| Disk read throughput (cached) | 2.4 GB/s | ~20.2 GB/s (**matches runc**) |
| Network throughput | 3.8 Gbit/s | 3.49 Gbit/s (**roughly even**) |

- **Real gap found and fixed, not specific to this cluster**: `kata-fc`
  needs a devicemapper snapshotter (Firecracker's guest rootfs needs a
  real block device, not overlayfs) that kata-deploy configures a
  *reference* to but never actually provisions — scheduling failed with
  `snapshotter devmapper was not found`. Fixed by hand-building a
  loopback-backed `dmsetup` thin-pool and wiring it into containerd's
  config on both workers.
- Firecracker's minimal device model pays off exactly where you'd expect
  — disk I/O and memory — while startup and network stay roughly even
  with `kata-qemu` (both dominated by shared costs: guest kernel boot,
  the virtio-net path). For I/O-heavy CI job classes (checkout,
  dependency install, layer export), `kata-fc` is a meaningfully better
  default than `kata-qemu` once the devmapper gap is fixed — it doesn't
  make Kata's isolation free, just cheaper on the dimension that hurt
  most.

## Project 5 — Disaster exercises

[`projects/05-disaster-exercises/`](projects/05-disaster-exercises/README.md)

Expanded Project 3's single-control-plane cluster to a genuine 3-node
etcd quorum (HAProxy LB, live cert regeneration, `kubeadm-config`
patching), then ran real destructive drills: kill 1-of-3 control-plane
nodes, fill a worker's disk mid-workload, cut a node's network at the
hypervisor level, rotate a ServiceAccount credential live, and contain a
"compromised" CI job mid-run.

**Know this:**
- Retrofitting HA onto an already-running cluster is real, fiddly
  surgery (TLS SAN regeneration, a silent `ufw` firewall gap) — deciding
  the control-plane topology *before* `kubeadm init` would have avoided
  all of it.
- Losing 1-of-3 control-plane nodes caused **zero data-plane impact**,
  but a load balancer's own health-check interval (~2s) still caused a
  brief, real, client-visible write failure — "the control plane
  survived" and "clients saw zero disruption" are different claims.
- **A naive delete-then-create credential rotation caused a real,
  measured ~24-second outage** — the old Secret is invalidated before a
  replacement exists. Create-then-delete is the correct order.
- "Node temporarily unreachable" (self-heals automatically, zero data
  loss) and "node actually gone" (needs full reprovisioning) look
  identical at first (`NotReady`) but need very different responses —
  confirmed by directly comparing both failure modes back to back.

## Project 6 — Real GitHub Actions CI on the cluster

[`projects/06-github-actions-arc/`](projects/06-github-actions-arc/README.md)

Wires a real GitHub repo to Actions Runner Controller (ARC) running on
Project 3's cluster, authenticated via a narrowly-scoped GitHub App (no
webhooks — the listener long-polls GitHub outbound, which is exactly what
a no-public-ingress cluster needs). Proved end-to-end with a real `git
push`: GitHub's own captured log output shows the exact kernel/OS of our
cluster nodes, not a hosted runner. See the live workflows:
[`self-hosted-ci.yml`](.github/workflows/self-hosted-ci.yml) and
[`security-sandbox-drill.yml`](.github/workflows/security-sandbox-drill.yml).

Also ran a [security sandbox-escape drill](projects/06-github-actions-arc/security-drill/README.md) —
a real CI job attempting host file access, container-runtime socket
access, privilege escalation, process-namespace escape, RBAC abuse, and
cross-namespace network reach.

**Know this:**
- Force-killing a runner pod mid-job doesn't fail the run outright — ARC
  auto-replaces it — but the **entire job restarts from scratch**, no
  mid-step resume. Real cost for long-running jobs, and infrastructure
  instability that would just reschedule a stateless pod instead throws
  away real CI work when it hits a runner specifically.
- **Container-level isolation held on every probe**: zero effective
  capabilities, no host filesystem/device exposure, no working privilege
  escalation, genuine PID namespace isolation, RBAC correctly denied via
  ARC's own deliberately-named `-no-permission` ServiceAccount.
- **But the CI runner could freely reach the internal container
  registry and any other cluster service** — no NetworkPolicy protected
  it by default. Fixed with default-deny egress
  ([`arc-runner-egress-policy.yaml`](projects/06-github-actions-arc/security-drill/arc-runner-egress-policy.yaml)).
- **Getting that fix right took two tries**: a plain `NetworkPolicy
  ipBlock` rule for the Kubernetes API server's ClusterIP silently failed
  on Cilium — CIDR selectors match traffic *after* Cilium's own
  datapath has already DNAT'd Service-ClusterIP destinations to a real
  backend Pod IP, so the rule never matches anything (a multi-minute
  hang, not a clean error). The documented fix is Cilium's `toEntities:
  kube-apiserver` selector via a `CiliumNetworkPolicy` — verified working
  afterward with the registry cleanly blocked in 3 seconds while the API
  server and internet access stayed intact.
- **All three `containerMode` options measured, not assumed** (also in
  the [security drill](projects/06-github-actions-arc/security-drill/README.md)):
  `dind` mode gets `docker build` for free via a sidecar that's
  hardcoded `privileged: true` with no way to reduce it — a real
  (user-approved) `--privileged --pid=host` + `nsenter -t 1` escape
  attempt against it stayed contained (returned the *pod's* own
  hostname/OS, not the real node's — confirmed by comparing directly
  against the actual node over SSH), but the structural gap (an
  always-privileged container in the pod) is real regardless.
  `kubernetes` mode has no privileged container anywhere in the pod at
  all — genuinely the safer default — but as a direct, confirmed
  consequence (`failed to connect to the docker API ... no such file or
  directory`) has **no way to build images without separately
  provisioning a build service**, exactly the tradeoff Project 1's
  rootless-BuildKit recommendation already argued for.

## Docs

- [`docs/concepts.md`](docs/concepts.md) — the roadmap's own "can you
  explain X" checkpoint questions (isolation boundaries, packet paths,
  VM-vs-container security), as a running self-check.
- [`docs/decisions.md`](docs/decisions.md) — lightweight ADRs for every
  non-obvious call made along the way, each with *why* and *revisit if*.

## Threads worth following up on

- DinD *inside* a Kata microVM — would the VM boundary make DinD's
  convenience safe for genuinely untrusted build jobs? Flagged in
  Project 1, not yet tested.
- MetalLB BGP mode (only L2 mode was exercised).
- Wiring a real rootless-BuildKit service alongside `kubernetes`-mode ARC
  runners, to get genuinely privileged-sidecar-free image builds — the
  natural next step now that both `dind` and `kubernetes` mode have been
  measured on their own.
- A cluster-wide NetworkPolicy sweep — Project 6's security drill found
  and fixed the gap for `arc-runners` specifically, but other namespaces
  (e.g. `registry` itself) likely have the same gap in the other
  direction.
