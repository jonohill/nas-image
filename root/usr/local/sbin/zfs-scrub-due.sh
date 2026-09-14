#!/bin/sh
# Exit 0 when the pool should be scrubbed now, 1 when it should not.
set -eu

pool=$1
max_age_days=${SCRUB_MAX_AGE_DAYS:-30}

# A paused scrub still reports SCANNING and must be resumed. A resilver
# blocks scrubbing. Anything else is due once the last scrub is old enough.
/usr/sbin/zpool status -j --json-int "$pool" | jq -e \
    --arg pool "$pool" --argjson now "$(date +%s)" --argjson max_age_days "$max_age_days" '
    .pools[$pool].scan_stats // {} |
    if .function == "RESILVER" and .state == "SCANNING" then false
    elif .function == "SCRUB" and .state == "SCANNING" then true
    elif .function == "SCRUB" and .state == "FINISHED" then
        ($now - .end_time) > ($max_age_days * 86400)
    else true
    end' > /dev/null
