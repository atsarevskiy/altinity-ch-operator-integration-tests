# #2035: ClickHouseKeeperInstallation stuck at `InProgress` after an interrupted reconcile

Upstream: [Altinity/clickhouse-operator#2035](https://github.com/Altinity/clickhouse-operator/issues/2035),
closed as fixed by [#2070](https://github.com/Altinity/clickhouse-operator/pull/2070) in 0.27.4.
It still reproduces on 0.27.4 and on master.

A 3-member Keeper ensemble stays `status: InProgress` indefinitely while all 3 pods are Ready and
serving. Nothing clears the status short of a spec change that gives the operator real work, or a
manual status patch.

## Trigger

```
baseline: CHK Completed, 3/3 Ready
      │
      ├── delete one member's StatefulSet     (drift the operator repairs with no spec change)
      ├── operator recreates it               (reconcile writes status InProgress)
      ├── operator pod is killed              (--grace-period=0 --force, before finalize)
      ▼
new operator pod: every reconcile finds nothing to do and returns without touching status
```

The kill has to be forced. A normal `kubectl delete pod` gives the old pod its grace period, and it
can finish the reconcile before it exits. A crash or an OOM kill is what leaves the reconcile half
done.

## Running it

```
KEEP_CLUSTER=1 ./run-case.sh 2035-chk-stuck-in-progress 0.27.4
CONTROL=1 ./run-case.sh 2035-chk-stuck-in-progress 0.27.4      # same drift, operator left running
TRIGGER=supersede ./run-case.sh 2035-chk-stuck-in-progress 0.27.4
```

Reproduced when the ensemble is Ready and quiet for `SETTLE` seconds (default 180) and the CHK
status is still not `Completed`. The control repairs the same drift without killing the operator
and should end `Completed`.

## Results

| Operator | Result | Evidence |
|---|---|---|
| 0.27.0 | REPRODUCED | `InProgress` with 3/3 Ready after 180 s, `taskIDsStarted` 3, `taskIDsCompleted` 1 |
| 0.27.3 | REPRODUCED | `InProgress` with 3/3 Ready after 180 s, `taskIDsStarted` 2, `taskIDsCompleted` 1 |
| 0.27.4 | REPRODUCED | same, plus 2 `No reconcile work - abort reconcile` reconciles after the restart |
| master (`a89fa9e2`) | REPRODUCED | same, plus 3 `No reconcile work` reconciles |

Each is a single run on k3d with `clickhouse/clickhouse-keeper:26.8`.

Operator log from the new pod on 0.27.4, the ensemble already Ready:

```
16:07:22.389 worker-reconciler-chk.go:58:reconcileCR():start:CHK:it-2035/stuck
16:07:22.434 reconcileCR():CHK:it-2035/stuck:No reconcile work - abort reconcile
16:07:22.434 worker-reconciler-chk.go:59:reconcileCR():end:CHK:it-2035/stuck
```

0.27.0 and 0.27.3 don't print that line in their log. What their log shows after the restart is
`buildCR` running, finding every StatefulSet "equal based on object version label", and then no
reconcile start and no finalize, which is the same branch.

## Mechanism

Read at `release-0.27.4`; the branch below is the same at `release-0.27.3` and at master.

1. The reconcile that repairs the deleted StatefulSet calls `markReconcileStart`
   (`pkg/controller/chk/worker.go`), which writes `status: InProgress`.
2. The operator is killed before `finalizeReconcileAndMarkCompleted` runs. That is the only path
   that writes `Completed`: `ReconcileComplete()` is called from `persistReconcileCompleted`
   (reached through `finalizeCR`) and from `finalizeReconcileAndMarkCompleted`, and from nowhere
   else in the Keeper controller.
3. The restarted operator runs `reconcileCR` (`pkg/controller/chk/worker-reconciler-chk.go`).
   The spec still equals `.status.normalizedCompleted`, so the action plan is empty, and the
   StatefulSet was already recreated, so there is no drift either:

   ```go
   case new.HasReconcileWork():          // ActionPlan.HasActionsToDo() || counters.HasDrift()
       ...
   case w.isAfterFinalizerInstalled(new.GetAncestorT(), new):
       ...
   default:
       w.a.M(new).F().Info("No reconcile work - abort reconcile")
       metrics.CRReconcilesCompleted(ctx, new)
       return nil
   }
   ```

4. That `default` branch returns before `markReconcileStart` and never reaches finalize, so it
   leaves whatever status the killed reconcile wrote. Every later reconcile takes the same branch.

#2070 reworked how the Keeper controller waits for members and protects Raft quorum, but it didn't
change this branch: the `default` arm is identical at 0.27.3, 0.27.4 and master.
