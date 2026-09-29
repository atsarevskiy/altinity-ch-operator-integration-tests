#!/usr/bin/env bash
# #2078, step 3: during a Recreate the operator doesn't check that the replica it just
# recreated came back before it takes down the next replica of the same shard. Reproduced when
# the shard ends up with zero Ready replicas.
source "$(dirname "$0")/../../lib/common.sh"
HERE="$(cd "$(dirname "$0")" && pwd)"

NS=it-2078b
export CHI=roll
WINDOW="${WINDOW:-480}"
selector="clickhouse.altinity.com/chi=${CHI}"

operator_install "${HERE}/chopconf.yaml"
fresh_namespace "${NS}"

DATA_VCT=data-a render "${HERE}/chi.yaml" | k -n "${NS}" apply -f - >/dev/null
wait_chi_completed "${NS}" "${CHI}" 600 || die "baseline CHI never reached Completed"
wait_pods_ready "${NS}" "${selector}" 2 300 || die "baseline pods never became Ready"

log "switching dataVolumeClaimTemplate to one whose replacement pods cannot start"
DATA_VCT=data-b render "${HERE}/chi.yaml" | apply_and_wait_started chi "${NS}" "${CHI}" \
    || die "operator never started a reconcile for the change"

start=$SECONDS; min_ready=2; zero_at=""
while (( SECONDS - start < WINDOW )); do
    r="$(ready_pod_count "${NS}" "${selector}")"
    if (( r < min_ready )); then
        min_ready="${r}"; log "Ready replicas in the shard now ${r}/2"
    fi
    if (( r == 0 )) && [[ -z "${zero_at}" ]]; then
        zero_at=$((SECONDS - start)); break
    fi
    st="$(chi_status "${NS}" "${CHI}")"
    [[ "${st}" == Completed || "${st}" == Aborted ]] && (( SECONDS - start > 60 )) && break
    sleep 3
done
status="$(chi_status "${NS}" "${CHI}")"
events="$(k -n "${NS}" get events --no-headers 2>/dev/null | grep -cE 'Recreate|switch from Update to Recreate' || true)"

evidence="min Ready replicas ${min_ready}/2, CHI status ${status}, recreate events ${events}"
[[ -n "${zero_at}" ]] && evidence+=", shard had zero Ready replicas ${zero_at}s after the change"
verdict "$(( min_ready == 0 ? 1 : 0 ))" "${evidence}"
