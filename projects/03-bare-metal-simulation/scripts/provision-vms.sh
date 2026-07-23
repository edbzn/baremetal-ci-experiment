#!/usr/bin/env bash
# Provisions N VMs on the default libvirt network using the Ubuntu 24.04
# cloud image + cloud-init, standing in for bare-metal nodes.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGES_DIR="$PROJECT_DIR/vm-images"
CLOUDINIT_DIR="$PROJECT_DIR/cloud-init"
BASE_IMAGE="$IMAGES_DIR/noble-base.img"
POOL="ci-vms"
SSH_PUBKEY=$(cat ~/.ssh/id_rsa.pub)

VCPUS=2
MEMORY_MB=3072
DISK_GB=20

create_vm() {
  local name="$1"
  local seed_iso="$IMAGES_DIR/${name}-seed.iso"
  local disk="$IMAGES_DIR/${name}.qcow2"

  echo "=== Creating VM: $name ==="

  sed -e "s/__HOSTNAME__/${name}/" -e "s|__SSH_PUBKEY__|${SSH_PUBKEY}|" \
    "$CLOUDINIT_DIR/user-data.tmpl.yaml" > "$IMAGES_DIR/${name}-user-data.yaml"

  cat > "$IMAGES_DIR/${name}-meta-data.yaml" <<EOF
instance-id: ${name}
local-hostname: ${name}
EOF

  sg libvirt -c "cloud-localds '$seed_iso' '$IMAGES_DIR/${name}-user-data.yaml' '$IMAGES_DIR/${name}-meta-data.yaml'"

  qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMAGE" "$disk" "${DISK_GB}G"

  sg libvirt -c "virt-install \
    --name '$name' \
    --memory '$MEMORY_MB' \
    --vcpus '$VCPUS' \
    --disk path='$disk',format=qcow2,bus=virtio \
    --disk path='$seed_iso',device=cdrom \
    --os-variant ubuntu24.04 \
    --network network=default,model=virtio \
    --graphics none \
    --console pty,target_type=serial \
    --import \
    --noautoconsole"
}

for name in "$@"; do
  create_vm "$name"
done

echo "Waiting for VMs to boot and get DHCP leases..."
sleep 20
sg libvirt -c "virsh net-dhcp-leases default"
