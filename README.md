# Altinity ClickHouse operator: integration tests for known issues

Each test stands up a real Kubernetes cluster (k3d), installs a given build of the
[Altinity clickhouse-operator](https://github.com/Altinity/clickhouse-operator), triggers the
failure described in an upstream issue, and reports whether that failure still happens on that
build. The point is to answer "is this fixed in version X?" by running it, rather than by reading
release notes.

```
targets.conf (releases, master, pull requests)
      │
      ▼
run-matrix.sh ── per target: fresh k3d cluster (API audit log on) ── install operator bundle + image
      │
      ├── cases/<issue>/run.sh   baseline (Completed + every pod Ready)
      │                          → trigger the issue
      │                          → observe (pod readiness, StatefulSets, Keeper quorum, audit log)
      │                          → RESULT: REPRODUCED | NOT_REPRODUCED | ERROR <evidence>
      ▼
results/<timestamp>/summary.md   one row per case × target, plus per-case and operator logs
```

## Cases

| Case | Upstream | What the test does | Reproduced when |
|---|---|---|---|
| `1420-invalid-label-destroys-hosts` | [#1420](https://github.com/Altinity/clickhouse-operator/issues/1420), [PR #2071](https://github.com/Altinity/clickhouse-operator/pull/2071) | 3 shards; sets a pod-template label value the API server rejects (`/metrics`) | any host's StatefulSet is gone afterwards |
| `2078-recreate-strands-host` | [#2078](https://github.com/Altinity/clickhouse-operator/issues/2078) | 2 shards whose pods hang in `preStop` on shutdown; switches `dataVolumeClaimTemplate`, which forces a Recreate | after the reconcile ends, a host has no Ready pod |
| `2078-recreate-continues-past-down-replica` | [#2078](https://github.com/Altinity/clickhouse-operator/issues/2078) (step 3) | 1 shard × 2 replicas; forces a Recreate whose replacement pod can't start | the shard reaches zero Ready replicas |
| `2069-chk-recreate-loses-quorum` | [#2069](https://github.com/Altinity/clickhouse-operator/issues/2069) | 3-member Keeper; forces a Recreate of every member, with replacements that can't start (`REPLACEMENT=slow` for slow-starting ones); a probe pod samples `srvr` on every member each second | fewer than 2 members serve for 10 s or more in a row |
| `2035-chk-stuck-in-progress` | [#2035](https://github.com/Altinity/clickhouse-operator/issues/2035) | 3-member Keeper; deletes one member's StatefulSet and restarts the operator once it's recreated (`TRIGGER=supersede` for a second spec change instead) | ensemble Ready and quiet for 180 s, status still not `Completed` |
| `2064-status-update-conflicts` | [#2064](https://github.com/Altinity/clickhouse-operator/issues/2064) | 8 shards rolled concurrently; counts the operator's CHI writes in the API audit log | any CHI write rejected with 409 Conflict |
| `2063-sts-get-per-host` | [#2063](https://github.com/Altinity/clickhouse-operator/issues/2063) | 6 shards rolled; counts StatefulSet GETs before the first host write | at least 2 GETs per host, none cached |
| `2045-client-throttling` | [#2045](https://github.com/Altinity/clickhouse-operator/issues/2045) | 12 shards rolled concurrently twice, on the client-go default limits and with `OPERATOR_K8S_CLIENT_QPS_LIMIT` / `_BURST_LIMIT` raised | default run is client-side throttled while the raised run shows the reconcile wanted more, with no startup warning |

Every case checks its own baseline first (CHI/CHK `Completed` and every pod Ready), because with
`create.onFailure: ignore` a CHI reports `Completed` even when no pod could be created.

## Requirements

- Docker, `k3d` (v5), `kubectl`, `jq`, `envsubst`, `curl`.
- About 16 GB of free memory for the 12-host case; the others need much less.
- To build master or a pull request: `go` on `PATH` (the version in the operator's `go.mod`, or
  `GOTOOLCHAIN=auto`). Set `GOPROXY` if the default module proxy isn't reachable from your network.

Images come from Docker Hub (`altinity/clickhouse-operator`, `altinity/metrics-exporter`,
`clickhouse/clickhouse-server`, `clickhouse/clickhouse-keeper`) and are imported into the cluster
before each run, so no pod waits on a registry mid-test.

## Running

One case against one release, on a cluster that's kept afterwards for poking around:

```
KEEP_CLUSTER=1 ./run-case.sh 2078-recreate-strands-host 0.27.4
```

The whole matrix, or part of it:

```
./run-matrix.sh                                   # every case × every target in targets.conf
./run-matrix.sh -t "0.27.3 0.27.4" -c "2035-chk-stuck-in-progress"
./run-matrix.sh -r 3                              # each case three times, to check it's stable
```

A build from any upstream ref:

```
OPERATOR_IMAGE=$(scripts/build-operator.sh pr/2071) OPERATOR_VERSION=0.27.4 ./run-case.sh 1420-invalid-label-destroys-hosts
```

`targets.conf` lists what the matrix runs against; add a line to test another release, branch or
pull request. Useful environment variables:

| Variable | Default | Meaning |
|---|---|---|
| `OPERATOR_VERSION` | `0.27.4` | release whose bundle (and, unless overridden, image) is installed |
| `OPERATOR_IMAGE` | released image | operator image to run instead |
| `BUNDLE_REF` | `release-<version>` | git ref whose install bundle is applied |
| `CLICKHOUSE_IMAGE` | `clickhouse/clickhouse-server:26.8` | server image for CHI pods |
| `KEEPER_IMAGE` | `clickhouse/clickhouse-keeper:26.8` | image for CHK pods |
| `KEEP_CLUSTER` | `0` | keep the k3d cluster after `run-case.sh` |
| `KEEP_NAMESPACE` | `0` | keep the test namespace after a case |

Cases take their own knobs (`WINDOW`, `SETTLE`, `SHARDS`, `REPLACEMENT`, `TRIGGER`); each
`run.sh` documents them at the top.

## Reading a result

Each case prints one line, `RESULT: <verdict> <evidence>`. The evidence is the measurement the
verdict rests on (StatefulSet counts, seconds below quorum, 409 counts, request rates), so a
surprising verdict can be checked without rerunning. The matrix also keeps the case's stderr log
and the operator log next to the summary.
