#!/usr/bin/env bash
# Takes an etcd snapshot on the control-plane node and copies it off-node
# to this host's etcd-backups/ directory — a snapshot that stays on the
# same disk as the etcd it backs up isn't a real backup.
set -euo pipefail

CP_IP="${1:-192.168.122.140}"
BACKUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/etcd-backups"
TIMESTAMP=$(date +%s)
REMOTE_FILE="/tmp/etcd-snapshot-${TIMESTAMP}.db"

mkdir -p "$BACKUP_DIR"

ssh -o BatchMode=yes "edouard@${CP_IP}" "
  sudo ETCDCTL_API=3 etcdctl \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
    --key=/etc/kubernetes/pki/etcd/healthcheck-client.key \
    snapshot save '${REMOTE_FILE}'
  sudo chown \$(whoami):\$(whoami) '${REMOTE_FILE}'
"

scp -o BatchMode=yes "edouard@${CP_IP}:${REMOTE_FILE}" "$BACKUP_DIR/"
ssh -o BatchMode=yes "edouard@${CP_IP}" "rm -f '${REMOTE_FILE}'"

echo "Snapshot saved to: $BACKUP_DIR/$(basename "$REMOTE_FILE")"
