# Project 5 — Disaster exercises

## Goal

Make the platform operationally credible by deliberately breaking it and
practicing recovery, rather than assuming backups/HA work because they exist
on paper.

## Drills

- [ ] Kill a worker node mid-build; confirm the job reschedules and observe
      how long it takes.
- [ ] Fill a worker's disk; confirm eviction/disk-pressure handling works and
      doesn't take down unrelated pods.
- [ ] Disable a simulated top-of-rack network link (drop a veth/bridge on the
      host); observe how the cluster and CNI react.
- [ ] Lose one control-plane node (of three); confirm the API server and etcd
      quorum survive.
- [ ] Full etcd snapshot + restore exercise on a scratch cluster.
- [ ] Reinstall a node from nothing (reprovision, rejoin) and time it.
- [ ] Rotate runner/service-account credentials without downtime.
- [ ] Revoke access for a "compromised" CI job mid-run (network policy +
      credential revocation) and confirm blast radius is actually contained.

## Notes / findings

Record what broke, what the actual recovery time was, and what the drill
revealed that the docs/dashboards didn't already show.
