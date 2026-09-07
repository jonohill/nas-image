#!/bin/sh
. /usr/lib/tuned/functions
start() { for p in /sys/bus/pci/devices/*/power/control; do echo auto > "$p"; done; }
stop()  { for p in /sys/bus/pci/devices/*/power/control; do echo on > "$p"; done; }
process "$@"
