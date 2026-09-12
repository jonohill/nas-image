#!/bin/sh
. /usr/lib/tuned/functions
start() { for p in /sys/bus/pci/devices/*/power/control; do echo auto > "$p"; done; }
stop()  { for p in /sys/bus/pci/devices/*/power/control; do echo on > "$p"; done; }
process "$@"

# The ASMedia ASM1042 xHCI (the two middle rear USB sockets) loses state in
# D3cold and never wakes on plug-in, so its sockets are dead under runtime PM.
# To use them, replace start() with:
#
# asm1042() { [ "$(cat "$1/vendor")" = 0x1b21 ] && [ "$(cat "$1/device")" = 0x1042 ]; }
# start() { for d in /sys/bus/pci/devices/*; do asm1042 "$d" || echo auto > "$d/power/control"; done; }
