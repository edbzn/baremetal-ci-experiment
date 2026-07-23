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

(fill in as you go)
