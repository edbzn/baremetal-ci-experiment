# Concept checkpoints

Running notes. Each question should get a short written answer in your own
words before moving to the next project — if you can't write it concisely,
you don't understand it yet.

## Linux / containers

- What isolates a container from the host?
- What happens when a CI job fills the disk, consumes all memory, or runs
  privileged code?
- Why does mounting the host Docker socket into a build job defeat container
  isolation?

## Kubernetes

- What does Kubernetes add on top of containerd?
- Where do packets travel when one pod connects to another (same node,
  cross-node, cross-namespace via Service)?
- What's the actual difference between a Deployment, a Job, and a bare Pod
  in terms of the controller reconciling them?

## Virtualization / microVMs

- Why does a VM provide a stronger security boundary than a container?
- What specifically does Firecracker/Kata's minimal virtual hardware model
  remove compared to full QEMU, and why does that matter for attack surface?
- Where does microVM overhead actually come from (boot time, I/O path,
  memory)?

## Bare metal

- What's the actual failure mode being protected against by 3 control-plane
  nodes / etcd quorum?
- What does MetalLB do that cloud Kubernetes gets for free?
