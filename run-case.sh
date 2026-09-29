#!/usr/bin/env bash
# Usage: ./run-case.sh <case-dir-name> [operator-version]
# Runs one case against one operator version on the current cluster (created if missing).
source "$(dirname "$0")/lib/common.sh"

case_name="${1:?case name, see cases/}"
export OPERATOR_VERSION="${2:-${OPERATOR_VERSION}}"
[[ -x "${ROOT_DIR}/cases/${case_name}/run.sh" ]] || die "no such case: ${case_name}"

cluster_up
"${ROOT_DIR}/cases/${case_name}/run.sh"
