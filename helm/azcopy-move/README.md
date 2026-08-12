# azcopy-move

Copies a prefix from one Azure Blob container or Azure Files share to
another, on a schedule, then deletes only the source objects it can prove
arrived.

One CronJob, one container, three steps per run:

1. `azcopy copy`, capturing the job ID from azcopy's own output.
2. `azcopy jobs show <id> --with-status=Success` for that exact job.
3. `azcopy rm --list-of-files` for the verified subset only.

All three run in one pod, so the azcopy job plan files live on a per-run
`emptyDir`. Each run therefore sees only its own job, never a previous one —
the verify step in run N can never be satisfied by a job plan left behind by
run N-1, and cleanup can never delete something a different run copied.

Authorization is SAS only. There is no workload identity and no OIDC.

## Source and destination

```yaml
move:
  source:
    type: blob            # blob | file
    storageAccount: ""    # ignored when endpoint is set
    endpoint: ""           # full scheme+host override, no path
    container: ""          # container name (blob) or share name (file)
    prefix: ""              # empty means the container/share root
  dest:
    type: file
    storageAccount: ""
    endpoint: ""
    container: ""
    prefix: ""
```

Each side is independently `blob` or `file`, so all four combinations work:
Blob→File, Blob→Blob, File→Blob, File→File.

**`container` means different things on the two `type`s.** Azure's URL
grammar is `<endpoint>/<container-or-share>/<path>` on both blob and file
services, so one key covers both:

- `type: blob` → `container` is a blob **container** name.
- `type: file` → `container` is a Files **share** name.

There is no separate `share` key. If a side is `type: file`, put the share
name in `container`.

**`endpoint` is a scheme and host only, nothing else.** For example
`https://acct.privatelink.file.core.windows.net`. It exists for private
endpoints and sovereign clouds. A path component is rejected by
`values.schema.json`. When `endpoint` is empty, the chart derives it from
`storageAccount` and `type`:

```
https://<storageAccount>.<type>.core.windows.net
```

`type` is the endpoint subdomain (`blob` or `file`), so there is no lookup
table — `storageAccount` and `type` alone are enough unless you need to
override the host.

`prefix` is the path under the container/share. Empty means the root.

## Worked examples

Placeholders: `<account>`, `<account2>` are storage account names,
`<container>` is a blob container, `<share>` is a Files share.

### Blob → File

Drain a blob prefix into a share on a different account.

```yaml
move:
  source:
    type: blob
    storageAccount: <account>
    container: <container>
    prefix: incoming
  dest:
    type: file
    storageAccount: <account2>
    container: <share>
    prefix: ""
```

### Blob → Blob

Copy between two containers, same or different accounts.

```yaml
move:
  source:
    type: blob
    storageAccount: <account>
    container: <container>
    prefix: incoming
  dest:
    type: blob
    storageAccount: <account2>
    container: <container>
    prefix: archive
```

`--trailing-dot` is not emitted here — neither side is `file` — so a
trailing-dot object name is copied unmodified.

### File → Blob

Move a share's contents into blob storage, for example ahead of
decommissioning the share.

```yaml
move:
  source:
    type: file
    storageAccount: <account>
    container: <share>
    prefix: ""
  dest:
    type: blob
    storageAccount: <account2>
    container: <container>
    prefix: from-share
```

### File → File

Copy between two shares.

```yaml
move:
  source:
    type: file
    storageAccount: <account>
    container: <share>
    prefix: exports
  dest:
    type: file
    storageAccount: <account2>
    container: <share>
    prefix: ""
```

## SAS permissions and how to mint them

Every SAS is scoped to the container or share it authorizes, never to the
whole account.

| Side | Command | Permissions |
|---|---|---|
| blob source | `az storage container generate-sas` | `rdl` |
| blob destination | `az storage container generate-sas` | `rcwl` |
| file source | `az storage share generate-sas` | `rdl` |
| file destination | `az storage share generate-sas` | `rcwl` |

`r` (read), `d` (delete), `l` (list) on the source; `r`, `c` (create), `w`
(write), `l` on the destination.

**`d` on the source is only needed once `cleanup.enabled` is `true`.** With
`cleanup.enabled: false` the chart never calls `azcopy rm`, so a
read-and-list-only source token (`rl`) works for a dry-run install. Add `d`
before you flip `cleanup.enabled` to `true`.

### Minting with the account key

