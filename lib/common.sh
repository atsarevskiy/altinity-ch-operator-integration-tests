# Shared helpers for the test cases. Source it, don't execute it.
#
#   run-case.sh / run-matrix.sh
#        │
#        ├── cluster_up            k3d cluster with an API audit log for the operator's service account
#        ├── operator_install      release bundle for OPERATOR_VERSION, optional OPERATOR_IMAGE override,
#        │                         ClickHouseOperatorConfiguration overrides from the case
#        ├── cases/<id>/run.sh     trigger + observation, prints one RESULT line
#        └── cluster_down          unless KEEP_CLUSTER=1

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CACHE_DIR="${ROOT_DIR}/.cache"
mkdir -p "${CACHE_DIR}"

CLUSTER="${CLUSTER:-altinity-it}"
KCTX="k3d-${CLUSTER}"
OPERATOR_NS="kube-system"
OPERATOR_SA="clickhouse-operator"
OPERATOR_VERSION="${OPERATOR_VERSION:-0.27.4}"
OPERATOR_IMAGE="${OPERATOR_IMAGE:-}"
# Git ref whose install bundle (CRDs, RBAC, deployment) is applied. Set it together with
# OPERATOR_IMAGE when testing a build from master or a pull request.
BUNDLE_REF="${BUNDLE_REF:-}"
CLICKHOUSE_IMAGE="${CLICKHOUSE_IMAGE:-clickhouse/clickhouse-server:26.8}"
KEEPER_IMAGE="${KEEPER_IMAGE:-clickhouse/clickhouse-keeper:26.8}"
K3S_IMAGE="${K3S_IMAGE:-rancher/k3s:v1.31.6-k3s1}"
AUDIT_LOG="/var/lib/rancher/k3s/server/logs/audit.log"
export CLICKHOUSE_IMAGE KEEPER_IMAGE

k() { kubectl --context "${KCTX}" "$@"; }

# Raw evidence behind a verdict (audit slices, probe logs) goes here; run-matrix.sh points it
# next to the case's result.
ARTIFACT_DIR="${ARTIFACT_DIR:-${CACHE_DIR}/artifacts}"
mkdir -p "${ARTIFACT_DIR}"
artifact() { cat > "${ARTIFACT_DIR}/$1"; }

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

die() { log "ERROR: $*"; echo "RESULT: ERROR $*"; exit 2; }

# result REPRODUCED|NOT_REPRODUCED|CONTROL_OK|CONTROL_FAILED "<one-line evidence>"
result() { echo "RESULT: $1 $2"; }

# CONTROL=1 runs the case's benign variant: the same steps without the condition the issue blames.
# The failure must NOT appear there, otherwise the case is measuring its own setup.
CONTROL="${CONTROL:-0}"

# verdict <failure-seen: 0|1> <evidence>
verdict() {
    if [[ "${CONTROL}" == "1" ]]; then
        (( $1 == 1 )) && result CONTROL_FAILED "$2" || result CONTROL_OK "$2"
    else
        (( $1 == 1 )) && result REPRODUCED "$2" || result NOT_REPRODUCED "$2"
    fi
}

# wait_until <timeout-seconds> <description> <command...>
wait_until() {
    local timeout="$1" what="$2"; shift 2
    local start=$SECONDS
    until "$@" >/dev/null 2>&1; do
        if (( SECONDS - start >= timeout )); then
            log "timed out after ${timeout}s waiting for: ${what}"
            return 1
        fi
        sleep 2
    done
    log "ok after $((SECONDS - start))s: ${what}"
}

