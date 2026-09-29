#!/usr/bin/env bash
# #2064: every host that finishes reconciling rewrites the whole CHI .status with a
# read-modify-write, so hosts finishing together collide on the same resourceVersion and retry.
# Reproduced when the API server rejects any of the operator's CHI writes with 409 Conflict
# during one concurrent roll.
#
# Mechanism, read at release-0.26.3 through master (pkg/controller/chi/kube/cr.go is byte-identical
# from 0.27.3 to master). statusUpdateProcess does Get, EnsureStatus().CopyFrom, then a whole-object
# UpdateStatus carrying the resourceVersion from that Get, wrapped in statusUpdateRetry with
# maxRetryAttempts = 50 and a flat 1 second sleep. There is no Patch path for status. Each host
# completing writes the same single CHI object, so concurrent hosts race. Before every CR write,
# including every retry, statusUpdate PUTs the status ConfigMap, which is built without a
# resourceVersion and so never conflicts: a losing attempt still overwrites it.
# PR #2067 only memoizes ActionPlan.String(), which the status path called once per attempt, so it
# lowers the cost of each attempt and not the number of attempts.
source "$(dirname "$0")/../../lib/common.sh"

NS=it-2064
export CHI=conflicts
SHARDS="${SHARDS:-8}"
# The control rolls the same hosts one shard at a time, so no two status writes race.
if [[ "${CONTROL}" == "1" ]]; then threads=1; else threads="${SHARDS}"; fi

scale_chi_up "${NS}" "${SHARDS}" "${threads}"
since="$(audit_now)"; roll_start="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
duration="$(scale_chi_change "${NS}" ROLL=2)"
[[ "${duration}" =~ ^[0-9]+$ ]] || die "change did not complete"
[[ "${duration}" =~ ^[0-9]+$ ]] || die "change did not complete"

events="$(audit_events_since "${since}" | jq -c 'select(.objectRef.resource=="clickhouseinstallations" and (.verb=="update" or .verb=="patch"))')"
writes="$(grep -c . <<< "${events}" || true)"
status_writes="$(jq -c 'select(.objectRef.subresource=="status")' <<< "${events}" | grep -c . || true)"
conflicts="$(jq -c 'select(.responseStatus.code==409)' <<< "${events}" | grep -c . || true)"
operator_logs --since-time="${roll_start}" 2>/dev/null | grep 'the object has been modified' | artifact operator-conflict-lines.log
log_conflicts="$(grep -c . "${ARTIFACT_DIR}/operator-conflict-lines.log" || true)"
jq -c '{t: .requestReceivedTimestamp, verb, sub: .objectRef.subresource, rv: .objectRef.resourceVersion, code: .responseStatus.code}' <<< "${events}" | artifact chi-writes.jsonl

evidence="${SHARDS} hosts, shard concurrency ${threads}, rolled in ${duration}s: ${writes} CHI writes (${status_writes} to /status), ${conflicts} rejected with 409, ${log_conflicts} conflict retries in the operator log during the roll"
verdict "$(( conflicts > 0 ? 1 : 0 ))" "${evidence}"
