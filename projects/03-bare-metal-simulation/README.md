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
- `scripts/provision-vms.sh <names...>`: templates cloud-init user-data
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
  script (`scripts/install-k8s-prereqs.sh`), run over SSH.
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
  `projects/03-bare-metal-simulation/.kube/config` (`.gitignore`d — it's a
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
