#!/usr/bin/env bash
# #2035: a CHK whose in-flight reconcile is cut short (operator restart, or a newer spec that
# supersedes it) can stay status InProgress forever once the ensemble has converged, because the
# next reconcile finds no work and never finalizes. Reproduced when the ensemble is fully Ready
# and quiet for SETTLE seconds but the CHK status is still not Completed.
#
# TRIGGER=restart (default): kill the operator while it repairs a deleted member StatefulSet.
# CONTROL=1: repair the same drift without killing anything, so the reconcile reaches its finalize.
# TRIGGER=supersede: apply a second spec change while the first one is still reconciling.
source "$(dirname "$0")/../../lib/common.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"

NS=it-2035
export CHK=stuck
TRIGGER="${TRIGGER:-restart}"
SETTLE="${SETTLE:-180}"
selector="clickhouse-keeper.altinity.com/chk=${CHK}"

operator_install
fresh_namespace "${NS}"

SESSION_TIMEOUT_MS=30000 render "${HERE}/chk.yaml" | k -n "${NS}" apply -f - >/dev/null
wait_chk_completed "${NS}" "${CHK}" 600 || die "baseline CHK never reached Completed"
wait_pods_ready "${NS}" "${selector}" 3 300 || die "baseline keeper pods never became Ready"

sts_uid() { k -n "${NS}" get sts "chk-${CHK}-main-0-2" -o jsonpath='{.metadata.uid}' 2>/dev/null; }
sts_replaced() { local u; u="$(sts_uid)"; [[ -n "${u}" && "${u}" != "$1" ]]; }

case "${TRIGGER}" in
    restart)
        # Losing a member's StatefulSet is drift the operator repairs without any spec change.
        # Once it has recreated the StatefulSet there's nothing left to repair, so a reconcile
        # that is interrupted from here on leaves no work for the next one.
        old_uid="$(sts_uid)"
        log "deleting one member's StatefulSet"
        k -n "${NS}" delete sts "chk-${CHK}-main-0-2" --wait=false >/dev/null
        wait_until 180 "operator recreated the StatefulSet" sts_replaced "${old_uid}" \
            || die "operator never recreated the deleted StatefulSet"
        # Killed rather than deleted gracefully: in its grace period the old pod can finish the
        # reconcile, and a crash or OOM kill is what leaves a reconcile half done.
        if [[ "${CONTROL}" == "1" ]]; then
            log "CHK status $(chk_status "${NS}" "${CHK}"), leaving the operator alone"
        else
            log "CHK status $(chk_status "${NS}" "${CHK}"), killing the operator mid-reconcile"
            k -n "${OPERATOR_NS}" delete pod -l app=clickhouse-operator --grace-period=0 --force >/dev/null 2>&1
        fi
        ;;
    supersede)
        SESSION_TIMEOUT_MS=31000 render "${HERE}/chk.yaml" | apply_and_wait_started chk "${NS}" "${CHK}" \
            || die "first change never started reconciling"
        sleep 5
        log "superseding the in-flight reconcile with a second change"
        SESSION_TIMEOUT_MS=32000 render "${HERE}/chk.yaml" | k -n "${NS}" apply -f - >/dev/null
        ;;
    *) die "TRIGGER must be restart or supersede" ;;
esac

k -n "${OPERATOR_NS}" rollout status deployment/clickhouse-operator --timeout=180s >&2 || die "operator did not come back"
wait_pods_ready "${NS}" "${selector}" 3 600 || die "ensemble never converged"
log "ensemble Ready, watching status for ${SETTLE}s"
start=$SECONDS
while (( SECONDS - start < SETTLE )); do
    [[ "$(chk_status "${NS}" "${CHK}")" == Completed ]] && break
    sleep 5
done

status="$(chk_status "${NS}" "${CHK}")"
started="$(k -n "${NS}" get chk "${CHK}" -o json | jq '.status.taskIDsStarted | length')"
completed="$(k -n "${NS}" get chk "${CHK}" -o json | jq '.status.taskIDsCompleted | length')"
ready="$(ready_pod_count "${NS}" "${selector}")"
no_work="$(operator_logs 2>/dev/null | grep "${NS}/${CHK}" | grep -c "No reconcile work" || true)"
label="trigger ${TRIGGER}"
[[ "${CONTROL}" == "1" ]] && label+=" (control, operator left running)"
evidence="${label}: status ${status} with ${ready}/3 Ready after ${SETTLE}s quiet, taskIDsStarted ${started}, taskIDsCompleted ${completed}, 'No reconcile work' reconciles after restart ${no_work}"
failed=0; [[ "${status}" != Completed ]] && failed=1
verdict "${failed}" "${evidence}"
