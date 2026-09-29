#!/usr/bin/env bash
# Usage: scripts/build-operator.sh <git-ref> [image-tag]
#   <git-ref>: a branch, tag or commit of Altinity/clickhouse-operator, or pr/<N> for a pull request.
# Builds the operator image from source and prints its name, for OPERATOR_IMAGE=...
# Needs go on PATH; set GOPROXY if the default module proxy isn't reachable.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# A pull-request branch can be many commits behind the release it targets, so `pr/<N>@<base>`
# applies the PR's own commits onto <base> instead of building the branch as it stands. Building
# the branch alone measures the PR plus everything the base has gained since, which is not the PR.
ref="${1:?git ref, e.g. master, pr/2071 or pr/2071@release-0.27.4}"
tag="${2:-local-$(tr '/@' '-' <<< "${ref}")}"
src="${ROOT_DIR}/.cache/src/clickhouse-operator"

if [[ ! -d "${src}/.git" ]]; then
    git clone -q https://github.com/Altinity/clickhouse-operator "${src}"
fi
git -C "${src}" fetch -q origin
# The upstream build vendors modules into the tree, and a cherry-picked patch stays in the worktree,
# so both are cleared before checking out the next ref.
git -C "${src}" cherry-pick --abort 2>/dev/null || true
git -C "${src}" checkout -q --force -- . 2>/dev/null || true
git -C "${src}" clean -qfdx

if [[ "${ref}" == pr/*@* ]]; then
    pr="${ref#pr/}"; base="${pr#*@}"; pr="${pr%@*}"
    git -C "${src}" fetch -q origin "pull/${pr}/head"
    head="$(git -C "${src}" rev-parse FETCH_HEAD)"
    mb="$(git -C "${src}" merge-base FETCH_HEAD "origin/${base}" 2>/dev/null || git -C "${src}" merge-base FETCH_HEAD "${base}")"
    git -C "${src}" checkout -q --force --detach "${base}"
    echo "applying PR ${pr} commits $(git -C "${src}" rev-list --count "${mb}..${head}") onto ${base}" >&2
    for c in $(git -C "${src}" rev-list --reverse "${mb}..${head}"); do
        if ! git -C "${src}" cherry-pick --no-commit "${c}" >/dev/null 2>&1; then
            # Test files are not part of the operator binary, so a conflict there is resolved by
            # keeping the base copy. A conflict in any other file means the PR does not apply and
            # the result would not be the PR's change.
            conflicts="$(git -C "${src}" diff --name-only --diff-filter=U)"
            if grep -qv '_test\.go$' <<< "${conflicts}"; then
                echo "ERROR: PR ${pr} does not apply cleanly onto ${base}:" >&2
                echo "${conflicts}" >&2
                git -C "${src}" cherry-pick --abort 2>/dev/null || true
                exit 1
            fi
            for f in ${conflicts}; do
                git -C "${src}" checkout --ours -- "${f}"
                git -C "${src}" add -- "${f}"
            done
        fi
    done
elif [[ "${ref}" == pr/* ]]; then
    git -C "${src}" fetch -q origin "pull/${ref#pr/}/head"
    git -C "${src}" checkout -q --detach FETCH_HEAD
else
    git -C "${src}" checkout -q --detach "origin/${ref}" 2>/dev/null || git -C "${src}" checkout -q --detach "${ref}"
fi
image="clickhouse-operator:${tag}"
sha="$(git -C "${src}" rev-parse --short HEAD)"
git -C "${src}" diff --cached --quiet || sha="${sha}+patch"
base="${BASE_IMAGE:-altinity/clickhouse-operator:0.27.4}"
out="${ROOT_DIR}/.cache/build/${tag}"
mkdir -p "${out}"

# Compile on the host with its Go toolchain and GOPROXY (the upstream Dockerfile fetches modules
# from inside the build container, which not every network allows), then put the binary on top
# of a released image so the runtime layout matches what the release ships.
echo "building ${image} from ${ref} (${sha}) on top of ${base}" >&2
( cd "${src}" && OPERATOR_BIN="${out}/clickhouse-operator" GOARCH="$(go env GOARCH)" bash ./dev/go_build_operator.sh ) >&2
cat > "${out}/Dockerfile" <<DOCKERFILE
FROM ${base}
COPY clickhouse-operator /clickhouse-operator
DOCKERFILE
docker build -q -t "${image}" "${out}" >&2
echo "${image}"
