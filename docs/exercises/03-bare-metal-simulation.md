# Project 3 — Rebuild on simulated bare metal

## Goal

Reproduce Project 2's cluster on "disposable machines" — nested VMs on this
host standing in for real bare-metal nodes — and make node loss/cluster
recreation routine. This is also where the full platform stack from the
roadmap gets introduced (networking, storage, GitOps).

## Why nested VMs first

Real bare-metal machines (PXE, BMC/Redfish, physical disk wipes) are a later
step. Nested KVM VMs on this host give the same "the OS underneath is not
Kubernetes-aware, and nodes can die" property without needing hardware yet.

## Checkpoints before moving on

- Why a VM provides a stronger security boundary than a container (this is
  also the conceptual bridge into Project 4/Kata).
- How CNI + kube-proxy/eBPF + Service + DNS compose end to end (revisit with
  a real CNI now, not kindnet).
- What a control-plane node loss actually looks like operationally (etcd
  quorum, apiserver LB, kubelet behavior on the remaining nodes).

## Steps

1. Provision 3-6 VMs with `virt-install`/`libvirt` or plain QEMU on this host
   (control-plane x3, workers x3+).
2. Bootstrap Kubernetes with `kubeadm` first (to learn internals). Evaluate
   Talos Linux afterward as the "real platform" OS.
3. Install Cilium as CNI (eBPF datapath, NetworkPolicy, Hubble observability).
4. Install MetalLB in layer-2 mode for service load balancing (bare metal has
   no cloud LB). Read up on BGP/FRR-K8s even if not used yet.
5. Add internal DNS and a registry (Harbor or plain `registry:2` to start).
6. Set up etcd snapshotting and do a full restore exercise (don't wait for
   Project 5 to try this once).
7. Introduce GitOps (Argo CD or Flux) for the CI-facing workloads, keeping
   Terraform scoped to machines/network/cluster-foundations only, per the
   division of responsibility in the top-level roadmap.
8. Practice killing a worker node and rejoining a fresh one.

## Notes / findings

### Environment

- Host: same machine as Projects 1-2 (32 cores, 60GB RAM). Freed ~5-6GB by
  deleting Project 2's kind cluster before starting (already fully
  documented/committed, nothing lost).
- Installed `qemu-system-x86`, `libvirt-daemon-system`, `libvirt-clients`,
  `virtinst`, `genisoimage`, `cloud-image-utils` via apt. Nested KVM already
  enabled (`/sys/module/kvm_amd/parameters/nested` = `1`).
- **libvirt group membership gotcha**: adding the user to the `libvirt`
  group doesn't take effect in an *already-running* shell session — even a
  full terminal/Claude Code restart didn't refresh it in this case, because
  the underlying persistent shell process backing the tool predated the
  group change. Workaround: `sg libvirt -c "virsh ..."` runs a command with
  the group active without needing a fresh login. Used this prefix for all
  virsh/virt-install calls throughout.
- **libvirt-qemu can't traverse into $HOME by default**: `virt-install`
  failed with `Cannot access storage file ... Permission denied` when VM
  disks live under `/home/edouard/...`, because the actual QEMU process
  runs as a separate system user (`libvirt-qemu`) that needs *search* (`x`)
  permission on every path component down to the image files, not just
  the final directory. Fixed with `chmod o+x` on each component
  (`/home/edouard`, `.../work`, `.../baremetal-ci-experiment`, etc.) down
  to `vm-images/` — grants traversal only, not directory listing or file
  read access to unrelated users.
- Scoped to **3 VMs** (1 control-plane + 2 workers) rather than the
  roadmap's full 3+3 HA topology, to keep memory headroom comfortable
  after accounting for the rest of the stack already running on this host.
  Full etcd-quorum HA behavior isn't exercised by 1 control-plane node —
  noted as a real scope limitation, not silently glossed over.

### Step 1: provision 3 VMs

