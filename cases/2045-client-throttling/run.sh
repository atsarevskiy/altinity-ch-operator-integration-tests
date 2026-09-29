#!/usr/bin/env bash
# #2045: unless OPERATOR_K8S_CLIENT_QPS_LIMIT / OPERATOR_K8S_CLIENT_BURST_LIMIT are set, the
# operator runs on the client-go defaults however much reconcile concurrency is configured, and
# nothing tells the user. With QPS unset, client-go gives each API group's client its own
# 5 QPS / burst 10 bucket, so the StatefulSet traffic (the apps group, most of a reconcile) is
# capped at 5 requests/s.
#
# The same concurrent roll runs twice: on the defaults, then with the limits raised. Reproduced
# when the default run is throttled (client-go logs throttling waits and apps-group traffic stays
# within one 5 QPS / burst 10 bucket) while the raised run shows the reconcile wanted more (its
# apps-group peak is above what that bucket allows), and the operator logged nothing about the
# limit at startup.
source "$(dirname "$0")/../../lib/common.sh"

NS=it-2045
export CHI=throttle
SHARDS="${SHARDS:-12}"

# apps-group requests per second from the operator in [since, until): "<p50> <p90> <max> <total>".
apps_rate() {
    audit_events_since "$1" \
        | jq -r --arg until "$2" 'select(.requestReceivedTimestamp < $until and .objectRef.apiGroup == "apps") | .requestReceivedTimestamp[0:19]' \
        | sort | uniq -c | awk '{print $1}' | sort -n \
        | awk '{a[NR]=$1; s+=$1} END {if (NR == 0) {print "0 0 0 0"; exit} printf "%d %d %d %d\n", a[int((NR+1)/2)], a[int(NR*0.9+0.5)], a[NR], s}'
}

# The control sets the limits from the start, so the first roll is not on the client-go defaults.
if [[ "${CONTROL}" == "1" ]]; then
    first_env=(OPERATOR_K8S_CLIENT_QPS_LIMIT=200 OPERATOR_K8S_CLIENT_BURST_LIMIT=400)
else
    first_env=()
fi

scale_chi_up "${NS}" "${SHARDS}" "${SHARDS}" "${first_env[@]}"
startup_mentions="$(operator_logs 2>/dev/null | grep -ciE 'OPERATOR_K8S_CLIENT|QPS' || true)"

t0="$(date -u +%Y-%m-%dT%H:%M:%SZ)"; since="$(audit_now)"
default_s="$(scale_chi_change "${NS}" ROLL=2)"
[[ "${default_s}" =~ ^[0-9]+$ ]] || die "roll on default limits did not complete"
read -r d_p50 d_p90 d_max d_total <<< "$(apps_rate "${since}" "$(audit_now)")"
operator_logs --since-time="${t0}" 2>/dev/null | grep 'due to client-side throttling' | artifact default-throttling-waits.log
d_throttle="$(grep -c . "${ARTIFACT_DIR}/default-throttling-waits.log" || true)"
audit_events_since "${since}" | jq -r 'select(.objectRef.apiGroup == "apps") | .requestReceivedTimestamp[0:19]' | sort | uniq -c | artifact default-apps-requests-per-second.txt

conf="${CACHE_DIR}/chopconf-concurrent-${SHARDS}.yaml"
operator_install "${conf}" OPERATOR_K8S_CLIENT_QPS_LIMIT=200 OPERATOR_K8S_CLIENT_BURST_LIMIT=400
wait_chi_completed "${NS}" "${CHI}" 600 || die "CHI not Completed after operator restart"
sleep 30
since="$(audit_now)"
raised_s="$(scale_chi_change "${NS}" ROLL=3)"
[[ "${raised_s}" =~ ^[0-9]+$ ]] || die "roll on raised limits did not complete"
read -r r_p50 r_p90 r_max r_total <<< "$(apps_rate "${since}" "$(audit_now)")"
audit_events_since "${since}" | jq -r 'select(.objectRef.apiGroup == "apps") | .requestReceivedTimestamp[0:19]' | sort | uniq -c | artifact raised-apps-requests-per-second.txt

evidence="${SHARDS} hosts rolled concurrently. Defaults: ${default_s}s, apps requests/s median ${d_p50}, p90 ${d_p90}, max ${d_max} (${d_total} total), ${d_throttle} throttling waits logged. QPS 200/burst 400: ${raised_s}s, apps requests/s median ${r_p50}, p90 ${r_p90}, max ${r_max} (${r_total} total). Startup log lines about the client limit: ${startup_mentions}"
verdict "$(( d_throttle > 0 && d_max <= 16 && r_max > 16 && startup_mentions == 0 ? 1 : 0 ))" "${evidence}"
