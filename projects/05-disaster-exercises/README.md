# Project 5 — Disaster exercises

## Goal

Make the platform operationally credible by deliberately breaking it and
practicing recovery, rather than assuming backups/HA work because they exist
on paper.

## Drills

- [x] Kill a worker node mid-build; confirm the job reschedules and observe
      how long it takes. *(Project 3 step 8 — see Scope note below)*
- [x] Fill a worker's disk; confirm eviction/disk-pressure handling works and
      doesn't take down unrelated pods.
- [x] Disable a simulated top-of-rack network link (drop a veth/bridge on the
      host); observe how the cluster and CNI react.
- [x] Lose one control-plane node (of three); confirm the API server and etcd
      quorum survive.
- [x] Full etcd snapshot + restore exercise on a scratch cluster. *(Project 3
      step 6 — see Scope note below)*
- [x] Reinstall a node from nothing (reprovision, rejoin) and time it.
      *(Project 3 step 8 — see Scope note below)*
- [x] Rotate runner/service-account credentials without downtime.
- [x] Revoke access for a "compromised" CI job mid-run (network policy +
      credential revocation) and confirm blast radius is actually contained.

## Scope note

Three drills overlap substantially with work already done in Project 3
and aren't repeated here — see that project's README for the actual
findings:

- **Kill a worker mid-workload / node reprovisioning**: Project 3 step 8
  destroyed `ci-worker1` (running real workloads at the time — the
  registry, MetalLB's controller, 2 GitOps-managed replicas), observed
  the full detection/recovery timeline, and provisioned+rejoined a
  genuinely fresh replacement VM using the same scripts as initial setup.
- **Full etcd snapshot + restore**: Project 3 step 6 did a real
  destructive test — snapshot, destroy the live etcd data directory,
  restore, and verified correctness with before/after marker ConfigMaps
  (not just "the cluster came back").

## Environment change for this project: real 3-node control-plane HA

Project 3's cluster only had 1 control-plane node — a stated scope
limitation at the time, since the control-plane-loss drill genuinely
needs etcd quorum (≥3 members) to be meaningful. Expanded it here before
running that drill:

- Provisioned 2 more VMs (`ci-cp2`, `ci-cp3`) with the same
  `scripts/provision-vms.sh`/`install-k8s-prereqs.sh` from Project 3 —
  both reused without modification.
- **Real retrofit problem, not anticipated going in**: the original
  single-CP cluster was never `kubeadm init`ed with a
  `controlPlaneEndpoint` (a load-balanced VIP in front of all API
  servers) — it just used `ci-cp1`'s own IP directly, since a single-node
  control plane doesn't need one. Adding more control-plane nodes
  requires one; kubeadm refuses with `unable to add a new control plane
  instance to a cluster that doesn't have a stable controlPlaneEndpoint
  address`.
- Fixed by retrofitting one onto the live cluster rather than rebuilding
  from scratch:
  1. Ran an `haproxy:2.9` container (`--network host`) on this host,
     listening on `192.168.122.1:16443`, round-robining to all 3
     control-plane nodes' real `:6443` (`haproxy.cfg` in this project's
     directory).
  2. Hit a real, easy-to-miss gap: HAProxy listened correctly on
     `0.0.0.0:16443` and worked from the host itself, but VMs on the
     libvirt bridge network couldn't reach it — `ufw` was active with
     default-deny-incoming, silently blocking the VM-to-host path with no
     error on the client side (just a timeout). Fixed with a narrowly
     scoped rule: `ufw allow from 192.168.122.0/24 to any port 16443
     proto tcp` — opens only this port to only the VM subnet, not a
     general firewall relaxation.
  3. Patched the live `kubeadm-config` ConfigMap's `ClusterConfiguration`
     to add `controlPlaneEndpoint: 192.168.122.1:16443`.
  4. **Regenerated the apiserver's TLS certificate** with the LB IP added
     as a SAN (`kubeadm init phase certs apiserver --config ...`) —
     necessary because the existing cert's SAN list only covered
     `ci-cp1`'s own IP/hostname; without this, TLS verification against
     the LB IP would fail even though the ConfigMap and network path were
     both correct.
  5. Force-restarted the apiserver static pod (`crictl stop` on its
     container — moving the manifest out and back didn't trigger a
     timely restart on its own; stopping the running container directly
     is what actually made kubelet recreate it) to pick up the new cert.
  6. Generated a fresh join token and joined both new nodes via
     `kubeadm join <LB-IP>:16443 ... --control-plane --certificate-key
     <uploaded-certs-key>`.
