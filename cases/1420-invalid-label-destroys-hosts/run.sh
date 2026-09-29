#!/usr/bin/env bash
# #1420 / PR #2071: an invalid pod-template label makes the operator delete a StatefulSet it then
# cannot recreate. Reproduced when any host's StatefulSet is gone after the change.
#
# Mechanism, read at release-0.26.3 through master: a rejected Update becomes ErrCRUDRecreate
# (statefulset-reconciler.go doUpdateStatefulSet), updateStatefulSet calls recreateStatefulSet,
# and that deletes the running StatefulSet before the desired one is validated. The delete-first
# order is the same on every release; what differs is whether the failed create is swallowed.
# shouldAbortOrContinueCreateStatefulSet returns nil on 0.26.3 and 0.27.0 ("Got recreate action.
# Ignore and continue for now"), so the walk moves on and drains every host. From 0.27.1 it
# returns the sentinel instead, so the reconcile stops after the first host. PR #2071 dry-runs the
# desired StatefulSet first and keeps the existing one when the API server rejects it.
# reconcile.statefulSet.recreate.onUpdateFailure=abort also prevents the delete; create.onFailure
# and update.onFailure do not, they are only read on the wait-for-ready paths.
source "$(dirname "$0")/../../lib/common.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"

NS=it-1420
export CHI=labels
WINDOW="${WINDOW:-480}"
# The control changes the same label to a value the API server accepts, so the operator takes the
# same update path without a rejected spec.
if [[ "${CONTROL}" == "1" ]]; then BAD_LABEL=also-ok; else BAD_LABEL=/metrics; fi

operator_install "${HERE}/chopconf.yaml"
fresh_namespace "${NS}"

PROBE_LABEL=ok render "${HERE}/chi.yaml" | k -n "${NS}" apply -f - >/dev/null
selector="clickhouse.altinity.com/chi=${CHI}"
wait_chi_completed "${NS}" "${CHI}" 600 || die "baseline CHI never reached Completed"
wait_pods_ready "${NS}" "${selector}" 3 300 || die "baseline pods never became Ready"
before="$(sts_count "${NS}" "${selector}")"
[[ "${before}" == 3 ]] || die "expected 3 StatefulSets at baseline, got ${before}"

log "applying label value '${BAD_LABEL}'"
PROBE_LABEL="${BAD_LABEL}" render "${HERE}/chi.yaml" | k -n "${NS}" apply -f - >/dev/null

min="${before}"; start=$SECONDS
while (( SECONDS - start < WINDOW )); do
    n="$(sts_count "${NS}" "${selector}")"
    (( n < min )) && min="${n}" && log "StatefulSets now ${n}/${before}"
    (( n == 0 )) && break
    st="$(chi_status "${NS}" "${CHI}")"
    # Aborted is terminal until the next spec change; give a deleted host one more poll to show.
    if [[ "${st}" == Aborted ]] && (( SECONDS - start > 30 )); then
        sleep 10; n="$(sts_count "${NS}" "${selector}")"; (( n < min )) && min="${n}"
        break
    fi
    sleep 5
done
after="$(sts_count "${NS}" "${selector}")"
status="$(chi_status "${NS}" "${CHI}")"
ready_pods="$(ready_pod_count "${NS}" "${selector}")"

evidence="label '${BAD_LABEL}': statefulsets ${before}->${after} (min ${min}), ready pods ${ready_pods}/3, CHI status ${status}"
verdict "$(( after < before ? 1 : 0 ))" "${evidence}"
