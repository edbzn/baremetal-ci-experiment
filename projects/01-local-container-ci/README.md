# Project 1 — Local container CI

## Goal

Understand jobs, caches, artifacts, and registries without Kubernetes in the
loop yet. Run a CI job in a container, build an image with rootless BuildKit,
push to a local registry.

## Checkpoints before moving on

You should be able to explain:

- What isolates a container from the host (namespaces, cgroups, capabilities).
- Why mounting `/var/run/docker.sock` into a build job is dangerous.
- What OCI images/registries actually are (manifest, layers, config).
- The difference between `containerd`, `runc`, and `BuildKit`.

## Steps

1. Run a local OCI registry (`registry:2`) on this host.
2. Run a rootless BuildKit instance (container or systemd unit) and build an
   image from a sample repo, pushing to the local registry.
3. Wire up layer caching (local cache dir, then registry-based cache
   import/export) and measure the difference on a rebuild.
4. Write a minimal "CI runner" script: clone a repo, run a build in a
   container with dropped capabilities and a read-only rootfs, push the
   result, publish an artifact to a local directory or MinIO.
5. Break things on purpose: fill the container's disk, let it consume all
   memory, try running privileged. Observe what happens to the host.

## Notes / findings

(fill in as you go)