cluster_up() {
    if k3d cluster list -o json | grep -q "\"name\":\"${CLUSTER}\""; then
        log "cluster ${CLUSTER} already exists, reusing it"
    else
        log "creating k3d cluster ${CLUSTER}"
        k3d cluster create "${CLUSTER}" \
            --image "${K3S_IMAGE}" \
            --no-lb \
            --wait \
            --volume "${ROOT_DIR}/lib/audit-policy.yaml:/etc/altinity-it/audit-policy.yaml@server:0" \
            --k3s-arg "--kube-apiserver-arg=audit-policy-file=/etc/altinity-it/audit-policy.yaml@server:0" \
            --k3s-arg "--kube-apiserver-arg=audit-log-path=${AUDIT_LOG}@server:0" \
            --k3s-arg "--disable=traefik@server:0" \
            --k3s-arg "--disable=metrics-server@server:0" >&2
    fi
    wait_until 120 "node Ready" k wait --for=condition=Ready node --all --timeout=5s
    import_images "${CLICKHOUSE_IMAGE}" "${KEEPER_IMAGE}"
}

cluster_down() {
    if [[ "${KEEP_CLUSTER:-0}" == "1" ]]; then
        log "KEEP_CLUSTER=1, leaving ${CLUSTER} running"
        return
    fi
    k3d cluster delete "${CLUSTER}" >&2 || true
}

# Pull on the host once and import, so pods never wait on a registry mid-test.
import_images() {
    local img
    for img in "$@"; do
        docker image inspect "${img}" >/dev/null 2>&1 || docker pull -q "${img}" >&2
    done
    k3d image import -c "${CLUSTER}" "$@" >&2
}

bundle_file() {
    local ref="${BUNDLE_REF:-release-${OPERATOR_VERSION}}"
    local f="${CACHE_DIR}/bundle-${ref//\//-}.yaml"
    # Branch bundles move; only release tags are safe to cache.
    if [[ ! -s "${f}" || "${ref}" != release-* ]]; then
        curl -sfL -o "${f}" \
            "https://raw.githubusercontent.com/Altinity/clickhouse-operator/${ref}/deploy/operator/clickhouse-operator-install-bundle.yaml" \
            || die "cannot download install bundle for ${ref}"
    fi
    echo "${f}"
}

