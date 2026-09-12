#!/usr/bin/env bash
# A module that does not load means the kmod and kernel disagree; roll back.
set -euo pipefail

modprobe zfs
zpool list > /dev/null
echo "ZFS module loaded."