```bash
KEY=$(az storage account keys list \
  --account-name <account> \
  --query "[0].value" -o tsv)

# BSD date (macOS):
EXPIRY=$(date -u -v+7d '+%Y-%m-%dT%H:%M:%SZ')
# GNU date (Linux):
EXPIRY=$(date -u -d '+7 days' '+%Y-%m-%dT%H:%M:%SZ')

# Blob container, source side (read, delete, list):
az storage container generate-sas \
  --account-name <account> --account-key "$KEY" \
  --name <container> --permissions rdl \
  --expiry "$EXPIRY" --https-only -o tsv

# Blob container, destination side (read, create, write, list):
az storage container generate-sas \
  --account-name <account2> --account-key "$KEY" \
  --name <container> --permissions rcwl \
  --expiry "$EXPIRY" --https-only -o tsv

# Files share, source side:
az storage share generate-sas \
  --account-name <account> --account-key "$KEY" \
  --name <share> --permissions rdl \
  --expiry "$EXPIRY" --https-only -o tsv

# Files share, destination side:
az storage share generate-sas \
  --account-name <account2> --account-key "$KEY" \
  --name <share> --permissions rcwl \
  --expiry "$EXPIRY" --https-only -o tsv
```

### Minting a user delegation SAS instead

A user delegation SAS is signed with Azure AD credentials instead of the
account key, so the account key never needs to be read. It is available only
for **Blob** — Azure Files has no user delegation key, so a Files side still
needs the account-key path above.

```bash
az storage container generate-sas \
  --account-name <account> \
  --name <container> --permissions rdl \
  --expiry "$EXPIRY" --https-only \
  --auth-mode login --as-user -o tsv
```

The caller needs `az login` and an RBAC role that can read blob data (for
example `Storage Blob Data Contributor` or `Storage Blob Data Reader`,
matching the permissions requested) on the storage account or container.

A user delegation SAS is capped at **seven days** by Azure regardless of the
`--expiry` you pass — request a longer expiry and Azure silently truncates
it, so the `EXPIRY` computation above (`+7 days`) is already at the ceiling
for this path.

## Creating the Secret

Create it out of band, so no token reaches git, a Helm release, or a shell
history you didn't mean to keep:

```bash
kubectl create namespace azcopy-move

kubectl create secret generic azcopy-move-sas -n azcopy-move \
  --from-file=source-sas=./source.sas \
  --from-file=dest-sas=./dest.sas
```

Set `sas.existingSecret: azcopy-move-sas` (and `sas.sourceKey` /
`sas.destKey` if you used different key names) in `values.yaml`.