- **Verified real 3-member etcd quorum**, not just 3 Ready nodes:
  `etcdctl member list` showed all three (`ci-cp1`, `ci-cp2`, `ci-cp3`)
  as `started`, `IS LEARNER: false` — genuine full voting members, not
  one stuck mid-join.
- Updated the local `.kube/config` to point at the LB endpoint instead of
  `ci-cp1` directly, so cluster access itself no longer has a single
  point of failure.

**Why this belongs in the write-up, not just as a setup footnote**: this
retrofit *is* itself a disaster-recovery-relevant finding — expanding a
single-node control plane to HA after the fact is real, fiddly surgery
(cert regeneration, config patching, a silent firewall gap) precisely
because it wasn't planned for at initial bootstrap. The roadmap's own
advice to decide control-plane HA topology upfront, rather than retrofit
it later, is borne out directly by how much manual work this took
compared to how trivial `--control-plane-endpoint` would have been to
pass to the original `kubeadm init`.

## Notes / findings

### Drill 1: control-plane node loss (real etcd quorum)

**Setup:** created a marker ConfigMap (`cp-loss-marker`), then `virsh
destroy ci-cp3` (hard kill, one of 3 control-plane nodes).

**Immediately after destruction:**
- A **read** against the API (via the LB) succeeded instantly —
  `kubectl get configmap cp-loss-marker` returned correctly, since it was
  likely served by a healthy backend or from a still-valid connection.
