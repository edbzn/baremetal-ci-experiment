# Project 5 — Disaster exercises

## Goal

Make the platform operationally credible by deliberately breaking it and
practicing recovery, rather than assuming backups/HA work because they exist
on paper.

## Drills

- [x] Kill a worker node mid-build; confirm the job reschedules and observe
      how long it takes. *(Project 3 step 8 — see Scope note below)*
- [ ] Fill a worker's disk; confirm eviction/disk-pressure handling works and
      doesn't take down unrelated pods.
- [ ] Disable a simulated top-of-rack network link (drop a veth/bridge on the
      host); observe how the cluster and CNI react.
- [x] Lose one control-plane node (of three); confirm the API server and etcd
      quorum survive.
- [x] Full etcd snapshot + restore exercise on a scratch cluster. *(Project 3
      step 6 — see Scope note below)*
- [x] Reinstall a node from nothing (reprovision, rejoin) and time it.
      *(Project 3 step 8 — see Scope note below)*
- [ ] Rotate runner/service-account credentials without downtime.
- [ ] Revoke access for a "compromised" CI job mid-run (network policy +
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
