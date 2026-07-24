# Project 6 — GitHub Actions on the real cluster (Actions Runner Controller)

## Goal

Wire a real GitHub repo's CI to actually run on the bare-metal-simulated
cluster from Project 3, end to end: a real `git push`, a real GitHub
Actions workflow, executed by a self-hosted runner pod scheduled by
Kubernetes on one of our own nodes — not a local runner, not a hosted
GitHub runner.

This is the most "does this actually work as a CI platform" exercise in
the whole roadmap: everything through Project 5 proved individual pieces
(scheduling, isolation, registry, GitOps, disaster recovery) work: this
project proves a real external CI system can drive them together.

## Why Actions Runner Controller (ARC)

The roadmap's CI-integration guidance calls out "Actions Runner
Controller for GitHub Actions" specifically. ARC runs self-hosted GitHub
Actions runners as Kubernetes pods, using an `EphemeralRunnerSet` /
`AutoscalingRunnerSet` that creates one ephemeral runner pod per queued
job — directly matching the "one ephemeral pod per CI job" pattern this
whole roadmap has been building toward since Project 2.

## Network reality check

Our cluster has no public ingress — GitHub.com can't push webhooks
directly to it. ARC's newer architecture doesn't need that: the runner
controller and listener run *inside* the cluster and poll/long-poll
GitHub's API for queued jobs (outbound only), rather than requiring
GitHub to reach in. This is exactly the model needed for a private,
NAT'd, bare-metal-style cluster like ours.

## Auth: GitHub App

Using a GitHub App (not a PAT) scoped narrowly to this repo, installed
just for runner registration — matches GitHub's own recommended approach
for ARC and avoids a broadly-scoped personal token.

## Steps

1. Create a GitHub App with the permissions ARC needs, install it on
   `edbzn/baremetal-ci-experiment`, generate a private key.
2. Install `gha-runner-scale-set-controller` (cert-manager dependency +
   the controller itself) via Helm into the cluster.
3. Install a `gha-runner-scale-set` Helm release configured with the
   GitHub App credentials, pointed at this repo.
4. Add a real `.github/workflows/*.yml` in this repo targeting
   `runs-on: [self-hosted, <runner-scale-set-name>]`.
5. Push a commit, watch a real ephemeral runner pod get scheduled,
   execute the workflow, and report status back to GitHub — verify in
   the GitHub Actions UI, not just cluster-side logs.
6. Break something on purpose: cancel a running job mid-run, kill the
   runner pod directly, watch it recover the way any other pod in this
   roadmap has.

## Notes / findings

### Feasibility confirmed: yes, straightforward

GitHub's Actions Runner Controller (`gha-runner-scale-set-controller` +
`gha-runner-scale-set`, the current Helm-based architecture — not the
older `summerwind/actions-runner-controller` community project) wires up
cleanly to a private, no-public-ingress cluster. No webhook/inbound
network requirement at all: the listener pod maintains a long-poll
connection outbound to `api.github.com`/`broker.actions.githubusercontent.com`,
which is exactly what a NAT'd bare-metal cluster like ours needs.

### Setup

- **Auth**: GitHub App (not a PAT) — two repository permissions only,
  `Administration: Read and write` and `Metadata: Read-only`, no webhook
  subscriptions. Three values extracted (App ID, Installation ID, private
  key `.pem`) and stored as a Kubernetes Secret
  (`github_app_id`/`github_app_installation_id`/`github_app_private_key`
  — exact literal key names the chart expects).
- **Install**: `cert-manager` (a dependency of the controller, for its
  own internal webhook TLS — unrelated to GitHub webhooks) →
  `gha-runner-scale-set-controller` → a `gha-runner-scale-set` release
  configured with `githubConfigUrl` pointed at this repo and
  `nodeSelector: node-role: isolated-ci` (reusing the roadmap's node-pool
  convention from Project 2/4 — untrusted-adjacent CI workload, kept off
  the control-plane and off any node not designated for it).
- **`minRunners: 0`**: no idle runner pods sitting around — genuinely
  scale-to-zero, matching "one ephemeral pod per CI job" rather than
  "N always-on runners."

### End-to-end proof — a real push, a real cluster-executed job

Pushed a commit with a workflow (`runs-on: arc-runner-set`). Confirmed,
not assumed:
- GitHub's run went `queued` → `in_progress` the moment the push landed.
- Simultaneously, a real ephemeral pod
  (`arc-runner-set-rtbcc-runner-<id>`) appeared on `ci-worker2`,
  `ContainerCreating` (pulling `ghcr.io/actions/actions-runner:latest`)
  → `Running` → `Completed`, matching the GitHub run's own
  `queued`→`in_progress`→`completed success` transitions in lockstep.
