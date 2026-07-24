# Side experiment — Docker-in-Docker (DinD) vs. Docker-outside-of-Docker (DooD) vs. rootless BuildKit

Prompted by wanting to understand a common CI pattern ("the CI job itself
needs to build/run Docker images") beyond the rootless-BuildKit approach
already used in Project 1. This compares three ways CI systems commonly
solve that problem, and what each actually grants a build job.

## The three approaches

1. **DinD (Docker-in-Docker)**: run `docker:dind` as a container, with
   `--privileged`. A genuinely separate, nested `dockerd` runs inside it,
   with its own storage, its own container namespace, its own
   `/var/run/docker.sock` — isolated from the host's real Docker daemon.
2. **DooD (Docker-outside-of-Docker)**: mount the **host's real**
   `/var/run/docker.sock` into a container. The container doesn't run its
   own daemon at all — it just talks to the host's daemon directly.
3. **Rootless BuildKit** (Project 1's approach): no daemon-socket sharing at
   all, no `--privileged`; builds happen via a nested *unprivileged* user
   namespace instead of shared root access.

## What was actually tested

```bash
# 1. DinD
docker run -d --name dind-test --privileged --network ci-experiment \
  -e DOCKER_TLS_CERTDIR="" docker:27-dind
docker exec dind-test sh -c 'mkdir -p /tmp/app && cd /tmp/app && \
  printf "FROM alpine:3.20\nCMD echo hello-from-nested-docker\n" > Dockerfile && \
  docker build -t nested-test . && docker run --rm nested-test'

# 2. DooD
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock:ro docker:27-cli docker ps
```

## Findings

### DinD is genuinely isolated from the host's Docker daemon

- Build+run loop worked fully inside the nested dockerd
  (`hello-from-nested-docker` printed correctly).
- `docker exec dind-test docker ps` (querying the **nested** daemon) showed
  an **empty** list, while the real host's `docker ps` at the same moment
  showed 6 running containers (`ci-registry`, `ci-buildkitd`, the kind
  cluster's 3 nodes, `mongodb`, plus `dind-test` itself). This is decisive
  proof the nested `/var/run/docker.sock` inside the DinD container is a
  **different, separate socket** talking to a **different, separate
  daemon** — not a leak of the host's real Docker state.
- `--privileged` still grants the same things measured in Project 1: full
  effective capabilities (`CapEff: 000001ffffffffff`) and visibility of the
  host's real block devices (`nvme0n1`, `dm-0`, `dm-1` under `/dev`). DinD's
  isolation is about the **Docker daemon/container namespace** specifically
  being nested and separate — it does **not** avoid the broader
  `--privileged` capability/device grant. A malicious build inside a DinD
  container still has the same raw host-kernel access as any other
  `--privileged` container; it's just that "can it see the host's actual
  running containers/images" specifically is not one of the things it
  gains for free.

### DooD is a direct, unrestricted line to the real host

- A container with **zero** special flags — no `--privileged`, no extra
  capabilities — but with `-v /var/run/docker.sock:/var/run/docker.sock`
  mounted, ran `docker ps` and saw the **exact same** container list as the
  real host, live.
- Taken one step further (run with explicit user approval, since it's a
  genuine host-filesystem-mount action): that same unprivileged-looking
  container instructed the host's real Docker daemon to start a **new**
  container with the **host's actual root filesystem** bind-mounted in
  (`-v /:/hostfs:ro`), and read a real host file
  (`/etc/hostname` → the actual machine hostname). No privilege escalation
  syscall was needed — asking the host's own daemon to do it was
  sufficient, because whoever can talk to `docker.sock` can ask the daemon
  to do *anything* the daemon (running as root) can do, including mounting
  arbitrary host paths into a container it creates for you.
- This is the concrete mechanism behind the roadmap's explicit warning:
  *"Avoid making /var/run/docker.sock available to arbitrary build
  pods. Mounting the host Docker socket effectively gives the job broad
  control over the node."* It's not hyperbole — it's a two-command proof.

### Comparison

| Approach | Needs `--privileged`? | Sees host's real containers? | Can escape to host filesystem? | Isolation mechanism |
|---|---|---|---|---|
| DinD | Yes | No (separate nested daemon) | Only via the same host-kernel access any `--privileged` container has (device/capability grant), not via the docker.sock specifically | Nested dockerd + its own storage/namespace, but still relies on the *same* kernel-level `--privileged` grant Project 1 already showed is dangerous |
| DooD | No | **Yes** (same host daemon) | **Yes, trivially** (proven above) | None — the container is a thin client to the real host daemon |
| Rootless BuildKit (Project 1) | No | N/A (no Docker daemon socket involved at all) | No (needs a nested *unprivileged* userns, actively blocked more by host policy, not less) | Unprivileged user namespace, no daemon/socket sharing of any kind |

**Conclusion:** DinD is safer than DooD (no direct host-daemon access,
genuinely separate container state) but is *not* actually safe on its own —
it still requires the same `--privileged` grant that Project 1 already
showed hands out full host block-device access and capabilities. DooD is
categorically worse: it requires no special container flags at all to
reach full host compromise, because the vulnerability isn't in the
container's own privilege level, it's in what the *daemon on the other end
of the socket* is willing to do for anyone who can reach it. Rootless
BuildKit (Project 1's approach) is the only one of the three that avoids
both problems — no daemon-socket sharing, and no `--privileged` grant —
which is exactly why the roadmap's CI image-building guidance leads with
it rather than either Docker-based option.

**Where this connects forward:** in Project 4 (Kata Containers), it will
be worth revisiting whether DinD *inside* a Kata microVM meaningfully
changes this picture — the microVM boundary would contain the
`--privileged` capability grant to the guest kernel rather than the real
host kernel, which is a plausible way to make DinD's convenience safe for
genuinely untrusted build jobs. That's a concrete, testable question for
that project rather than something to assume here.
