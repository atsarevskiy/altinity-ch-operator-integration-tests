#!/usr/bin/env bash
# #2069: when the CHK controller has to recreate the StatefulSets of an existing ensemble it
# doesn't make sure a recreated member rejoined before recreating the next one, so the ensemble
# can drop below Raft quorum. Reproduced when fewer than 2 of 3 members serve for at least
# LOSS_SECONDS in a row (a leader re-election alone is well under that).
#
# Mechanism, read at release-0.27.3 and release-0.27.4. The issue blames a skipped readiness wait
# for a host with no ancestor, but the Keeper controller does wait: the ancestor comes from
# .status.normalizedCompleted, which deleting a StatefulSet does not clear, so HasAncestor stays
# true and prepareStsReconcileOptsWaitSection sets SetWaitUntilReady. The wait then times out and
# the cascade continues because the Keeper controller is wired to statefulset.NewDefaultFallback(),
# whose OnStatefulSetCreateFailed returns ErrCRUDIgnore unconditionally; the reconciler maps that
# to nil, so the host walk sees success. That is hardcoded, not configuration:
# reconcile.statefulSet.create.onFailure is read only by the ClickHouse controller. 0.27.4 swaps in
# newChkStatefulSetFallback (returns ErrCRUDAbort) and adds ensureQuorumSafeToDisruptHost, which
# refuses to disrupt a member when fewer than members/2+1 would stay Ready, after waiting a
# hardcoded 2 minute per-pass budget.
#
# REPLACEMENT=broken (default): the replacement member can't start (its volume never binds),
#   which is what the reported fleet-wide recreate ran into.
# REPLACEMENT=slow: the replacement starts after START_DELAY seconds.
source "$(dirname "$0")/../../lib/common.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"

NS=it-2069
export CHK=ens
WINDOW="${WINDOW:-600}"
LOSS_SECONDS="${LOSS_SECONDS:-10}"
selector="clickhouse-keeper.altinity.com/chk=${CHK}"

operator_install "${HERE}/chopconf.yaml"
fresh_namespace "${NS}"

# CONTROL=1 uses replacements that start normally, so a Recreate of every member should keep quorum.
[[ "${CONTROL}" == "1" ]] && REPLACEMENT="${REPLACEMENT:-slow}"
REPLACEMENT="${REPLACEMENT:-broken}"
case "${REPLACEMENT}" in
    broken) export DATA_B_STORAGE_CLASS=does-not-exist CHANGE_START_DELAY=0 ;;
    slow)   export DATA_B_STORAGE_CLASS=local-path CHANGE_START_DELAY="${START_DELAY:-60}" ;;
    *) die "REPLACEMENT must be broken or slow" ;;
esac
export DATA_B_STORAGE_CLASS

DATA_VCT=data-a START_DELAY=0 render "${HERE}/chk.yaml" | k -n "${NS}" apply -f - >/dev/null
wait_chk_completed "${NS}" "${CHK}" 600 || die "baseline CHK never reached Completed"
wait_pods_ready "${NS}" "${selector}" 3 300 || die "baseline keeper pods never became Ready"
keeper_probe_start "${NS}" "chk-${CHK}-main-0-0 chk-${CHK}-main-0-1 chk-${CHK}-main-0-2"
sleep 5
read -r base_min _ _ <<< "$(keeper_probe_report "${NS}" 2 0)"
[[ "${base_min}" == 3 ]] || die "baseline ensemble not fully serving (min serving ${base_min})"

since="$(date +%s)"
log "switching dataVolumeClaimTemplate (forces a Recreate), replacement=${REPLACEMENT}"
DATA_VCT=data-b START_DELAY="${CHANGE_START_DELAY}" render "${HERE}/chk.yaml" | apply_and_wait_started chk "${NS}" "${CHK}" \
    || die "operator never started a reconcile for the change"

start=$SECONDS; terminal_at=""
while (( SECONDS - start < WINDOW )); do
    st="$(chk_status "${NS}" "${CHK}")"
    if [[ "${st}" == Completed || "${st}" == Aborted ]]; then
        [[ -z "${terminal_at}" ]] && terminal_at=$SECONDS && log "CHK status ${st}"
        (( SECONDS - terminal_at >= 30 )) && break
    else
        terminal_at=""
    fi
    sleep 3
done

k -n "${NS}" logs keeper-probe 2>/dev/null | artifact keeper-probe.log
read -r min_serving longest samples <<< "$(keeper_probe_report "${NS}" 2 "${since}")"
status="$(chk_status "${NS}" "${CHK}")"
recreated="$(k -n "${NS}" get sts -l "${selector}" -o json | jq --argjson s "${since}" \
    '[.items[] | select((.metadata.creationTimestamp | fromdateiso8601) >= $s)] | length')"
ready="$(ready_pod_count "${NS}" "${selector}")"

evidence="replacement ${REPLACEMENT}: min serving members ${min_serving}/3, longest below quorum ${longest}s over ${samples} samples, recreated StatefulSets ${recreated}/3, ready ${ready}/3, CHK status ${status}"
verdict "$(( longest >= LOSS_SECONDS ? 1 : 0 ))" "${evidence}"
