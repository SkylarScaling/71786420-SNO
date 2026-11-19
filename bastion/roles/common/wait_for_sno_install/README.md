# wait_for_sno_install

## tl;dr

Polls until `sno_kubeconfig` exists and the cluster reports `ClusterVersion`
`Available: True`.

### To use this correctly:

- No vars to set — this role just waits. If it keeps failing past `retries`, check
  the actual cluster/bootstrap state rather than re-running blindly.

## Full Details:

Two waits, back to back:

1. `sno_kubeconfig` exists on disk (up to 30 retries × 30s) — confirms the
   agent-based install got far enough to write it out at all.
2. The `ClusterVersion`/`version` object reports an `Available: True` condition (up
   to 40 retries × 30s).

The second wait's `until` condition pipes `status.conditions` through
`default([])` before `selectattr` — without it, a `ClusterVersion` object that
exists but whose `status.conditions` the cluster-version-operator hasn't populated
yet makes the condition template itself raise (`'dict object' has no attribute
'conditions'`), which aborts the task immediately instead of retrying. Confirmed
live: the task failed outright on an early run, then succeeded without any code
change once re-run later — the resource had simply caught up by then. `default([])`
makes an empty/missing `conditions` list evaluate to "not yet available" (a normal
retry) instead of a hard error.
