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

### Environment

- Host: Ubuntu 26.04, Docker 29.5.1, KVM available, 32 cores / 60GB RAM.
- Docker network `ci-experiment` created for the registry + buildkitd + client
  containers to reach each other by name.

### Step 1-2: registry + rootless BuildKit

- Registry: plain `registry:2` container, `-p 127.0.0.1:5000:5000`, named
  volume `ci-registry-data`.
- Rootless BuildKit (`moby/buildkit:rootless`) needs to create a **nested**
  user namespace (rootlesskit runs BuildKit's own userns inside the
  container's already-unprivileged userns). Ubuntu 26.04 blocks unprivileged
  user namespaces by default via
  `kernel.apparmor_restrict_unprivileged_userns=1` (a kernel-wide AppArmor
  LSM hook), which fails nested-userns creation for a containerized process
  regardless of that container's own AppArmor confinement.
  - The commonly cited fix (a host AppArmor profile for
    `/usr/bin/rootlesskit`) does **not** apply here — it's for rootlesskit
    running directly on the host (e.g. `dockerd-rootless-setuptool.sh`), not
    inside a container. A containerized process is already confined by
    Docker's own profile (or unconfined via `--security-opt
    apparmor=unconfined`), and the userns check gates on that confinement,
    not a separate host-side profile keyed to the in-container path.
  - Confirmed fix: relax the sysctl host-wide,
    `kernel.apparmor_restrict_unprivileged_userns=0`, persisted via
    `/etc/sysctl.d/99-userns.conf`. Acceptable tradeoff on a personal
    learning box; would need reconsidering for shared/production hosts.
  - Required container flags either way: `--security-opt seccomp=unconfined`,
    `--security-opt apparmor=unconfined`, `--security-opt
    systempaths=unconfined`, plus `--device /dev/fuse`.
- The `moby/buildkit:rootless` image's entrypoint is `[rootlesskit buildkitd]`
  — running `buildctl` as a client from the same image requires
  `--entrypoint buildctl` to bypass the rootlesskit wrapper (the client
  doesn't need its own userns).
- Successful loop: `buildctl build --frontend dockerfile.v0 --local
  context=... --local dockerfile=... --output
  type=image,name=ci-registry:5000/sample-app:v1,push=true,registry.insecure=true`
  against `tcp://ci-buildkitd:1234`, then pulled and ran from
  `localhost:5000/sample-app:v1` successfully.
- Checkpoint answer (what isolates a container from the host): normally PID/
  mount/network/user namespaces + cgroups + capability drops. Rootless
  adds another layer (an unprivileged user namespace mapping container root
  to an unprivileged host UID) — the interesting finding this step surfaced
  is that this rootless boundary is exactly what modern kernels/distros are
  increasingly restricting by default, because unprivileged user namespaces
  are also a significant kernel attack-surface/privilege-escalation vector.
  That tension (rootless-for-safety vs. userns-restriction-for-safety) is
  worth remembering going into the Kata/microVM project later.

### Step 3: layer caching

- Local warm-cache rebuild (same buildkitd instance, no Dockerfile changes):
  0.66s, every step `CACHED`. Unsurprising — this is just BuildKit's own
  content-addressed cache, not something ephemeral CI runners get to rely on
  since each job gets a fresh pod/daemon.
- The real test for CI: simulate a brand-new ephemeral runner (a *fresh*
  buildkitd container, empty local cache/volume) and see whether importing
  cache from the registry helps.
  - Daemon-side config needed for the insecure local registry:
    `~/.config/buildkit/buildkitd.toml` with
    `[registry."ci-registry:5000"]  http = true  insecure = true`, passed via
    `buildkitd --config`. The `insecure=true` attribute on
    `--export-cache`/`--import-cache` flags did NOT work on this BuildKit
    version (v0.31.2) — kept trying HTTPS regardless. Daemon-level registry
    config is the reliable mechanism.
  - Export cache after a build: `--export-cache
    type=registry,ref=ci-registry:5000/sample-app:buildcache,mode=max`
    (`mode=max` exports intermediate layers too, not just the final image —
    needed for multi-stage-style reuse).
  - Results:
    | Scenario | Time | Steps |
    |---|---|---|
    | Fully cold daemon, no cache import | 3.8s | all steps executed (`apk add` re-fetched/installed) |
    | Fresh daemon, `--import-cache type=registry,ref=...buildcache` | 2.1s | all steps `CACHED` |
  - On this trivial Alpine+curl image the absolute delta is small (~1.7s),
    but the *mechanism* is the point: a brand-new daemon with zero local
    state reused a previous, different daemon's build output purely via the
    registry. On a real dependency-heavy build (e.g. a multi-minute
    `apt-get`/`npm install`/compile step) this is the difference between
    every ephemeral CI pod redoing that work from scratch vs. reusing it.
  - Checkpoint takeaway: ephemeral CI pods have no shared local disk by
    default, so registry-based cache import/export (not local BuildKit
    cache) is the mechanism that actually matters once this moves to
    Kubernetes Jobs in Project 2.

### Step 4: minimal CI runner script

- `scripts/run-ci-job.sh <tag>`: builds via BuildKit + registry cache (step
  3's mechanism), pushes, then smoke-tests the built image in a locked-down
  container (`--read-only`, `--tmpfs /tmp`, `--cap-drop ALL`,
  `--security-opt no-new-privileges`, `--pids-limit 64`, `--memory 64m`),
  and finally writes an artifact record (`artifacts/<image>-<tag>.json` with
  the image ref, digest, and captured run output) plus a build log.
- Gotcha: this BuildKit version pushes OCI-media-type manifests by default.
  Fetching the digest back from the registry with only
  `Accept: application/vnd.docker.distribution.manifest.v2+json` 404s —
  the registry's content negotiation doesn't fall back. Fixed by accepting
  both `application/vnd.oci.image.manifest.v1+json` and the docker v2 media
  type in the same request.

### Step 5: break things on purpose

| Scenario | Setup | Result |
|---|---|---|
| Fill disk, size-capped | `--read-only --tmpfs /tmp:size=10m`, `dd` 50MB into `/tmp` | `dd: No space left on device` at exactly 10MB written; container fails cleanly, host untouched. |
| Fill disk, **no** size cap | default writable overlay layer, `dd` 2GB | Succeeds silently (`exit=0`) — the container's overlay upper dir lives on the **host's real filesystem**, so an unbounded build step really can consume the whole host disk. This is the actual danger case, not the tmpfs one. |
| Memory exhaustion | `--memory=64m --memory-swap=64m`, shell loop appending to `/dev/shm` | Repeated `Killed` (exit 137); confirmed via `docker events --filter event=oom` (`container oom ...`). Host memory (`free -h`) unaffected — the cgroup memory limit contained the damage to that container's processes. |
| Privileged vs default capabilities | `docker run --privileged` vs default, compare `/proc/self/status` `CapEff` and `/dev` contents | Privileged: `CapEff: 000001ffffffffff` (effectively all capabilities, incl. `CAP_SYS_ADMIN`/`CAP_SYS_MODULE`) **and** host block devices (`nvme0n1`, `dm-0`, `dm-1` — the real host disks) visible under `/dev`. Default: `CapEff: 00000000a80425fb` (small allowlisted set) and zero host devices visible. A privileged container can mount the host's raw disk device directly — this is a real, practical host-compromise path, not a theoretical one. |

**Key takeaways for the CI-runner design (carried into Project 2):**
- Ephemeral-storage limits are not optional — an uncapped build step's
  writable layer is host disk, full stop. Kubernetes `ephemeral-storage`
  resource limits map directly onto this.
- Memory limits (`--memory`) genuinely contain OOM blast radius to the
  container's own cgroup; this is the mechanism `resources.limits.memory`
  relies on in Kubernetes too.
- `--privileged` (or any `CAP_SYS_ADMIN`-equivalent grant) is not "a bit
  more risk" — it's full host disk/device access. Never allow it for CI
  jobs; this is exactly what Kubernetes Pod Security admission/RuntimeClass
  policy needs to reject by default (Project 2 checkpoint).