- Dedicated libvirt storage pool (`ci-vms`) created under the project
  directory rather than the system default `/var/lib/libvirt/images`, so
  VM disk state stays colocated with the project (and is `.gitignore`d,
  since qcow2 images are large binary runtime state, not source).
- Ubuntu 24.04 (Noble) cloud image + `cloud-localds`-generated NoCloud
  seed ISOs per VM, each VM's disk a qcow2 overlay against one shared base
  image (`-b`/`-F` backing file) rather than 3 full copies.
- `cluster/scripts/provision-vms.sh <names...>`: templates cloud-init user-data
  per hostname, injects the host's real SSH pubkey, creates the overlay
  disk + seed ISO, and `virt-install --import`s each VM non-interactively.
- cloud-init handles the kubeadm prerequisites proactively (swap off,
  `overlay`/`br_netfilter` kernel modules) — refined further in step 2
  after discovering two gaps (see below).
- Result: 3 VMs (`ci-cp1`, `ci-worker1`, `ci-worker2`) booted, got DHCP
  leases and correct hostnames from the default libvirt NAT network,
  cloud-init reported `status: done` on all three, swap confirmed off via
  empty `swapon --show`.

### Step 2: kubeadm bootstrap

- Installed containerd (with `SystemdCgroup = true` — required for
  kubelet's cgroup driver to match) + `kubeadm`/`kubelet`/`kubectl`
  v1.31 from the official Kubernetes apt repo on all 3 nodes via a shared
  script (`cluster/scripts/install-k8s-prereqs.sh`), run over SSH.
- **`kubeadm init` preflight failures, first attempt** — two real gaps
  cloud-init hadn't covered:
  - `ERROR FileExisting-conntrack`: `conntrack` package wasn't installed.
  - `ERROR FileContent--proc-sys-net-ipv4-ip_forward`: cloud-init loaded
    the `br_netfilter` kernel module but never actually set
    `net.ipv4.ip_forward=1` via sysctl — module loading and the actual
    forwarding sysctl are two separate steps, easy to do one without the
    other.
  - Fixed live on all 3 nodes (`apt install conntrack` +
    `/etc/sysctl.d/99-kubernetes-forwarding.conf` with
    `net.ipv4.ip_forward=1` and the two `bridge-nf-call-*` settings), *and*
    folded the fix back into the cloud-init template for next time, so a
    freshly reprovisioned VM won't hit the same preflight failure.
- `kubeadm init --pod-network-cidr=10.244.0.0/16` succeeded on `ci-cp1` on
  retry. `kubeadm join` succeeded on both workers using the real token +
  discovery-hash it printed (no `--upload-certs`/multi-control-plane
  complexity needed for a single-control-plane setup).
- All 3 nodes showed up via `kubectl get nodes` immediately (`NotReady`,
  correctly, pending CNI) — real kernel `6.8.0-134-generic`,
  `containerd://2.2.1`, actual separate machines rather than containers
  standing in for nodes (the key structural difference from Project 2's
  kind cluster).
- Fetched `admin.conf` from the control-plane VM to
  `cluster/.kube/config` (`.gitignore`d — it's a
  cluster-admin credential) so `kubectl`/`helm` on the host machine manage
  this cluster directly via `KUBECONFIG=.../.kube/config`.

### Step 3: Cilium as CNI

- Installed via Helm (`cilium/cilium` v1.16.5) into `kube-system`, with
  `kubeproxyReplacement: "false"` deliberately — kept standard
  `kube-proxy` in place alongside Cilium so the *only* variable changing
  versus Project 2 is the CNI datapath itself (kindnet's minimal
  veth/iptables approach -> Cilium's eBPF), not also removing kube-proxy
  at the same time. `ipam.mode: cluster-pool` with the same
  `10.244.0.0/16` CIDR used at `kubeadm init`. Hubble + Hubble Relay + UI
  enabled for observability.
- All 3 nodes went `Ready` immediately once Cilium's daemonset was
  running (`cilium status --brief` → `OK` on every node).
- **Verified real cross-machine pod networking**, not just cross-container:
  a pod scheduled on `ci-worker1` successfully reached a pod on
  `ci-worker2` over HTTP (`hello-cross-node`) — genuinely two separate
  libvirt VMs communicating over Cilium's eBPF datapath across the virtual
  network, not two processes sharing a Docker bridge like kind's
  "nodes" were in Project 2.
- **Hubble flow visibility confirmed live**, not just configured:
  `hubble observe --last 15` (run via `kubectl exec` into a `cilium-agent`
  pod, since the CLI isn't bundled in the `hubble-relay` image) showed
  real flows with resolved pod identities (`kube-system/hubble-ui-...`),
  TCP flags, and datapath stage labels (`to-endpoint`, `to-stack`,
  `to-overlay`) — meaningfully richer per-packet observability than
  kindnet ever exposed in Project 2.
- DNS resolution confirmed working through CoreDNS at the standard
  `10.96.0.10` ClusterIP, same mechanism as Project 2.

### Step 4: MetalLB in layer-2 mode

- Shrunk the libvirt `default` network's DHCP range from
  `192.168.122.2-254` down to `.2-.199` (`virsh net-update ... delete/add
  ip-dhcp-range --live --config`), carving out `.200-.220` as a static pool
  for MetalLB with no risk of DHCP handing the same address to a future VM.
- Installed via Helm (`metallb/metallb` into a new `metallb-system`
  namespace). This chart version bundles `frr-k8s` (FRRouting) pods
  alongside the classic `speaker` daemonset even when only L2 mode is
  configured — worth knowing so the extra `frr-k8s-*` pods aren't mistaken
  for something separately installed.
- Configured via CRs: an `IPAddressPool` (`192.168.122.200-220`) and an
  `L2Advertisement` referencing it.
- **Verified with a real `type: LoadBalancer` Service**, not just checking
  CRD status: `kubectl expose deployment ... --type=LoadBalancer` got
  `EXTERNAL-IP: 192.168.122.200` (the first address in the pool) almost
  immediately — no cloud provider involved, which is exactly the gap
  MetalLB exists to fill on bare metal.
- **Reachability confirmed from the real host machine**, external to the
  Kubernetes cluster entirely: a plain `curl http://192.168.122.200/` from
  this host (just an ordinary client on the libvirt network, no kubeconfig
  or cluster context involved) got a real response from the pod behind the
  Service.
- **L2 mechanism confirmed concretely**: `ip neigh show 192.168.122.200`
  from the host showed a real ARP entry resolving to `ci-worker2`'s actual
  MAC address — i.e., one specific node answers ARP for the LB IP and
  becomes the ingress point for that Service's traffic (which then gets
  forwarded to wherever the actual pod is running, via the same Cilium
  datapath already verified in step 3). This is the literal mechanism
  behind "MetalLB in L2 mode" rather than something to take on faith from
  the CRD's existence.
- Not yet tested: BGP/FRR-K8s mode (would need a real or simulated router
  peering with the cluster nodes) — noted as a gap, matching the roadmap's
  own framing that L2 is the simple lab setup and BGP is worth
  understanding but not required for this first pass.

### Step 5: internal DNS + registry

- **Internal DNS**: used Kubernetes's own CoreDNS/Service-DNS mechanism
  rather than standing up a separate DNS server — a registry Deployment +
  Service resolves cluster-internally as
  `registry.registry.svc.cluster.local`, confirmed via a test pod's
  `wget`. This is the same mechanism already verified in Project 2; no new
  DNS infrastructure needed for "internal DNS" at this scale.
- **Registry**: deployed `registry:2` as an actual cluster workload
  (`registry.yaml`) rather than reusing Project 1/2's host-side
  `registry:2` Docker container — the host's registry is bound to
  `127.0.0.1:5000` (loopback only) and lives on Docker's own bridge
  networks, unreachable from the separate libvirt VM network the cluster
  nodes are on. A cluster-internal registry is also more architecturally
  correct for this project's "reproduce this as if it were real bare
  metal" framing.
- Exposed via a `type: LoadBalancer` Service — MetalLB (step 4) assigned
  it `192.168.122.200`, immediately reachable both from the host (`curl`)
  and from inside the cluster (Service DNS name).

**The actual debugging story — containerd 2.x's CRI "transfer service"
silently ignores insecure-HTTP `certs.d` overrides:**

- Configured `/etc/containerd/certs.d/192.168.122.200:5000/hosts.toml`
  (`server = "http://..."` + a `[host."http://..."]` block) on all 3
  nodes, matching the documented pattern and confirmed valid TOML.
- `ctr -n k8s.io images push/pull --plain-http ...` against this registry
  worked immediately from every node — proving network connectivity and
  the registry itself were never the problem.
- But `crictl pull` / an actual pod's `PullImage` **kept forcing HTTPS**
  and failing (`server gave HTTP response to HTTPS client`), completely
  ignoring the `hosts.toml` — even after confirming `config_path` was
  correctly set under the (containerd-2.x-correct)
  `[plugins.'io.containerd.cri.v1.images'.registry]` section, restarting
  containerd, trying the alternate `host_port` directory-naming
  convention, and validating the TOML parsed cleanly.
- Root cause, found by turning on containerd debug logging
  (`[debug] level = 'debug'` in `config.toml`, **not** an env var) and
  grepping the journal: the pull log line read `"PullImage ... with
  snapshotter overlayfs **using transfer service**"` — containerd 2.x
  routes CRI image pulls through a newer, pluggable "transfer service"
  path by default, which does **not** reliably honor `certs.d` host
  overrides for insecure HTTP (a known containerd limitation, not a local
  misconfiguration — see containerd/containerd#12550).
- **Fix**: `[plugins.'io.containerd.cri.v1.images'] use_local_image_pull =
  true` — reverts CRI/kubelet image pulls to the classic client-based
  resolver (the same one `ctr images pull` already used successfully),
  which fully honors `certs.d`/`hosts.toml`. Applied on all 3 nodes,
  restarted containerd, and confirmed: a real pod (`kubectl run
  ...--image=192.168.122.200:5000/...`) pulled and ran successfully on
  all 3 nodes afterward.
- Packaged as `cluster/scripts/configure-insecure-registry.sh <registry-host:port>
  <node-ip>...` for reuse — handles both the `hosts.toml` generation and
  the `use_local_image_pull` fix (including de-duplicating the key if a
  `= false` default already exists elsewhere in `config.toml`, which
  caused a containerd startup failure the first time this was applied —
  TOML doesn't allow duplicate keys and containerd's parser fails closed,
  not open, on that error).
- **Why this is worth remembering**: this is a containerd-version-specific
  behavior (2.x's transfer-service default), not something documented
  prominently in most kubeadm/insecure-registry tutorials, which mostly
  predate containerd 2.x. Anyone following older guidance on a fresh
  Kubernetes 1.31+/containerd 2.x install would hit this exact silent
  failure. Directly relevant going into Project 4 (Kata) and any future
  bare-metal registry work on newer containerd versions.

### Step 6: etcd snapshot + full restore exercise

Ran this as an actual destructive test on the live single-control-plane
cluster, not a dry run — per the roadmap's own framing, "a backup that has
never been restored is not sufficient."

**Setup:** installed `etcd-client` (`etcdctl` v3.4.30, matching this
etcd/Kubernetes version's expected API) on `ci-cp1` — not present by
default after kubeadm bootstrap.

**Sequence, with a marker ConfigMap at each stage to prove correctness
rather than just "it came back up":**

1. Created `pre-backup-marker` ConfigMap.
2. `etcdctl snapshot save` using the `healthcheck-client` cert (kubeadm
   already generates this cert specifically for etcd maintenance
   operations like snapshotting) → 7.5MB snapshot, 1917 keys.
3. **Copied the snapshot off-node** to this host's
   `etcd-backups/` — a snapshot sitting on the same disk as the etcd data
   it backs up doesn't survive the failure modes that actually matter
   (disk failure, VM destruction). Hit a real permission gotcha here: the
   snapshot file is owned by `root` (created via `sudo`), so a plain `scp`
   as the regular user fails until `chown`'d first — easy to miss and
   silently end up with backups that were never actually copied anywhere.
4. Created `post-backup-marker` ConfigMap — deliberately *after* the
   snapshot, so its presence/absence after restore proves whether the
   restore actually rolled back to the snapshot's point in time or did
   something else.
5. **Destroyed etcd's live data directory for real**: moved
   `/etc/kubernetes/manifests/etcd.yaml` out of the kubelet-watched
   manifests directory (stopping the static pod cleanly) and `rm -rf
   /var/lib/etcd/member`. Confirmed via `kubectl get nodes` from the host
   genuinely hanging/refusing — the API server was unreachable, not just
   slow, since it depends on etcd for every request.
6. **Restored**: `etcdctl snapshot restore` into a fresh directory
   (`/var/lib/etcd-restored`) with the correct `--name`/
   `--initial-cluster`/`--initial-advertise-peer-urls` matching this
   single-node cluster's identity, then swapped it into place
   (`rm -rf /var/lib/etcd && mv /var/lib/etcd-restored /var/lib/etcd`,
   `chown root:root`) and moved the static pod manifest back.
7. kubelet picked up the restored `etcd.yaml` automatically (that's the
   whole point of static pods — no `kubectl apply` needed, or possible,
   since the API server itself was down) and started etcd against the
   restored data. `kube-apiserver`'s own static pod then restarted itself
   once etcd became reachable again.

**Verification — the actual proof, not just "cluster looks fine":**
- `pre-backup-marker` (created *before* the snapshot): **present** after
  restore, exact original data intact.
- `post-backup-marker` (created *after* the snapshot, before destruction):
  **genuinely gone** — `404 NotFound`. This is the specific, falsifiable
  check that confirms the restore rolled the cluster back to precisely the
  snapshot's point in time, rather than (for instance) partially
  recovering, silently keeping some later writes, or just restarting
  successfully without actually being the restored data.
- Confirmed the rest of the cluster survived the exercise intact: all pods
  still `Running`, and the registry from step 5 still reachable with its
  previously pushed image (`alpine-test`) still listed.

**Packaged for reuse**: `cluster/scripts/etcd-snapshot.sh <control-plane-ip>` —
takes the snapshot, fixes ownership, copies it off-node, cleans up the
node-local temp file. (The restore procedure was kept manual/documented
here rather than scripted, since a real restore should never be a blind
one-command operation — matching the node identity flags to the actual
cluster and confirming the failure mode first matters too much to
automate away.)

**Scope limitation, stated plainly**: this is a single-control-plane
cluster, so this exercise validates the snapshot/restore *mechanism*
correctly, but does not exercise etcd quorum loss/recovery (which needs
≥3 control-plane nodes) — that's a real gap versus the roadmap's stated
architecture, not something to gloss over. A genuine multi-member
etcd-quorum-loss drill belongs in Project 5's disaster exercises if this
cluster is ever expanded to 3 control-plane nodes.

### Step 7: GitOps (Argo CD)

Chose Argo CD over Flux for this exercise mainly for its UI/CLI making the
reconciliation loop easy to inspect directly, matching the roadmap's own
division: Terraform (not used yet in this project) would own
machines/network/cluster-foundations, Argo CD owns frequently-changing
application state — this step introduces that second half concretely.

- Installed via the official manifest
  (`kubectl apply -n argocd -f .../install.yaml`) — hit the well-known
  `metadata.annotations: Too long: must have at most 262144 bytes` error on
  one large CRD (`applicationsets.argoproj.io`), because client-side
  `kubectl apply` stores the entire previous config as an annotation and
  this CRD's schema exceeds the 256KiB annotation size limit. Fixed with
  `--server-side --force-conflicts`, which doesn't have this problem (no
  last-applied-config annotation needed).
- Exposed `argocd-server` via MetalLB (`kubectl patch svc ... -p
  '{"spec":{"type":"LoadBalancer"}}'`) — got `192.168.122.201`, the pool's
  second address, reusing the same mechanism proven in step 4.
- **Application target**: rather than reusing Project 2's manifests
  (which reference `ci-registry:5000` — Project 1/2's *host-side* Docker
  registry, unreachable from this VM cluster per step 5's findings), wrote
  a small dedicated `gitops-demo/` workload in this repo referencing the
  step-5 *cluster-internal* registry (`192.168.122.200:5000`) instead, and
  pointed an Argo CD `Application` at
  `https://github.com/edbzn/k8s-bare-metal-ci.git`,
  path `cluster/gitops-demo`, with
  `syncPolicy.automated: {prune: true, selfHeal: true}`.

**Verified both core GitOps guarantees concretely, not just installed the
tooling:**

1. **Push-to-deploy**: committed and pushed a change (`replicas: 2 -> 4`)
   to this repo, then confirmed Argo CD picked it up — the
   `Application`'s `status.sync.revision` matched the exact new commit
   hash (`3ebf499...`), and `kubectl get deploy` showed 4 replicas
   actually running. (Manually triggered a hard refresh rather than
   waiting out Argo CD's default 3-minute poll interval — a legitimate
   operational action, not a workaround for something broken.)
2. **Self-healing / drift correction**: manually ran `kubectl scale
   deploy gitops-demo --replicas=1` directly against the cluster —
   deliberately bypassing git entirely, simulating either an operator
   mistake or a compromised/misbehaving process touching the cluster
   directly. Within roughly 10 seconds, `kubectl get events` showed Argo
   CD's controller deleting/recreating pods to bring the count back to 4
   (the git-declared value), and `Application.status.operationState`
   confirmed a `Succeeded` sync operation had run automatically,
   unprompted, immediately after the drift.

**Why this matters for the roadmap's CI platform framing**: this is the
concrete mechanism behind "GitOps controllers are better at continuously
reconciling frequently changing Kubernetes workloads" than Terraform —
Terraform would need to be *re-run* to notice and fix drift; Argo CD's
controller is always watching and reverts it automatically, without
anyone needing to remember to do anything. For a CI platform specifically,
this means CI-facing workload config (runner Deployments, RBAC,
NetworkPolicy for the CI namespace) drifting away from its declared state
— whether by accident or by a compromised job trying to modify its own
environment — gets corrected automatically rather than silently
persisting until someone notices.

### Step 8: kill and rejoin a worker node

`ci-worker1` was running real, meaningful workloads at the time (the
step-5 registry, MetalLB's controller, 2 of 4 `gitops-demo` replicas) —
deliberately not an idle node, so this exercises actual failure impact
rather than a no-op.

**Sequence:**
1. `virsh destroy ci-worker1` — hard-kills the VM process outright (not a
   graceful shutdown), simulating real hardware loss rather than a clean
   drain.
2. Watched the cluster's own detection timeline, not just the end state:
   - ~20s after destruction: node transitioned `Ready` → `NotReady`
     (kubelet node-lease heartbeat expiring).
   - Pods already scheduled on the dead node kept showing `Running` in
     the API server's last-known state for some time — the API server
     has no way to know otherwise until the node-controller's taint
     eviction logic acts.
   - `gitops-demo` (4 replicas via a Deployment/ReplicaSet) got **2 fresh
     replacement pods on `ci-worker2` almost immediately** — the
     ReplicaSet controller doesn't wait for confirmation the old pods are
     dead, it just notices "N ready pods < desired N" and creates more.
     The 2 stale pods still bound to the dead node stuck around, still
     tainted with `node.kubernetes.io/not-ready:NoExecute ... for 300s`.
   - The **registry** (`replicas: 1`, no PVC) behaved differently: with
     only one desired replica, there was no "not enough ready replicas"
     signal until the old pod was actually removed — it only got
     rescheduled onto `ci-worker2` once the 300s
     not-ready-toleration window fully expired. This is a concrete,
     observed illustration of why replica count matters for failure
     recovery speed, not just raw availability — a single-replica
     workload waits out the full toleration window; a multi-replica one
     self-heals almost immediately via the same mechanism proven in
     step 7's GitOps drift test.
3. `kubectl delete node ci-worker1` — removing the stale Node object is a
   genuine operator action, not automatic; kubeadm/kubelet won't do this
   for you when a node is truly gone (as opposed to temporarily
   unreachable). This is what actually triggers prompt cleanup of the
   remaining stale pod records, rather than waiting out timers.
4. Provisioned a **fresh** VM (`cluster/scripts/provision-vms.sh ci-worker1` —
   same script as step 1, proving it's genuinely reusable for this exact
   purpose) — new disk, new cloud-init run, new DHCP lease
   (`192.168.122.102`, different from the destroyed VM's `.236`).
5. Ran the same prereqs script (containerd/kubeadm/kubelet) and the
   registry containerd config script from step 5 — both proved reusable
   as-is for a replacement node, not just the original three.
6. Generated a **fresh** join token (`kubeadm token create
   --print-join-command` on the control-plane) rather than reusing the
   original — kubeadm bootstrap tokens expire (24h by default), so a
   real "replace a node" runbook needs this step, not just the original
   join command copy-pasted from initial setup.
7. `kubeadm join` succeeded; new node went `NotReady` → `Ready` once
   Cilium's daemonset pod scheduled onto it (same dependency observed
   back in step 3 — a node isn't `Ready` until its CNI is running there).

**Final state verified, not assumed:**
- All 3 nodes `Ready`, all pods cluster-wide back to `Running`.
- `gitops-demo`: `4/4` again (Argo CD `Synced`/`Healthy`) — the 2 stale
  pods were cleaned up and 2 fresh ones scheduled once the node was
  actually deleted.
- Both MetalLB `LoadBalancer` IPs (`192.168.122.200` for the registry,
  `192.168.122.201` for `argocd-server`) survived the node churn and
  stayed reachable throughout — L2 announcement duty redistributed to a
  healthy node automatically.
- **The registry's data was genuinely lost**: `curl
  http://192.168.122.200:5000/v2/_catalog` returned `{"repositories":[]}`
  — the `alpine-test` image pushed in step 5 is gone, because the
  registry Deployment uses an `emptyDir` volume (local to whichever node
  the pod runs on), and that node was destroyed. This is not a bug in
  this exercise — it's the exact, concrete consequence of the roadmap's
  own storage guidance ("do not assume one distributed storage system
  should serve all five [storage concerns]"; here, zero persistent
  storage was used at all for something that arguably needed it). A
  production-intent registry needs a PVC (or, per the roadmap, something
  like Harbor backed by real storage) — this step makes that requirement
  concrete rather than theoretical, by actually losing real data to prove
  the point.

**Overall takeaway**: node loss recovery worked end-to-end and the same
scripts written for initial provisioning (step 1) and registry config
(step 5) were directly reusable for replacement — which is itself the
point of "making node loss and cluster recreation routine" rather than a
one-off manual scramble. The registry data loss is the one finding that
should change future design (add a PVC before this cluster is trusted
with anything real), not just something to note and move past.
