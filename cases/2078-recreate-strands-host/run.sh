#!/usr/bin/env bash
# #2078: a Recreate whose pod will not terminate within reconcile.statefulSet.update.timeout
# aborts after the delete and leaves the host with no running pod until a later reconcile.
# Reproduced when, after the reconcile has finished, some host has no Ready pod.
#
# Mechanism, read at release-0.27.3 and release-0.27.4. recreateStatefulSet returns the delete
# error before it reaches createStatefulSet, and that early return is still there at master; the
# fix works by making the delete succeed. doDeleteStatefulSet scales to 0, and a pod wedged in
# shutdown keeps reporting Ready so ReadyReplicas never reaches 0 and the poll spends its whole
# budget. 0.27.4 captures that wait error and, only when it is poller.ErrTimeout, force-deletes the
# pod with grace period 0 so the delete can complete in the same pass. On 0.26.3 the delete error
# is discarded at the call site and the create is attempted anyway, so both hosts end at
# Replicas=0 while the CR still reports Completed. Both controllers share this code, so the Keeper
# side is covered by the same change.
source "$(dirname "$0")/../../lib/common.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"

NS=it-2078
export CHI=wedge
WINDOW="${WINDOW:-420}"
SETTLE="${SETTLE:-90}"
selector="clickhouse.altinity.com/chi=${CHI}"
# The control runs the same Recreate with pods that terminate promptly, so the delete never times out.
if [[ "${CONTROL}" == "1" ]]; then export PRESTOP_SLEEP=0 GRACE=5; else export PRESTOP_SLEEP=900 GRACE=900; fi

operator_install "${HERE}/chopconf.yaml"
fresh_namespace "${NS}"

DATA_VCT=data-a render "${HERE}/chi.yaml" | k -n "${NS}" apply -f - >/dev/null
wait_chi_completed "${NS}" "${CHI}" 600 || die "baseline CHI never reached Completed"
wait_pods_ready "${NS}" "${selector}" 2 300 || die "baseline pods never became Ready"

# Switching the data volume claim template renames the StatefulSet's volumeClaimTemplates entry,
# which is immutable, so the operator has to delete and recreate each host's StatefulSet.
log "switching dataVolumeClaimTemplate to force a Recreate"
DATA_VCT=data-b render "${HERE}/chi.yaml" | apply_and_wait_started chi "${NS}" "${CHI}" \
    || die "operator never started a reconcile for the change"

start=$SECONDS; min_ready=2; terminal_at=""
while (( SECONDS - start < WINDOW )); do
    r="$(ready_pod_count "${NS}" "${selector}")"
    (( r < min_ready )) && min_ready="${r}" && log "Ready pods now ${r}/2"
    st="$(chi_status "${NS}" "${CHI}")"
    if [[ "${st}" == Completed || "${st}" == Aborted ]]; then
        [[ -z "${terminal_at}" ]] && terminal_at=$SECONDS && log "CHI status ${st}, settling ${SETTLE}s"
        (( SECONDS - terminal_at >= SETTLE )) && break
    else
        terminal_at=""
    fi
    sleep 3
done

ready="$(ready_pod_count "${NS}" "${selector}")"
status="$(chi_status "${NS}" "${CHI}")"
stranded=()
for h in 0 1; do
    sts="chi-${CHI}-main-${h}-0"
    replicas="$(k -n "${NS}" get sts "${sts}" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo absent)"
    host_ready="$(ready_pod_count "${NS}" "${selector},statefulset.kubernetes.io/pod-name=${sts}-0")"
    [[ "${host_ready}" == 0 ]] && stranded+=("${sts}(replicas=${replicas:-absent})")
done
force_event="$(k -n "${NS}" get events --field-selector reason=HostPodForceDeleted --no-headers 2>/dev/null | wc -l | tr -d ' ')"
aborted_event="$(k -n "${NS}" get events --no-headers 2>/dev/null | grep -c 'Recreate aborted' || true)"

evidence="preStop sleep ${PRESTOP_SLEEP}s: ready pods ${ready}/2 after reconcile (min ${min_ready}), CHI status ${status}, stranded [${stranded[*]:-none}], recreate-aborted events ${aborted_event}, force-delete events ${force_event}"
verdict "$(( ${#stranded[@]} > 0 ? 1 : 0 ))" "${evidence}"
