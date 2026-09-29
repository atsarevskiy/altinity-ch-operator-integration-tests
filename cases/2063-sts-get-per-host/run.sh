#!/usr/bin/env bash
# #2063: before touching the first host, each reconcile reads every host's StatefulSet with its
# own uncached GET (no resourceVersion, so the read goes to etcd), more than once per host.
# Reproduced when that pre-pass issues at least 2 GETs per host and none of them are cached reads.
#
# Mechanism, read at release-0.26.3 through master. buildCR normalizes twice and each pass calls
# fillCurSTS and findMinMaxVersions, which Get every host's StatefulSet: 4 per host. setHostStatuses
# Preliminary adds a 5th, issued after it has already LISTed every StatefulSet and discarded in
# three of its four branches. controller.NewGetOptions() returns an empty meta.GetOptions, so none
# of these is a cached read. A StatefulSet informer is already running with a populated indexer
# (addEventHandlersStatefulSet), but no lister exists and nothing reads the cache.
# The count this case reports is only the pre-pass. Total GETs per reconcile are far higher because
# buildCR also runs from updateEndpoints -> finalizeCR -> buildCRFromObj on every endpoint change,
# which the WHOLE-RECONCILE figure in the evidence reflects.
source "$(dirname "$0")/../../lib/common.sh"

NS=it-2063
export CHI=gets
SHARDS="${SHARDS:-6}"

scale_chi_up "${NS}" "${SHARDS}" 1
since="$(audit_now)"
duration="$(scale_chi_change "${NS}" ROLL=2)"
[[ "${duration}" =~ ^[0-9]+$ ]] || die "change did not complete"
[[ "${duration}" =~ ^[0-9]+$ ]] || die "change did not complete"

sts="$(audit_events_since "${since}" | jq -c 'select(.objectRef.resource=="statefulsets" and .objectRef.namespace=="'"${NS}"'")')"
# The pre-pass ends at the first StatefulSet write of the reconcile.
first_write="$(jq -r 'select(.verb=="update" or .verb=="patch" or .verb=="create" or .verb=="delete") | .requestReceivedTimestamp' <<< "${sts}" | sort | head -1)"
[[ -n "${first_write}" ]] || die "no StatefulSet write seen during the roll"
prepass="$(jq -c --arg t "${first_write}" 'select(.verb=="get" and .requestReceivedTimestamp < $t)' <<< "${sts}")"
prepass_gets="$(grep -c . <<< "${prepass}" || true)"
jq -c '{t: .requestReceivedTimestamp, verb, name: .objectRef.name, uri: .requestURI, code: .responseStatus.code}' <<< "${sts}" | artifact statefulset-requests.jsonl
echo "${first_write}" | artifact first-statefulset-write.txt
cached="$(jq -r '.requestURI' <<< "${prepass}" | grep -c 'resourceVersion=0' || true)"
lists="$(jq -c --arg t "${first_write}" 'select(.verb=="list" and .requestReceivedTimestamp < $t)' <<< "${sts}" | grep -c . || true)"
total_gets="$(jq -c 'select(.verb=="get")' <<< "${sts}" | grep -c . || true)"
per_host=$(( prepass_gets / SHARDS ))

evidence="${SHARDS} hosts: ${prepass_gets} StatefulSet GETs before the first host write (${per_host} per host, ${cached} cached, ${lists} LISTs), ${total_gets} GETs over the whole ${duration}s reconcile"
verdict "$(( prepass_gets >= 2 * SHARDS && cached == 0 ? 1 : 0 ))" "${evidence}"
