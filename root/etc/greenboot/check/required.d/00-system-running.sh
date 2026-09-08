#!/usr/bin/env bash
# greenboot required health check.
#
set -uo pipefail

# `systemctl is-system-running --wait` cannot be used here: it blocks until
# multi-user.target is reached, and that target waits on greenboot itself.
# Instead wait for the remaining running jobs (other than this check) to
# settle, then judge the boot on failed units alone.
running_jobs() {
    systemctl list-jobs --plain --no-legend \
        | awk '$4 == "running" && $2 != "greenboot-healthcheck.service"'
}

for _ in $(seq 1 30); do
    [ -z "$(running_jobs)" ] && break
    sleep 5
done

failed_units() {
    systemctl list-units --state=failed --no-legend --plain | awk '{print $1}'
}

if [ -z "$(failed_units)" ]; then
    echo "System healthy: no failed units."
    exit 0
fi

# Restart=always workloads can be momentarily failed at the instant boot
# finishes; give them a short grace period to recover before condemning the
# deployment.
for i in 1 2 3 4 5 6; do
    sleep 10
    if [ -z "$(failed_units)" ]; then
        echo "System healthy after $((i * 10))s settle."
        exit 0
    fi
done

echo "System degraded; failed units: $(failed_units | tr '\n' ' ')" >&2
exit 1
