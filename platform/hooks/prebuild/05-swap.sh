#!/usr/bin/env bash
set -euo pipefail
# EB env 로드(있으면)
[ -f /opt/elasticbeanstalk/deployment/env ] && . /opt/elasticbeanstalk/deployment/env

SIZE_GB="${SWAP_SIZE_GB:-2}"
SWAPFILE="/swapfile"

if ! grep -q "swap" /proc/swaps; then
  echo "[swap] creating ${SIZE_GB}G swapfile at ${SWAPFILE}"
  fallocate -l "${SIZE_GB}G" "${SWAPFILE}" 2>/dev/null || dd if=/dev/zero of="${SWAPFILE}" bs=1M count="$((SIZE_GB*1024))"
  chmod 600 "${SWAPFILE}"
  mkswap "${SWAPFILE}"
  swapon "${SWAPFILE}"
  if ! grep -q "${SWAPFILE}" /etc/fstab; then
    echo "${SWAPFILE} swap swap defaults 0 0" >> /etc/fstab
  fi
  sysctl -w vm.swappiness=60 >/dev/null
fi