**A SAS expires. Nothing in this chart warns you.** When it does, every run
fails on authorization — there is no expiry check in the cluster and no
alerting on it (see the design's out-of-scope list). Track the `EXPIRY` you
minted and rotate the Secret before it lapses:

```bash
kubectl create secret generic azcopy-move-sas -n azcopy-move \
  --from-file=source-sas=./source.sas \
  --from-file=dest-sas=./dest.sas \
  --dry-run=client -o yaml | kubectl apply -f -
```

`hack/check-sas.sh` in the repository root validates a token file before you
load it: it rejects a leading `?`, requires `sv=` and `sig=`, checks for each
permission letter you expect, and warns when the expiry is inside 48 hours.

## Safe rollout

Install with deletion off:

```bash
helm install move oci://ghcr.io/dobbo-ca/charts/azcopy-move \
  --version <chart semver> \
  -n azcopy-move --create-namespace \
  -f values.yaml \
  --set cleanup.enabled=false
```

`cleanup.enabled` defaults to `false`. Every run still copies and writes a
delete report; it deletes nothing. Watch a few cycles and read the reports:

```bash
kubectl -n azcopy-move logs -l app.kubernetes.io/instance=move --tail=200
```

Only once the reports look right, turn deletion on:

```bash
helm upgrade move oci://ghcr.io/dobbo-ca/charts/azcopy-move \
  --version <chart semver> \
  -n azcopy-move --reuse-values \
  --set cleanup.enabled=true
```

## Why `concurrencyPolicy` must stay `Forbid`

Two concurrent runs would copy and delete the same objects, and one run
could delete a source file the other run is still writing from. `Forbid`
means a tick is skipped outright while the previous run is still going,
instead of stacking a second pod that races the first. The chart's
`_helpers.tpl` validation fails templating if `concurrencyPolicy` is set to
anything else — do not override it.

`activeDeadlineSeconds` exists because `Forbid` has a failure mode of its
own: a hung run blocks every later tick forever unless something kills it.

**`Forbid` does not cover a manually-created Job.** `kubectl create job
--from=cronjob/...` (as printed in the post-install NOTES) makes a Job the
CronJob controller did not create, so it is never added to `.status.active`
and `Forbid` does not block a scheduled tick from starting alongside it.
Suspend the CronJob before running one manually, and resume it after — the
NOTES output does this for you.

## Values

| Key | Default | Notes |
|---|---|---|
| `image.repository` | `ghcr.io/dobbo-ca/containers/azcopy-move` | |
| `image.tag` | `""` | pin an immutable semver or a digest, never `latest` |
| `image.pullPolicy` | `IfNotPresent` | |
| `imagePullSecrets` | `[]` | |
| `move.source.type` | `blob` | `blob` or `file` |
| `move.source.storageAccount` | `""` | ignored when `move.source.endpoint` is set |
| `move.source.endpoint` | `""` | scheme+host only, no path |
| `move.source.container` | `""` | container name (blob) or share name (file) |
| `move.source.prefix` | `""` | empty means the container/share root |
| `move.dest.type` | `file` | `blob` or `file` |
| `move.dest.storageAccount` | `""` | ignored when `move.dest.endpoint` is set |
| `move.dest.endpoint` | `""` | scheme+host only, no path |
| `move.dest.container` | `""` | container name (blob) or share name (file) |
| `move.dest.prefix` | `""` | empty means the container/share root |
| `schedule` | `*/5 * * * *` | |
| `concurrencyPolicy` | `Forbid` | must stay `Forbid`; see above |
| `startingDeadlineSeconds` | `120` | a run not started within this window counts as missed |
| `activeDeadlineSeconds` | `3600` | hard ceiling on one run |
| `backoffLimit` | `0` | one attempt per run; the next scheduled run is the retry |
| `successfulJobsHistoryLimit` | `3` | |
| `failedJobsHistoryLimit` | `5` | |
| `suspend` | `false` | |
| `cleanup.enabled` | `false` | `false` copies and writes the delete report but deletes nothing |
| `cleanup.trustJobRecordOnly` | `false` | `true` skips the destination check and deletes on the job record alone |
| `cleanup.reconcile` | `true` | also deletes any source object already present at the destination with a matching byte count, not only this run's job output; keep this on |
| `azcopy.logLevel` | `ERROR` | successes are read from the job record, not the log |
| `azcopy.concurrencyValue` | `""` | HTTP connections; empty lets azcopy size it from logical cores |
| `azcopy.concurrentFiles` | `""` | files in flight at once; empty lets azcopy decide |
| `azcopy.progressIntervalSeconds` | `30` | seconds between progress lines in the pod log; `0` prints every update |
| `azcopy.overwrite` | `ifSourceNewer` | |
| `azcopy.extraArgs` | `[]` | |
| `sas.existingSecret` | `""` | required when `sas.create` is `false` |
| `sas.sourceKey` | `source-sas` | key inside the existing Secret |
| `sas.destKey` | `dest-sas` | key inside the existing Secret |
| `sas.create` | `false` | throwaway testing only — `true` writes the SAS into the Helm release |
| `sas.sourceSas` | `""` | only used when `sas.create` is `true` |
| `sas.destSas` | `""` | only used when `sas.create` is `true` |
| `serviceAccount.create` | `true` | |
| `serviceAccount.name` | `""` | |
| `podSecurityContext` | restricted profile | `runAsNonRoot`, uid/gid 1000, `seccompProfile: RuntimeDefault`; do not change without checking cluster policies |
| `containerSecurityContext` | restricted profile | `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`, `capabilities.drop: [ALL]` |
| `resources` | `100m`/`256Mi` requests, `2`/`2Gi` limits | |
| `workDir.sizeLimit` | `2Gi` | `emptyDir` for job plan files, logs and the delete list; one per run |
| `nodeSelector` | `{}` | |
| `tolerations` | `[]` | |
| `affinity` | `{}` | |

## What is not covered

- No alerting. A failed run shows as a failed Job and nothing else.
- No in-cluster SAS expiry check.
- No metric for throttling — grep the pod logs for `503` or `ServerBusy` and
  lower `azcopy.concurrencyValue` if they climb.
- No local filesystem or PVC endpoints.
- No workload identity or OIDC.

## Reading the progress output

azcopy redraws a single status line using a carriage return. That is right for a
terminal and useless under Kubernetes: with no TTY the entire run arrives as one
unbounded line, so `kubectl logs` shows a wall of text and `kubectl logs -f`
looks like it has hung.

The chart converts those carriage returns to real newlines before anything else
sees them, then thins the result. Progress lines are limited to one per
`azcopy.progressIntervalSeconds`; every other line — the job ID, warnings,
errors and the final summary — passes through untouched.

```
--- azcopy copy ---
INFO: Scanning...
Job a6654046-f533-bd40-56a9-6f99076f664d has started
0.1 %, 0 Done, 0 Failed, 845 Pending, 0 Skipped, 845 Total
12.3 %, 71 Done, 0 Failed, 774 Pending, 0 Skipped, 845 Total
```

Set `azcopy.progressIntervalSeconds: 0` to print every update. Note that azcopy
emits one roughly every two seconds, so a long first drain produces thousands of
lines.

`/work/copy.log` inside the pod always keeps every line regardless of this
setting. It is what the job ID is parsed from, so thinning the pod log cannot
affect the delete-verification chain.

**A caveat on `/work`.** It is an `emptyDir`, so `copy.log`, the azcopy job log
and `delete-report.csv` are destroyed when the pod terminates. The pod log
survives; the emptyDir does not. If you need the full record, copy it out while
the pod is still running.

## Throttling, and why the concurrency default is empty

A server-to-server copy is bounded by the storage account, not the pod. The two
services do not have the same ceiling: **an Azure Files destination throttles
far earlier than Blob.** A standard file share is around 1,000 IOPS, and azcopy
writes a large file as a stream of 4 MB `PUT ?comp=range` calls, so a high
connection count becomes a flood of range writes against a single share.

Measured on a real migration — 845 files averaging about 1.7 GB, from a blob
container to a file share on the same account, with `concurrencyValue: 400`:

| | |
|---|---|
| 503 `ServerBusy` from the **file** destination | 202,725 |
| 503 `ServerBusy` from the **blob** source | 0 |
| deepest retry observed | 6 attempts |
| transfers failed | 0 |

The copy still finished, because azcopy's retries eventually win. That is the
trap: throttling this severe is invisible in the outcome and shows up only as
wasted requests, a log full of 503s, and load on an account that is usually
also serving live traffic.

So `concurrencyValue` defaults to empty, which leaves the decision to azcopy
based on the pod's logical cores. Raise it deliberately, in steps, watching the
pod log for `ServerBusy`. For a Files destination treat something like 64 as a
ceiling rather than a starting point.

`concurrentFiles` is the other lever. It bounds how many *files* are in flight
rather than how many connections exist, which with large files is often the
more effective control: it limits concurrent range writes per share without
starving any single transfer.

Counting throttles in a finished run:

```bash
kubectl -n <ns> logs job/<job> | grep -c ServerBusy
```

Note that `azcopy.logLevel` defaults to `ERROR`, so the azcopy log file records
only failed requests. You cannot compute a 503 *rate* from it — successes are
never written.

## Ad-hoc delete: reaping a copy that ran with cleanup off

If a run copied everything but `cleanup.enabled` was `false`, the objects are at
the destination and still at the source. The azcopy job plan that recorded the
transfer lived on the pod's `emptyDir` and died with it, so the schedule cannot
replay that job — but the run still wrote a **verified** `delete-list.txt`
before exiting, because the list and the report are produced before the
cleanup-enabled check.

`adhocDelete` feeds that list back through the same `remove-migrated.sh` the
schedule uses.

**The list supplies candidates, not decisions.** Every path is re-checked
against a live destination listing and a byte comparison before anything is
removed, so a stale or wrong list cannot delete an object that is not provably
at the destination. That is also why a `delete-report.csv` can be used directly
even though it contains `keep` rows: verdicts are recomputed against current
state rather than trusted from a file that may be hours old.

Capture the list before the pod exits — `/work` is an `emptyDir`:

```bash
kubectl -n <ns> exec <pod> -- cat /work/delete-list.txt > delete-list.txt
kubectl create configmap azcopy-move-reap -n <ns> \
  --from-file=delete-list.txt=./delete-list.txt
```

Then dry-run it, read the output, and only then arm it:

```bash
helm upgrade --install <rel> . -n <ns> \
  --set adhocDelete.enabled=true \
  --set adhocDelete.listConfigMap=azcopy-move-reap \
  --set adhocDelete.cleanupEnabled=false     # reports, deletes nothing

helm upgrade --install <rel> . -n <ns> \
  --set adhocDelete.enabled=true \
  --set adhocDelete.listConfigMap=azcopy-move-reap \
  --set adhocDelete.cleanupEnabled=true      # deletes
```

`adhocDelete.cleanupEnabled` is deliberately **separate** from
`cleanup.enabled`: arming the schedule's deletion must not silently arm a
one-shot bulk delete, and vice versa.

Notes:

- `RECONCILE` is forced off for this Job. The list is already the reconciled
  set; running the stranded sweep as well would widen the blast radius beyond
  what was reviewed.
- The Job's spec is immutable once created, so changing the list means deleting
  the Job first. The name is stable rather than random so a stale one is
  noticed instead of quietly accumulating.
- A ConfigMap caps at 1 MiB, roughly 20,000 paths. Split a larger list.
- Delete the Job and its ConfigMap when finished, so a later `helm upgrade`
  cannot resurrect a bulk delete from a stale list.