- **The clincher, straight from GitHub's own captured log output**:
  `kernel: Linux arc-runner-set-rtbcc-runner-nh5n4 6.8.0-134-generic
  #134-Ubuntu ... Ubuntu 24.04.4 LTS` — the exact kernel/OS of our own
  cluster nodes from every other project in this roadmap, visible in
  GitHub's Actions UI as the job's own output. This is not a
  hosted GitHub runner; it's genuinely our bare-metal-simulated cluster.
- After completion: pod gone (`No resources found`), GitHub's own
  registered-runners list also empty (`total_count: 0`) — fully
  ephemeral, no lingering registration either side.

### Break-it: kill the runner pod mid-job

Added a ~5-minute sleep loop step, pushed, waited for the runner pod to
reach `Running`, then `kubectl delete pod ... --force --grace-period=0`
on it directly — simulating a hard node/pod failure mid-CI-run (the same
class of failure as Project 5's node-loss drills, but specifically
targeting a CI job's own runner rather than an infrastructure
component).

**Result:**
- The GitHub Actions run did **not** immediately fail — it stayed
  `in_progress`.
- ARC's `EphemeralRunnerSet` controller detected the runner was gone and
  **automatically created a brand-new replacement pod** (confirmed via
  `kubectl get ephemeralrunners` showing a fresh `RUNNERID` against the
  same `WORKFLOWRUNID`/`JOBID`) — the controller-level recovery worked
  exactly as ARC is designed to.
- **The replacement runner re-ran the entire job from the beginning**,
  not from wherever the killed pod had gotten to — GitHub Actions has no
  mid-step checkpoint/resume mechanism; a lost runner means the whole job
  reattempts on a fresh one. The sleep loop genuinely restarted from
  `tick 1`, confirmed by the new pod's own age tracking against the
  ~5-minute total duration needed.
- **Real operational cost, not just "it recovers"**: killing a runner
  mid-job doesn't lose the CI run outright, but it does cost a full
  job-duration's worth of re-execution — for a quick job this is
  negligible, but for a long build/test suite this is a genuine, sizable
  cost of any infrastructure instability during a run. Directly connects
  to every prior disaster-exercise finding in Project 5: a node loss or
  network blip that would otherwise just reschedule a stateless service
  pod instead throws away real, possibly expensive-to-redo CI work when
  it hits a runner specifically.
- Worth building forward: for genuinely long-running CI jobs, this cost
  argues for either smaller/more granular jobs (so a lost runner loses
  less work) or accepting the redo cost as the tradeoff for the
  simplicity of stateless, ephemeral, ARC-managed runners rather than
  trying to build checkpoint/resume into CI jobs themselves.

### Gaps / not yet explored

- Attempted `gh run cancel` on the still-running retried job as a
  cleanup step, expecting a clean stop. It didn't take effect — the run
  stayed `in_progress` well past when the cancellation was requested.
  Likely explanation, not fully confirmed: a cancellation request needs
  the *current* runner to acknowledge and stop, but this run's runner had
  already been through one forced replacement, and a second manual
  `kubectl delete pod` (to force cleanup) triggered ARC to spin up yet
  another fresh replacement that restarted the job again — i.e., the
  cancellation signal and ARC's automatic-replacement behavior may have
  been racing each other, with replacement "winning" each time. Ended up
  just letting the (now much-shortened) workflow finish naturally rather
  than continuing to fight this. Worth a real, careful follow-up: does
  `gh run cancel` actually reach an ARC-managed ephemeral runner
  reliably, or does forcibly killing/replacing a runner pod interfere
  with graceful cancellation specifically?
- ~~`containerMode` was left at its simplest setting~~ — **now explored**:
  see [`06-github-actions-arc-security-drill.md`](06-github-actions-arc-security-drill.md) for a full
  measured comparison of plain/`dind`/`kubernetes` modes, including a
  real (approved) host-escape probe against `dind` mode's privileged
  sidecar, and a real failed-connection confirmation that `kubernetes`
  mode has no Docker daemon reachable at all without a separately
  provisioned build service. Reverted back to plain-container mode as
  the running default afterward — the comparison's conclusion.
- No autoscaling behavior under real concurrent load was tested
  (`maxRunners: 3`, but only ever exercised one job at a time).
- Setting up `kubernetes` mode surfaced a real gap in Project 3's
  cluster: **no dynamic `StorageClass` existed at all** (needed for that
  mode's required work-volume claim). Installed
  `rancher/local-path-provisioner` to unblock it — worth folding back
  into Project 3's own setup notes as a real, generally-useful gap, not
  something specific to this test.
