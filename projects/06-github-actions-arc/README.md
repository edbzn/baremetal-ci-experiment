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

(fill in as you go)
