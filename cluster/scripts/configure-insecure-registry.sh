#!/usr/bin/env bash
# Configures containerd on every node to trust a plain-HTTP (insecure)
# registry, for the internal cluster registry deployed via registry.yaml.
#
# Two containerd 2.x quirks this works around (see Project 3 README for
# the full debugging story):
#   1. `certs.d`/hosts.toml requires config_path to point at
#      /etc/containerd/certs.d under the NEW plugin path
#      ([plugins.'io.containerd.cri.v1.images'.registry]), not the old
#      io.containerd.grpc.v1.cri path — already the default in this
#      containerd version, so no config.toml edit needed for that part.
#   2. containerd 2.x's CRI "transfer service" pull path does NOT reliably
#      honor certs.d insecure-HTTP host overrides. Fix: set
#      use_local_image_pull = true to revert CRI pulls to the classic
#      resolver, which does honor certs.d.
#
# Usage: ./configure-insecure-registry.sh <registry-host:port> <node-ip> [<node-ip>...]
set -euo pipefail

REGISTRY="$1"
shift
NODE_IPS=("$@")

for ip in "${NODE_IPS[@]}"; do
  echo "=== configuring containerd on $ip for insecure registry $REGISTRY ==="
  ssh -o BatchMode=yes "edouard@$ip" "
    sudo mkdir -p '/etc/containerd/certs.d/${REGISTRY}'
    cat <<EOF | sudo tee '/etc/containerd/certs.d/${REGISTRY}/hosts.toml' > /dev/null
server = \"http://${REGISTRY}\"

[host.\"http://${REGISTRY}\"]
  capabilities = [\"pull\", \"resolve\", \"push\"]
EOF
    if ! grep -q 'use_local_image_pull = true' /etc/containerd/config.toml; then
      sudo sed -i '/use_local_image_pull = false/d' /etc/containerd/config.toml
      sudo sed -i \"/\\[plugins.'io.containerd.cri.v1.images'\\]/a\\\\    use_local_image_pull = true\" /etc/containerd/config.toml
    fi
    sudo systemctl restart containerd
    sleep 2
    sudo systemctl is-active containerd
  "
done
