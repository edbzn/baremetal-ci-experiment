#!/usr/bin/env bash
# Fixes a real gap in stock kata-fc: EmptyDir volumes default to
# emptydir_mode="shared-fs", which needs virtio-fs — but Firecracker has
# no shared_fs support, so Kata silently falls back to a small
# (~400MB), RAM-backed guest tmpfs instead of erroring. Any pod whose
# EmptyDir needs exceed that (e.g. ARC's dind containerMode, which
# copies several hundred MB of runner externals into one) fails with
# "No space left on device".
#
# Switches to emptydir_mode="block-plain", which plugs a real virtio
# block device for EmptyDir instead of tmpfs — same devmapper mechanism
# already used for kata-fc's container rootfs.
#
# Run on each isolated-ci worker node (over SSH), then re-schedule any
# affected pods — no containerd/kubelet restart needed, Kata reads this
# file fresh per VM boot via the shim.
set -euo pipefail

CONFIG=/opt/kata/share/defaults/kata-containers/runtimes/fc/configuration-fc.toml

sudo sed -i 's/^emptydir_mode = "shared-fs"/emptydir_mode = "block-plain"/' "$CONFIG"
grep -n '^emptydir_mode' "$CONFIG"
