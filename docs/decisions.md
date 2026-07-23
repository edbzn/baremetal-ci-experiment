# Decisions log

Lightweight ADRs. One entry per non-obvious choice — what was chosen, what
the alternative was, and why. Keep it short.

## Template

### YYYY-MM-DD — Title

**Decision:** ...

**Alternatives considered:** ...

**Why:** ...

**Revisit if:** ...

### 2026-07-23 — Relax kernel.apparmor_restrict_unprivileged_userns for rootless BuildKit

**Decision:** Set `kernel.apparmor_restrict_unprivileged_userns=0` host-wide via
`/etc/sysctl.d/99-userns.conf` on this learning box.

**Alternatives considered:** A host AppArmor profile for
`/usr/bin/rootlesskit` (doesn't apply to containerized processes — verified
by testing, still failed after adding it); running BuildKit non-rootless as
root-in-container instead (would have avoided the sysctl change but skips
the rootless-build lesson this project is meant to cover); `--privileged`
container (works but defeats the purpose of testing rootless boundaries).

**Why:** Ubuntu 26.04 blocks unprivileged (nested) user namespaces by
default at the kernel/AppArmor level. `moby/buildkit:rootless` needs to
create a nested userns inside the container's own userns, which this
restriction blocks regardless of the container's own AppArmor confinement.
Fully unconfining the container (`apparmor=unconfined`,
`seccomp=unconfined`, `systempaths=unconfined`) still wasn't enough — the
gate is a global kernel sysctl, not a per-container policy.

**Revisit if:** moving any of this to a shared or production host — the
restriction exists specifically because unprivileged user namespaces are a
meaningful privilege-escalation/kernel-attack-surface vector, so relaxing it
host-wide is a real (if small) security tradeoff, acceptable here but not
somewhere multi-tenant.

### 2026-07-23 — Kata Containers (kata-qemu) only for genuinely high-risk CI jobs, not by default

**Decision:** Use plain `runc` as the default RuntimeClass for all CI jobs.
Reserve `kata-qemu` for a specific, narrow class of jobs: those that must
run genuinely untrusted/adversarial code (e.g. building an image from a
PR opened by an unknown external contributor, running a job that needs
`privileged`-adjacent capabilities for a legitimate reason) where a
container-escape would otherwise put the shared host kernel — and every
other pod scheduled on it — directly at risk.

**Alternatives considered:** Kata by default for all CI jobs (simplest
policy, but the measured costs below make this the wrong default for a
platform aiming for "highest density" trusted-job throughput); Kata only
for the specific job *steps* that touch untrusted input, with the rest of
a pipeline on runc (more precise, but adds RuntimeClass-switching
complexity across a single CI pipeline's stages — worth revisiting later,
not adopted now).

**Why:** Measured directly on this cluster (Project 4 step 4), not
assumed: `kata-qemu` costs ~3.5x cold-start latency, ~300MB fixed memory
+ 250m fixed CPU overhead per pod (accounted for correctly by the
RuntimeClass's own `overhead` field), ~33x disk write throughput
reduction and ~18x network throughput reduction versus plain `runc` on
identical hardware. None of these are prohibitive for a small number of
high-risk jobs, but applied to every job by default they would
substantially cut achievable parallelism (measured: CPU overhead alone
capped a 2-vCPU node at ~8 Kata pods before scheduling failures) and slow
down exactly the I/O-heavy work (checkout, dependency install, compile,
layer export) that dominates real CI job duration. The isolation
boundary itself is real and verified (separate guest kernel, confirmed
via mismatched `uname` output; real QEMU process with `accel=kvm`) —
the finding here is about cost, not about whether the isolation is
genuine.

**Revisit if:** (a) the CI platform's trust model changes such that most
jobs are effectively untrusted (e.g. becoming a public build service),
making Kata-by-default the correct tradeoff despite the cost; (b) a
future Kata/hypervisor version meaningfully closes the I/O gap (virtio-fs
performance work is an active upstream area); (c) node CPU:memory ratios
change enough that the "CPU is the binding constraint" finding from this
cluster's specific 2vCPU/3GB nodes no longer holds — re-measure rather
than assume it transfers to different hardware.