# operator_install [chopconf-file] [KEY=VALUE env overrides...]
operator_install() {
    local chopconf="${1:-}"; shift || true
    local image="${OPERATOR_IMAGE:-altinity/clickhouse-operator:${OPERATOR_VERSION}}"
    local exporter="altinity/metrics-exporter:${OPERATOR_VERSION}"

    log "installing operator ${OPERATOR_VERSION} (image ${image})"
    if [[ "${image}" == altinity/* ]]; then
        import_images "${image}" "${exporter}"
    else
        import_images "${exporter}"
        k3d image import -c "${CLUSTER}" "${image}" >&2
    fi

    # Start from the bundle's own deployment: env and image set by a previous case would
    # otherwise survive the apply, since server-side apply leaves fields other managers own.
    k -n "${OPERATOR_NS}" delete deployment clickhouse-operator --ignore-not-found --wait=true >/dev/null
    k apply --server-side --force-conflicts -f "$(bundle_file)" >/dev/null
    k -n "${OPERATOR_NS}" set image deployment/clickhouse-operator "clickhouse-operator=${image}" >/dev/null
    k -n "${OPERATOR_NS}" patch deployment clickhouse-operator --type=json \
        -p '[{"op":"replace","path":"/spec/template/spec/containers/0/imagePullPolicy","value":"IfNotPresent"}]' >/dev/null

    k -n "${OPERATOR_NS}" delete clickhouseoperatorconfigurations --all >/dev/null 2>&1 || true
    if [[ -n "${chopconf}" ]]; then
        k -n "${OPERATOR_NS}" apply -f "${chopconf}" >/dev/null
    fi
    if (( $# > 0 )); then
        k -n "${OPERATOR_NS}" set env deployment/clickhouse-operator -c clickhouse-operator "$@" >/dev/null
    fi

    k -n "${OPERATOR_NS}" rollout restart deployment/clickhouse-operator >/dev/null
    k -n "${OPERATOR_NS}" rollout status deployment/clickhouse-operator --timeout=180s >&2 \
        || die "operator deployment did not become ready"
    OPERATOR_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    export OPERATOR_STARTED_AT
}

operator_pod() {
    k -n "${OPERATOR_NS}" get pod -l app=clickhouse-operator -o jsonpath='{.items[0].metadata.name}'
}

operator_logs() {
    k -n "${OPERATOR_NS}" logs "$(operator_pod)" -c clickhouse-operator "$@"
}

# Some cases wedge pod shutdown on purpose, so teardown force-deletes pods instead of waiting
# out their grace period.
drop_namespace() {
    local ns="$1"
    k get ns "${ns}" >/dev/null 2>&1 || return 0
    k -n "${ns}" delete chi,chk --all --wait=false >/dev/null 2>&1 || true
    k -n "${ns}" delete pods --all --grace-period=0 --force >/dev/null 2>&1 || true
    k delete ns "${ns}" --wait=false >/dev/null 2>&1 || true
    local start=$SECONDS
    while k get ns "${ns}" >/dev/null 2>&1; do
        if (( SECONDS - start > 180 )); then
            # A CR whose finalizer the operator can no longer process would hold the namespace forever.
            for r in $(k -n "${ns}" get chi,chk -o name 2>/dev/null); do
                k -n "${ns}" patch "${r}" --type=merge -p '{"metadata":{"finalizers":null}}' >/dev/null 2>&1 || true
            done
        fi
        k -n "${ns}" delete pods --all --grace-period=0 --force >/dev/null 2>&1 || true
        sleep 3
    done
}

# Fresh namespace per case so leftovers from a previous case can't leak in.
fresh_namespace() {
    local ns="$1"
    drop_namespace "${ns}"
    k create ns "${ns}" >/dev/null
    if [[ "${KEEP_NAMESPACE:-0}" != "1" ]]; then
        trap "drop_namespace ${ns}" EXIT
    fi
}

# Render a manifest template, substituting ${VARS} from the environment.
render() {
    envsubst < "$1"
}

chi_status() { k -n "$1" get chi "$2" -o jsonpath='{.status.status}' 2>/dev/null; }
chk_status() { k -n "$1" get chk "$2" -o jsonpath='{.status.status}' 2>/dev/null; }

chi_tasks() { k -n "$1" get chi "$2" -o jsonpath='{.status.taskIDsStarted}' 2>/dev/null; }
chk_tasks() { k -n "$1" get chk "$2" -o jsonpath='{.status.taskIDsStarted}' 2>/dev/null; }
tasks_changed() { [[ "$("$1" "$2" "$3")" != "$4" ]]; }

# apply_and_wait_started <chi|chk> <ns> <name> <manifest-on-stdin>
# Applies a change and returns once the operator has started a reconcile task for it, so a
# status read afterwards can't be the status left over from the previous reconcile.
apply_and_wait_started() {
    local kind="$1" ns="$2" name="$3" before
    before="$("${kind}_tasks" "${ns}" "${name}")"
    k -n "${ns}" apply -f - >/dev/null
    wait_until 120 "${kind} ${ns}/${name} reconcile started" tasks_changed "${kind}_tasks" "${ns}" "${name}" "${before}"
}

chi_status_is() { [[ "$(chi_status "$1" "$2")" == "$3" ]]; }
chk_status_is() { [[ "$(chk_status "$1" "$2")" == "$3" ]]; }

# Wait for the CHI to report Completed and for its hosts to be reconciled.
wait_chi_completed() {
    local ns="$1" name="$2" timeout="${3:-600}"
    wait_until "${timeout}" "CHI ${ns}/${name} Completed" chi_status_is "${ns}" "${name}" Completed
}

wait_chk_completed() {
    local ns="$1" name="$2" timeout="${3:-600}"
    wait_until "${timeout}" "CHK ${ns}/${name} Completed" chk_status_is "${ns}" "${name}" Completed
}

ready_pod_count() {
    k -n "$1" get pods -l "$2" -o json 2>/dev/null \
        | jq '[.items[] | select(.metadata.deletionTimestamp == null)
                         | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length'
}

pods_ready_is() { [[ "$(ready_pod_count "$1" "$2")" == "$3" ]]; }

# Completed alone is not enough: with create.onFailure=ignore the CHI reports Completed even
# when no pod could be created, so every baseline also waits for the pods themselves.
wait_pods_ready() {
    local ns="$1" selector="$2" count="$3" timeout="${4:-600}"
    wait_until "${timeout}" "${count} Ready pods for ${selector}" pods_ready_is "${ns}" "${selector}" "${count}"
}

sts_count() {
    k -n "$1" get sts -l "$2" --no-headers 2>/dev/null | wc -l | tr -d ' '
}

audit_now() { date -u +%Y-%m-%dT%H:%M:%S.000000Z; }

# Audit events from the operator's service account since a marker time (see audit_now).
audit_events_since() {
    local since="$1"
    docker exec "k3d-${CLUSTER}-server-0" cat "${AUDIT_LOG}" 2>/dev/null \
        | jq -c --arg since "${since}" \
            'select(.stage=="ResponseComplete" and .requestReceivedTimestamp >= $since)'
}

# keeper_probe_start <ns> "<host> <host> ..."
keeper_probe_start() {
    local ns="$1"
    KEEPER_HOSTS="$2" envsubst '${KEEPER_IMAGE} ${KEEPER_HOSTS}' < "${ROOT_DIR}/lib/keeper-probe.yaml" \
        | k -n "${ns}" apply -f - >/dev/null
    wait_until 60 "keeper probe running" k -n "${ns}" wait --for=condition=Ready pod/keeper-probe --timeout=5s
}

# keeper_probe_report <ns> <quorum> <since-epoch>
# Prints "<min serving> <longest run of seconds below quorum> <samples>".
keeper_probe_report() {
    local ns="$1" quorum="$2" since="$3"
    k -n "${ns}" logs keeper-probe 2>/dev/null | awk -v q="${quorum}" -v since="${since}" '
        $1 >= since {
            split($2, a, "="); s = a[2] + 0; n++
            if (min == "" || s < min) min = s
            if (s < q) { if (start == "") start = $1; run = $1 - start + 1; if (run > longest) longest = run }
            else start = ""
        }
        END { printf "%d %d %d\n", (min == "" ? -1 : min), longest + 0, n + 0 }'
}

# scale_chi_up <ns> <shards> <shard-threads> [KEY=VALUE operator env...]
# Installs the operator with concurrent shard reconcile and brings up a Completed scale CHI.
scale_chi_up() {
    local ns="$1"; export SHARDS="$2" SHARD_THREADS="$3"; shift 3
    local conf="${CACHE_DIR}/chopconf-concurrent-${SHARD_THREADS}.yaml"
    envsubst < "${ROOT_DIR}/lib/chopconf-concurrent.yaml" > "${conf}"
    operator_install "${conf}" "$@"
    fresh_namespace "${ns}"
    export ROLL=1 PROFILE_REV=1
    render "${ROOT_DIR}/lib/chi-scale.yaml" | k -n "${ns}" apply -f - >/dev/null
    wait_chi_completed "${ns}" "${CHI}" 900 || die "baseline CHI never reached Completed"
    wait_pods_ready "${ns}" "clickhouse.altinity.com/chi=${CHI}" "${SHARDS}" 300 || die "baseline pods never became Ready"
}

# scale_chi_change <ns> <VAR=value> -> prints the reconcile duration in seconds
# VAR is ROLL (restart every host) or PROFILE_REV (config only).
scale_chi_change() {
    local ns="$1" start
    export "${2?}"
    start=$SECONDS
    render "${ROOT_DIR}/lib/chi-scale.yaml" | apply_and_wait_started chi "${ns}" "${CHI}" \
        || die "operator never started a reconcile for the change"
    wait_chi_completed "${ns}" "${CHI}" 1800 || die "change never reached Completed"
    echo $((SECONDS - start))
}
