# Security drill — sandbox-escape probes from a real CI job

Ran a battery of read-only host/cluster-access probes as a **real GitHub
Actions job**, executed by the ARC runner on Project 3's cluster
(`.github/workflows/security-sandbox-drill.yml`, triggered manually via
`workflow_dispatch`). This tests the *current, default* ARC runner
configuration (`containerMode.type: ""`, no explicit `securityContext`,
`nodeSelector: node-role: isolated-ci`) — not a hardened configuration,
deliberately, so the results show what's actually happening by default
before any explicit lockdown.

## Results

| Probe | Result | Verdict |
|---|---|---|
| Effective capabilities (`CapEff`) | `0000000000000000` — zero | ✅ Contained. Bounding set (`CapBnd`) still shows the normal unprivileged default set, but nothing is actually *effective*. |
| Host filesystem markers (`/host`, `/rootfs`, `/var/lib/kubelet`, `/etc/kubernetes`) | None present | ✅ Contained. No hostPath mounts exposing host paths. |
| `/etc/shadow` | `Permission denied` | ✅ Contained (this is the container's *own* shadow file, and even that's inaccessible to the `runner` user). |
| Host block devices under `/dev` | None visible | ✅ Contained. No `--privileged`-style device exposure (matches Project 1's findings on what privileged grants vs. what a default container gets). |
| Docker/containerd/CRI-O sockets | None present | ✅ Contained. No accidental host-socket mount (the Project 1 DinD/DooD danger). |
| `mount` (needs `CAP_SYS_ADMIN`) | Blocked (`Read-only file system`) | ✅ Contained. |
| `modprobe` (needs `CAP_SYS_MODULE`) | Not available | ✅ Contained. |
| Write to `/proc/sys/kernel/printk` | Blocked (`Read-only file system`) | ✅ Contained. |
| `NoNewPrivs` | `0` (not set) | ⚠️ **Gap** — see below. |
| Process visibility (`ps aux`) | 8 processes total, all belonging to the job itself | ✅ Contained. Genuine PID namespace isolation — no visibility into other pods/containers on the shared node. |
| ServiceAccount token | Mounted (`arc-runner-set-gha-rs-no-permission`) | Expected — auto-mounted by default. |
| `get pods`/`list secrets`/`get nodes`/`list namespaces` via the mounted token | All `403` | ✅ Contained. ARC's own default ServiceAccount is deliberately named `-no-permission` and has zero RoleBindings — genuinely zero API permissions, not just "low." |
| Kubernetes API server reachability (`https://kubernetes.default.svc`) | Reachable (unauthenticated `/version` endpoint responds) | Expected/benign — `/version` is intentionally unauthenticated on most clusters; the actual authorization gate (above) is what matters and held. |
| kubelet read-only port (10255) | Unreachable | ✅ Contained (either not listening, firewalled, or the hostname/IP resolution in the probe didn't reach the right target — see gaps below). |
| **Internal registry (`192.168.122.200:5000`)** | **Reachable — `{"repositories":[]}`** (before fix) → **`blocked/unreachable` (after fix)** | ❌ **Real gap, found and fixed.** See below. |

## The one real finding: no NetworkPolicy on `arc-runners` or `registry`

The CI runner pod successfully reached the internal container registry —
a completely unrelated internal service it has no legitimate reason to
talk to for this job. Root cause, confirmed directly:

```
kubectl get networkpolicy -A
```

shows NetworkPolicies only in the `argocd` namespace (Argo CD's own Helm
chart defaults) — **none exist for `arc-runners`, `registry`, or any
other namespace**, despite Project 2 and Project 5 both demonstrating
that default-deny + explicit-allow NetworkPolicy works correctly on
this exact cluster stack (Cilium, in this case, not kindnet — and
Cilium's enforcement doesn't have the same live-pod-tracking race
documented for kindnet in Project 2).

This means: **every pod on this cluster can currently reach every other
pod/service**, including a CI runner reaching the registry, the Argo CD
API, or anything else with a ClusterIP or LoadBalancer address. This is
exactly the gap the roadmap's "CI runners should generally have limited
access to internal systems... default-deny and explicit egress paths"
guidance is meant to close — and this drill demonstrates concretely that
it was never actually applied to Project 6's runner namespace, because
Project 6 was scoped around getting ARC working end-to-end, not around
hardening it.

## Fix — applied and verified, with two real false starts along the way

`arc-runner-egress-policy.yaml`: default-deny egress in `arc-runners`,
plus explicit allows for DNS, "the real internet" (an `ipBlock:
0.0.0.0/0` with RFC1918 ranges excluded — lets `actions/checkout`,
dependency downloads, and the GitHub API keep working, while blocking
every internal cluster destination including the registry), and the
Kubernetes API server specifically. Getting this last piece right took
two iterations, both instructive:

**Attempt 1 — plain `ipBlock: 10.96.0.1/32`** (the API server's
ClusterIP) alongside the default-deny + internet-allow rules. Result:
**broke the cluster's own use of the runner** — re-running the drill
workflow, a `curl` to `kubernetes.default.svc` hung for **~2.5 minutes**
before timing out (`exit code 28`), rather than either working or
failing fast. The RFC1918-exclusion rule from the internet-allow policy
correctly excludes `10.96.0.1` (it's in `10.0.0.0/8`), so it needed an
explicit re-allow — but a plain `ipBlock` rule for a Service ClusterIP
doesn't actually work on Cilium.

**Root cause, confirmed via research and then directly reproduced**:
Cilium's `ipBlock`/CIDR selectors match against the real wire-level
destination *after* Cilium's own datapath has already DNAT'd
Service-ClusterIP traffic to a real backend Pod IP — policy enforcement
never sees `10.96.0.1` as the destination, so an `ipBlock` rule for it
silently never matches anything. This produces a default-deny-driven
silent drop (hence the multi-minute TCP timeout, not a clean rejection)
rather than an obvious error — a genuinely easy trap to fall into, since
the policy applies without any error and looks correct on paper.

**Attempt 2 — the actual fix**: Cilium's own documentation explicitly
recommends `toEntities: kube-apiserver` instead of any CIDR-based rule
for this exact case (a `CiliumNetworkPolicy`, since the entity selector
has no equivalent in the plain Kubernetes `NetworkPolicy` API):

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-kubernetes-api-egress
  namespace: arc-runners
spec:
  endpointSelector: {}
  egress:
    - toEntities:
        - kube-apiserver
```

**Re-verified after the fix, both directions confirmed correct**:
- Internal registry: `blocked/unreachable` after a clean **3-second**
  timeout (matching the probe's own `--max-time 3`, i.e. an honest,
  fast deny — not the ~2.5-minute hang from the broken intermediate
  state).
- Kubernetes API server: reachable again, `/version` responds normally.
- RBAC checks (via the mounted ServiceAccount token): still all `403`,
  unaffected by any of this — confirming the network fix didn't
  accidentally loosen the separate authorization layer.

**Why this is worth keeping as the headline finding, not a footnote**:
this is a real, concrete instance of the general principle that CIDR-
based network policy rules can silently fail to match Kubernetes
Service traffic on an eBPF-based CNI, because the datapath's own service
load-balancing happens *before* policy enforcement sees the packet. It
cost real, if brief, breakage of a working CI pipeline mid-session — a
direct, first-hand demonstration of exactly the kind of "looks correct,
isn't" gap that's easy to ship to a real cluster without a drill like
this one to catch it.

## Secondary finding: `NoNewPrivs` is not set

`/proc/self/status` shows `NoNewPrivs: 0`. This flag, when set to `1`,
prevents a process (and anything it `exec`s) from gaining new privileges
via setuid binaries or file capabilities — a standard container hardening
setting (`securityContext.allowPrivilegeEscalation: false` in Kubernetes
terms). ARC's default runner pod spec doesn't set this. Given the
`CapEff` is already zero, the practical exposure here is limited (there's
nothing to escalate *to* without capabilities to begin with), but it's a
real, easy, standard hardening step that's simply not applied by default
— consistent with `containerMode.type: ""` being the simplest, least-
locked-down ARC configuration option, not the most secure one.

## What this drill did NOT find (and why that's informative too)

- No host filesystem access, no host device access, no container-runtime
  socket access, no working privilege escalation path, no working process/
  namespace escape, and no working RBAC-based Kubernetes API abuse.
  Combined with Project 1's findings (privileged containers/DooD *do*
  grant these), this is a clean confirmation that the *default*,
  non-privileged container boundary genuinely holds on this cluster —
  the CI-specific gap here is a networking oversight in this project's
  own setup, not a fundamental flaw in the isolation model.
- This drill used the default `containerMode.type: ""` (jobs run directly
  in the runner container, no DinD/Kubernetes-mode). Project 1's DinD/DooD
  findings suggest revisiting this specific drill if/when this runner
  setup is extended to let jobs build Docker images — that's a
  meaningfully different risk surface (see Project 1's
  `dind-experiment/README.md`) not exercised here.

## Overall verdict

Container-level isolation on this ARC runner is solid by default — the
same properties proven in Project 1 (no privileged access, no host
device/filesystem exposure) hold for a real CI job on this cluster too.
The one real gap found — no NetworkPolicy on `arc-runners`, letting the
CI runner reach the internal registry and any other internal service —
has been fixed and re-verified: default-deny egress with explicit
allows for DNS, external internet, and (via the Cilium-specific
`kube-apiserver` entity, not a CIDR rule) the Kubernetes API server.
Confirmed post-fix: the registry is genuinely unreachable, the API
server and internet access both still work, and RBAC denials are
unaffected. This closes the gap this project's own setup had left open
since Project 6 was originally scoped around getting ARC working end to
end, not around hardening it — now brought in line with the
NetworkPolicy pattern already proven correct in Projects 2 and 5.
