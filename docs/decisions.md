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
