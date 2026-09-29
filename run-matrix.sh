#!/usr/bin/env bash
# Usage: ./run-matrix.sh [-t "label label"] [-c "case case"] [-r repeats]
# For each target in targets.conf: a fresh cluster, every selected case against it, results in
# results/<timestamp>/summary.md plus per-case logs and operator logs.
source "$(dirname "$0")/lib/common.sh"

targets=""; cases=""; repeats=1
while getopts "t:c:r:" opt; do
    case "${opt}" in
        t) targets="${OPTARG}" ;;
        c) cases="${OPTARG}" ;;
        r) repeats="${OPTARG}" ;;
        *) exit 2 ;;
    esac
done
[[ -n "${cases}" ]] || cases="$(ls "${ROOT_DIR}/cases")"

out_dir="${ROOT_DIR}/results/$(date +%Y%m%d-%H%M%S)"
mkdir -p "${out_dir}"
summary="${out_dir}/summary.md"
printf '| Case | Operator | Run | Result | Evidence |\n|---|---|---|---|---|\n' > "${summary}"

while read -r label version image bundle; do
    [[ -z "${label}" || "${label}" == \#* ]] && continue
    [[ -n "${targets}" && " ${targets} " != *" ${label} "* ]] && continue

    export OPERATOR_VERSION="${version}" OPERATOR_IMAGE="" BUNDLE_REF=""
    [[ "${bundle}" != "-" ]] && BUNDLE_REF="${bundle}"
    case "${image}" in
        -) ;;
        build:*) OPERATOR_IMAGE="$("${ROOT_DIR}/scripts/build-operator.sh" "${image#build:}" 2>> "${out_dir}/build-${label}.log")" \
                     || { log "build for ${label} failed, see ${out_dir}/build-${label}.log"; continue; } ;;
        *) OPERATOR_IMAGE="${image}" ;;
    esac

    KEEP_CLUSTER=0 cluster_down
    cluster_up
    for c in ${cases}; do
        for run in $(seq 1 "${repeats}"); do
            log "=== ${c} on ${label} (run ${run}/${repeats})"
            logf="${out_dir}/${c}-${label}-${run}"
            set +e
            ARTIFACT_DIR="${logf}.artifacts" "${ROOT_DIR}/cases/${c}/run.sh" > "${logf}.out" 2> "${logf}.log"
            set -e
            line="$(grep '^RESULT:' "${logf}.out" | tail -1)"
            [[ -n "${line}" ]] || line="RESULT: ERROR no result line, see $(basename "${logf}").log"
            verdict="$(awk '{print $2}' <<< "${line}")"
            evidence="$(cut -d' ' -f3- <<< "${line}")"
            printf '| %s | %s | %s | %s | %s |\n' "${c}" "${label}" "${run}" "${verdict}" "${evidence//|/\\|}" >> "${summary}"
            operator_logs > "${logf}.operator.log" 2>/dev/null || true
            log "${line}"
        done
    done
done < "${ROOT_DIR}/targets.conf"
cluster_down
cat "${summary}"