- A **write** (`kubectl create configmap post-loss-marker`) initially
  **failed with a TLS handshake timeout** — not because the cluster was
  actually broken, but because **HAProxy hadn't yet detected `ci-cp3` was
  down** and was still routing some connections to the dead backend.
  `docker logs k8s-lb` showed the exact sequence: connections routed to
  `ci-cp3` for ~2 seconds (HAProxy's default TCP-check interval/timeout)
  before it was marked `DOWN` and removed from rotation. Retrying the
  write immediately after succeeded.
- **This is a real, generalizable finding, not specific to this setup**:
  a load balancer's own health-check latency is part of the actual
  failover time users experience, on top of whatever etcd/Kubernetes
  itself needs — "the control plane survived" and "clients experienced
  zero disruption" are different claims, and this drill made the gap
  between them concrete rather than assumed away.
- After HAProxy failed over: full read/write functionality confirmed —
  the write succeeded, all pods cluster-wide stayed `Running`
  (unaffected), and `etcdctl endpoint status --cluster` showed the
  remaining 2 members (`ci-cp1` leader, `ci-cp2` follower) healthy,
  in sync (identical RAFT term and near-identical index), while
  correctly timing out only on the genuinely dead `ci-cp3` endpoint.
- No leader re-election churn observed — `ci-cp1` remained leader
  throughout (etcd's Raft implementation doesn't need to re-elect when
  a follower, not the leader, is lost, and the term number stayed
  constant confirming this).

**Recovery:** `virsh start ci-cp3` (the VM was only powered off by
`destroy`, not `undefine`d, so its disk/etcd data survived intact) —
came back `Ready` and rejoined etcd's quorum **automatically, with no
manual `kubeadm join` needed**, catching up to the exact same RAFT index
as the other two members. This is a materially different (and easier)
recovery path than Project 3's worker-node drill, where the VM was
`undefine`d and genuinely gone, requiring full reprovisioning — worth
keeping in mind operationally: "the VM is temporarily unreachable" and
"the VM/its disk is actually gone" are different failure classes with
very different recovery procedures, and it's worth knowing which one
you're actually facing before reacting.

**Overall**: etcd's majority-quorum design worked exactly as intended —
losing 1 of 3 members caused zero data-plane impact and only a few
seconds of client-visible disruption, entirely attributable to the load
balancer's health-check interval rather than the control plane itself.

### Drill 2: fill a worker's disk mid-workload

**Setup:** `ci-worker2` was already at 80% disk usage (15GB/19GB) before
starting — convenient, since it meant triggering real pressure needed
only a few more GB rather than a much larger fill. Deployed a plain
"bystander" pod pinned to that node (`sh -c 'while true; echo tick;
sleep 5; done'`) first, specifically so its continued healthy operation
could be checked against, rather than just assuming "no other pods
crashed" from a coarse cluster-wide glance.

**Fill:** `dd if=/dev/zero of=/root/fill.bin bs=1M count=3000` directly
on the host filesystem (simulating an unbounded process/log, not a
container's own ephemeral-storage limit — that mechanism was already
covered in Project 2 step 7) — pushed the node to 96% used, 766MB free.

**Kubelet's actual response, observed step by step:**
1. `DiskPressure` condition flipped `False` → `True` within ~10 seconds
   of crossing the threshold (kubelet's default `nodefs.available < 10%`
   hard-eviction threshold — not custom-configured, this cluster uses
   kubeadm's defaults).
2. Node stayed `Ready` throughout — disk pressure does **not** take the
   node itself offline, only changes what can run on it.
3. A `node.kubernetes.io/disk-pressure:NoSchedule` taint was
   automatically applied. Verified concretely: a new pod pinned to this
   node via `nodeSelector` correctly stayed `Pending` with
   `FailedScheduling: ... untolerated taint {node.kubernetes.io/disk-pressure}`
   — new work is genuinely refused, not just discouraged.
4. Kubelet's own event log showed it **attempting image garbage
   collection first**, before touching any running pod
   (`Attempting to reclaim ephemeral-storage`) — reclaim, not eviction,
   is the first response.
5. **DaemonSet pods on the pressured node got evicted and immediately
   recreated on the same node**, repeatedly (`metallb-frr-k8s-*`,
   `metallb-speaker-*` cycling through `Evicted` → new pod, several times
   over a few minutes) — because DaemonSet pods tolerate most node
   taints (including disk-pressure) by default, so the DaemonSet
   controller keeps trying to satisfy "one pod per node" even while that
   node is actively pressured, producing real eviction churn rather than
   the DaemonSet simply skipping the bad node.
6. **The plain `bystander` pod was never touched** — confirmed via its
   own log continuing to tick (`tick 7` → `tick 21` and beyond) with zero
   restarts throughout the entire episode. This is the actual, concrete
   proof the drill set out to get: disk pressure on a node evicts
   *some* things (DaemonSet pods cycling, in this observation) but does
   **not** indiscriminately take down unrelated running workloads on that
   same node.

**Recovery — a real, non-obvious gotcha**: after deleting the fill file
and confirming real disk usage back to 65% used / 6.5GB free (well under
the 10% threshold), `DiskPressure` **did not clear on its own** within
several minutes of active checking — it stayed stuck `True` with a stale
timestamp, despite `df`/`df -i` on the node both showing healthy numbers.
Only `sudo systemctl restart kubelet` forced a fresh evaluation, which
then correctly reported `DiskPressure: False` within seconds. Whether
this was kubelet's eviction-manager sync loop genuinely running on a
longer interval than the few minutes waited, or a real stuck-condition
bug, wasn't conclusively distinguished here — but the practical
takeaway is the same either way: **don't assume a disk-pressure
condition clears promptly just because the underlying disk usage is
already fine** — check the node condition directly rather than trusting
"I freed the space, so it must be fine now."

**Cleanup note**: three unrelated pods were sitting in `Error` state
after this drill (`argocd-dex-server`, `hubble-relay`, the registry pod)
— all leftovers from earlier drills' churn (control-plane-loss retries,
kubelet restarts), not new casualties of this specific disk-fill test.
Deleting them let their controllers recreate healthy replacements —
worth distinguishing "pods this drill broke" from "pre-existing mess
from prior drills" rather than attributing all observed errors to
whichever drill happens to be running when you look.

**Follow-up: this stopped being a simulated drill and became a real,
recurring problem.** Across later projects in this roadmap (Project 6's
`dind`/`kubernetes` containerMode tests, Project 4's later `kata-fc`
follow-up), the `isolated-ci` workers hit genuine `DiskPressure` — not
induced, actual exhaustion — three separate times as the accumulated CI
stack (Cilium, MetalLB, ArgoCD, cert-manager, ARC, Kata's images/kernels/
Firecracker binaries, the registry) grew past what the original 20GB
qcow2 disks could hold. Restarting kubelet each time (the workaround
above) treated the symptom repeatedly rather than the cause. Fixed at the
root instead: live-resized both workers' qcow2 disks to 40GB
(`virsh blockresize <vm> vda 40G`, no VM downtime needed since libvirt
supports online block resize), then grew the in-guest partition and
filesystem (`growpart /dev/vda 1 && resize2fs /dev/vda1`, both online too).
Real usage dropped from 76-81% to ~37-39%, and this time `DiskPressure`
cleared **on its own** — no kubelet restart needed — once genuine disk
pressure was actually relieved, which is a useful data point on the
"does the condition clear promptly" question left open above: it does,
when the fix is real and total capacity (not just used space) increases.
Lesson for the roadmap: a 20GB disk was fine for Project 3's original
scope but was always going to be too small once Projects 4 and 6 layered
Kata and ARC on top — worth sizing new lab VMs closer to 40GB from the
start rather than growing them reactively under pressure.

### Drill 3: simulated network link failure

Rather than dropping a veth/bridge globally (all VMs share the single
libvirt `virbr0` bridge in this lab setup, so a global drop would sever
every VM at once, not simulate a single top-of-rack link failure), cut
one node's network specifically at the hypervisor level: `virsh
domif-setlink ci-worker2 vnet2 down` — this sets the virtual NIC's link
state down, closer to a real physical link failure than an iptables
rule (which would still let the guest OS believe its NIC is up).

**Setup:** deployed a marker pod (`netfail-test`, a `sh` loop printing an
incrementing counter every 5s) pinned to `ci-worker2` before cutting the
link, specifically so its counter's continuity could prove whether the
container process itself survived the outage or was restarted.

**Immediately after the link-down:**
- SSH to the node timed out (`Connection timed out`, not "connection
  refused" — confirming genuine network-layer isolation, not just the
  SSH daemon being down).
- The rest of the cluster was **entirely unaffected**: a new ConfigMap
  write succeeded immediately, and a fresh pod scheduled on the healthy
  `ci-worker1` ran and resolved DNS normally — no isolated node has any
  special claim on cluster-wide control-plane functions in this
  architecture.
- `ci-worker2` transitioned `Ready` → `NotReady` after ~20 seconds — the
  same kubelet node-lease timeout observed in Project 3's VM-destruction
  drill. `netfail-test`'s pod itself kept showing `STATUS: Running`
  (stale, from the API server's last-known state — it has no way to know
  otherwise once its node stops reporting), with the same 300s
  `not-ready`/`unreachable` `NoExecute` toleration window from Project 3
  governing when it would eventually be considered for eviction.

**Recovery — the actual point of distinguishing this drill from Project
3's**: restored the link (`virsh domif-setlink ci-worker2 vnet2 up`).
- SSH reachable again within seconds.
- `ci-worker2` returned to `Ready` **automatically**, with **no manual
  intervention at all** — no `kubectl delete node`, no rejoin, no
  reprovisioning. This is the key structural difference from Project 3's
  drill: there, the VM was genuinely destroyed (`virsh destroy` +
  `undefine`), so kubelet itself was gone and recovery required treating
  it as a dead node (delete + reprovision + rejoin). Here, kubelet never
  stopped running — it just couldn't communicate — so once the network
  path returned, it resumed reporting on its own.
- **The original `netfail-test` pod was still the exact same pod,
  `RESTARTS: 0`, and its counter had kept incrementing the entire time**
  (`tick 27` by the time it was checked, having started well before the
  outage) — definitive proof the container process itself was never
  interrupted. The outage was purely a *reporting* gap from the cluster's
  perspective, not an actual workload interruption.

**Takeaway — this distinction is the actual finding**: "a node is
temporarily unreachable" and "a node is actually gone" produce
superficially similar symptoms at first (`NotReady`, stale pod status)
but have completely different correct responses. Treating a transient
network partition as if the node were dead (deleting the Node object,
forcing rescheduling) would have been actively counterproductive here —
it would have caused unnecessary pod churn and duplicate work for a
problem that was already self-healing. The 300s
not-ready/unreachable toleration window exists precisely to give a
partition like this time to resolve before Kubernetes commits to the
more expensive "treat it as dead and reschedule everything" response —
worth remembering as a deliberate design tradeoff (some extra tolerance
for false-positive node loss) rather than just "slow recovery."

### Drill 4: rotate a runner ServiceAccount credential without downtime

**Setup:** a `ServiceAccount` (`ci-runner-sa`) with an explicitly-created,
long-lived token `Secret` — the older static pattern still common in CI
systems that predate Kubernetes's auto-rotating bound service account
tokens — mounted into a pod that continuously authenticates against the
API server every 3 seconds (`curl` with the token as a Bearer header,
checked against a read the RBAC Role actually permits).

**Naive rotation sequence tested first (delete-then-create) — this is
the actual finding, a real, measured outage**:
1. Confirmed the runner authenticating successfully (`http_code=200`)
   for 12 consecutive attempts.
2. Deleted the old token `Secret`.
3. **The very next attempt started failing** (`http_code=401`) — even
   though the pod's mounted volume still had the old token file on disk
   (kubelet hadn't re-synced the volume yet), the API server immediately
   rejected it once the underlying Secret object was gone. The
   credential became invalid *before* a replacement existed.
4. Created a new token `Secret` with the same name/annotation.
5. Recovery took **8 failed attempts** (~24 seconds at this drill's 3s
   poll interval) before requests started succeeding again — the delay
   is kubelet's periodic Secret-volume resync interval picking up the new
   token file on disk, not anything the pod itself needed to do (it was
   never restarted — `RESTARTS: 0` throughout the entire drill).
6. **This is a real, non-zero downtime window from a naive rotation
   order** — delete-then-create guarantees a gap between "old credential
   invalidated" and "new credential available," sized by whatever the
   consuming pod's resync/reconnect behavior is.

**What the correct sequence would have been (not re-tested, but the
clear implication of the measured behavior above)**: create the new
token/Secret *first*, let consumers pick it up (or explicitly restart
them to force immediate pickup rather than waiting on a resync
interval), confirm the new credential is actually in use, *then* delete
or expire the old one. Never delete-then-create for something with live
consumers — the measured ~24s gap here is directly attributable to
doing it backwards.

**Broader implication for the roadmap's "short-lived credentials /
workload identity" guidance**: this static-Secret-token pattern is
exactly the kind of credential the roadmap recommends moving away from
in favor of projected, auto-rotating bound service account tokens
(the default `kubernetes.io/serviceaccount` volume mechanism used
throughout Projects 1-4, not the explicit long-lived Secret used here
specifically to have something to rotate manually). Bound tokens rotate
automatically with a configurable expiry and kubelet handles the
refresh without any of this manual delete/recreate choreography — this
drill's whole failure mode is specific to the older pattern and is a
concrete argument for why the newer default is better, not just a
theoretical preference.

### Drill 5: revoke access for a "compromised" CI job mid-run

**Setup:** a namespace with a plausible normal CI-job shape — a
`ServiceAccount` (`suspect-job-sa`) granted `get/list` on Secrets in its
own namespace (standing in for, e.g., legitimate registry-credential
access), a `sensitive-secret` it can read, and an `internal-target`
Service it can reach over the network. A pod (`suspect-job`, using its
own auto-mounted default token, not a custom-mounted one — simpler and
avoided the volume-mount mistake made on the first attempt) continuously
exercises both: polling the internal Service and reading the Secret via
a direct API call, every 4 seconds. Confirmed both succeeding normally
(`network=[sensitive-internal-response]`,
`api_http_code=200`) for 12 consecutive attempts before containment —
establishing a genuine baseline of "this looks like a normal, functioning
CI job" before treating it as compromised.

**Containment applied live, mid-run, deliberately scoped to the specific
suspect pod rather than the whole namespace** (a more realistic incident
response than nuking everything in the namespace, which would also take
down legitimate workloads sharing it):

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
spec:
  podSelector:
    matchLabels:
      run: suspect-job
  policyTypes: ["Egress", "Ingress"]
```

plus `kubectl delete rolebinding suspect-job-binding` (revoking the RBAC
grant, not deleting the ServiceAccount itself — keeps the object around
for forensics rather than erasing evidence of what it was permitted to
do).

**Result, verified precisely rather than assumed:**
- Both measures took effect at the same observed poll cycle (attempt 13)
  — network went fully dark (`network=[]`) and the API call failed at
  the transport level (`api_http_code=000`, connection-level failure,
  not even reaching an HTTP response) — because the blanket
  `Egress`/`Ingress` deny with no exceptions blocks *all* outbound
  traffic from this pod, including to the API server itself, not just to
  the internal target.
- **This made it impossible to tell, from inside the pod's own log,
  whether the RBAC revocation alone would have been sufficient** — the
  network block already prevented any API traffic at all. Checked
  independently, from outside the contained pod's network path:
  `kubectl auth can-i get secrets --as=system:serviceaccount:...` →
  `no`. Confirms the RBAC revocation is genuinely effective on its own,
  not just incidentally masked by the simultaneous network block —
  worth verifying both measures independently rather than assuming a
  combined test proves each one individually.
- **Blast radius genuinely confirmed surgical, not just assumed from the
  NetworkPolicy's `podSelector`**: a *different*, freshly-created pod in
  the *same namespace* (not the contained `suspect-job`) successfully
  reached `internal-target-svc` immediately after containment
  (`sensitive-internal-response`) — proving the NetworkPolicy's
  pod-specific selector genuinely scoped the block to just the one
  suspect pod, not the whole namespace, exactly as intended rather than
  as a side effect that happened to look right.
- On namespace cleanup (tearing down the ServiceAccount along with
  everything else), the API check transitioned from `000`
  (network-blocked) to `401` (token itself invalidated, once the
  ServiceAccount object was actually deleted) — a clean confirmation of
  the layered nature of these controls: network policy, RBAC, and
  ServiceAccount existence are three independent gates, each capable of
  stopping access on its own.

**Overall**: both containment mechanisms — NetworkPolicy scoped to the
specific suspect pod, and RBAC revocation via deleting the RoleBinding —
worked exactly as intended, independently verifiable, and genuinely
surgical (collateral-free for other workloads in the same namespace).
This is the concrete version of the roadmap's "revoke access for a
compromised job" principle: not a single kill switch, but layered,
independently-effective controls that can be applied without first
killing the pod itself (useful if forensics on the running process
matter before termination).
