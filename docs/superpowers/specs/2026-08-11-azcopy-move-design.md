# azcopy-move — design

**Date:** 2026-08-11
**Status:** approved for planning

## 1. Purpose

`azcopy-move` is a public repository under `dobbo-ca` holding two published
artifacts:

- a container image with `azcopy` and nothing else, and
- a Helm chart that runs it as a CronJob which copies a storage prefix,
  verifies what arrived, then deletes only the verified source objects.

It generalises a private, single-purpose chart that only moved an Azure Blob
prefix into an Azure Files share on one storage account. The generic version
selects the source and destination independently, so all four of Blob→File,
Blob→Blob, File→Blob and File→File work, across two different storage accounts,
with a per-side endpoint override for private endpoints and sovereign clouds.

Authorization is SAS only. There is no workload identity and no OIDC. The chart
README documents the `az` commands that mint each token.

## 2. Repository layout

```
azcopy-move/
├── containers/azcopy/
│   ├── Dockerfile
│   └── CONTAINER.md
├── helm/azcopy-move/
│   ├── Chart.yaml
│   ├── values.yaml
│   ├── values.schema.json
│   ├── README.md
│   ├── templates/
│   │   ├── _helpers.tpl
│   │   ├── configmap-scripts.yaml
│   │   ├── cronjob.yaml
│   │   ├── secret.yaml
│   │   ├── serviceaccount.yaml
│   │   └── NOTES.txt
│   ├── scripts/
│   │   ├── invoke-migration.sh
│   │   ├── remove-migrated.sh
│   │   ├── candidates.awk
│   │   ├── decide.awk
│   │   └── parse-list.awk
│   └── ci/
│       ├── blob-to-file-values.yaml
│       ├── blob-to-blob-values.yaml
│       ├── file-to-blob-values.yaml
│       └── file-to-file-values.yaml
├── hack/
│   ├── check-sas.sh
│   └── test-awk.sh
├── test/
│   ├── fixtures/
│   └── golden/
├── .cliff-chart.toml
├── .cliff-image.toml
├── .github/workflows/{pr.yml,release.yml}
├── docs/
└── README.md
```

The scripts stay in `helm/azcopy-move/scripts/` and are mounted from a
ConfigMap. They are not copied into the image; the image only supplies
`azcopy` and a POSIX userland.

Script filenames do not change. `invoke-migration.sh` and `remove-migrated.sh`
still describe what they do, and keeping the names keeps the diff reviewable.

## 3. Chart values

### 3.1 Source and destination

```yaml
move:
  source:
    type: blob            # blob | file
    storageAccount: ""    # ignored when endpoint is set
    endpoint: ""          # full scheme+host override, no path
    container: ""         # container name (blob) or share name (file)
    prefix: ""            # empty means the container root
  dest:
    type: file
    storageAccount: ""
    endpoint: ""
    container: ""
    prefix: ""
```

`container` names a blob container on a `blob` side and a file share on a
`file` side. Azure's URL grammar is `<endpoint>/<container-or-share>/<path>` on
both, so one key covers both and the chart README says so explicitly.

`endpoint` holds a scheme and a host only, for example
`https://acct.privatelink.file.core.windows.net`. A path component is not
supported and `values.schema.json` rejects one.

The remaining value blocks — `schedule`, `concurrencyPolicy`, `cleanup`,
`azcopy`, `sas`, `serviceAccount`, `podSecurityContext`,
`containerSecurityContext`, `resources`, `workDir` — carry over unchanged, with
`cleanup.enabled` still defaulting to `false`.

### 3.2 Derived values

| Derived | Rule |
|---|---|
| endpoint | `endpoint` when set, else `https://<storageAccount>.<type>.core.windows.net` |
| `--from-to` | `title(source.type) + title(dest.type)` → `BlobFile`, `BlobBlob`, `FileBlob`, `FileFile` |
| `--trailing-dot` | emitted only when `source.type` or `dest.type` is `file` |

`type` doubles as the endpoint subdomain, so no lookup table is needed.

The chart resolves both endpoints in `_helpers.tpl` and passes finished base
URLs to the scripts. `helm template` therefore shows the exact URLs azcopy will
call, and the scripts build no hostnames.

### 3.3 Validation

`values.schema.json` enforces:

- `move.source.type` and `move.dest.type` are one of `blob`, `file`;
- `move.*.container` is a non-empty string;
- `move.*.endpoint` is empty or matches `^https?://[^/]+$`.

The existing `_helpers.tpl` `validate` template keeps the checks whose failure
needs an explanation rather than a type error: `concurrencyPolicy` must be
`Forbid` because two concurrent runs would copy and delete the same objects,
`storageAccount` is required when `endpoint` is empty, and `sas.existingSecret`
is required when `sas.create` is false.

## 4. Script changes

### 4.1 Environment contract

The CronJob passes these. The scripts read them and build no hostnames.

```
SOURCE_ENDPOINT    https://acct1.blob.core.windows.net
SOURCE_CONTAINER   raw
SOURCE_PREFIX      <prefix>                 (may be empty)
DEST_ENDPOINT      https://acct2.file.core.windows.net
DEST_CONTAINER     <share>
DEST_PREFIX        ""                       (may be empty)
FROM_TO            BlobFile
```

`AZCOPY_TRAILING_DOT` is unset when neither side is `file`, and the script omits
the flag when the variable is empty.

### 4.2 Per-file changes

**`invoke-migration.sh`**

- Required variables become `SOURCE_ENDPOINT SOURCE_CONTAINER DEST_ENDPOINT
  DEST_CONTAINER FROM_TO`. `SOURCE_PREFIX` becomes optional.
- URL assembly:

  ```sh
  SRC="${SOURCE_ENDPOINT}/${SOURCE_CONTAINER}"
  [ -n "$SOURCE_PREFIX" ] && SRC="${SRC}/${SOURCE_PREFIX}"
  SRC="${SRC}/*"

  DST="${DEST_ENDPOINT}/${DEST_CONTAINER}"
  [ -n "$DEST_PREFIX" ] && DST="${DST}/${DEST_PREFIX}"
  ```

- `--from-to` takes `$FROM_TO` instead of the literal `BlobFile`.
- `--trailing-dot` is appended only when `AZCOPY_TRAILING_DOT` is non-empty.
- The banner prints both endpoints and `FROM_TO`.
- The child invocation passes `SOURCE_ENDPOINT`, `DEST_ENDPOINT` and
  `DEST_CONTAINER` in place of `ACCOUNT`, `CONTAINER` and `SHARE`.

**`remove-migrated.sh`**

- `ACCOUNT`/`CONTAINER`/`SHARE` become `SOURCE_ENDPOINT`/`SOURCE_CONTAINER`/
  `DEST_CONTAINER`, and `DEST_ENDPOINT` is added.
- `SRC_ROOT` and `DST_ROOT` are assembled from the endpoints, appending each
  prefix only when it is non-empty.
- Everything else — the two-source-of-truth rule, the default verdict of keep,
  the dry run when `CLEANUP_ENABLED` is not `true` — is unchanged.

**`candidates.awk`**

- Takes `SRC_ENDPOINT`, `DST_ENDPOINT`, `CONTAINER` and `PREFIX` instead of
  `ACCOUNT`, `CONTAINER` and `PREFIX`.
- A `reesc()` helper escapes regex metacharacters before the endpoints go into
  the match patterns. The current code interpolates a hostname with unescaped
  dots; an arbitrary endpoint makes that a real defect rather than a latent one.
- `relpath()` gains an empty-prefix guard. Today an empty `PREFIX` makes
  `index(p, PREFIX "/") != 1` true for every path, so every candidate is
  discarded. With the guard, an empty prefix means the container root.

**`decide.awk`**

- `SHARE` is renamed `DEST_CONTAINER`. The "did the job write where we expected"
  check is otherwise identical.

**`parse-list.awk`**

- Unchanged. `azcopy list --machine-readable --running-tally` emits the same
  `<path>; Content Length: <n>` lines for a blob container and a file share.

## 5. Container

`containers/azcopy/Dockerfile` keeps the Azure Linux 3.0 base, the non-root uid
1000, and the read-only-root contract. One change:

```dockerfile
ARG AZCOPY_VERSION=10.32.4
RUN tdnf -y install azcopy-${AZCOPY_VERSION}
```

Pinning makes a rebuild of an old commit reproducible and turns an azcopy bump
into a one-line PR that git-cliff converts into a release. CI reads the ARG for
the chart's `appVersion` and for the image's azcopy alias tag.

**Risk.** The Azure Linux `tdnf` repository may carry only the newest azcopy, in
which case an exact-version install fails. The implementation plan must verify
this first. If exact pinning is unavailable, the fallback is to download the
versioned tarball from `aka.ms` and verify a recorded SHA-256, keeping the ARG
as the single source of truth.

`CONTAINER.md` moves next to the Dockerfile and drops the customer-specific
registry examples. Its five verification commands become a CI job.

## 6. Tests

The delete decision is the dangerous part of this system and has no tests today.

**awk golden tests** (`hack/test-awk.sh`, fixtures in `test/`). Plain `sh` and
`diff`, no framework. Cases:

- `candidates.awk` — Blob→File and File→Blob job output; percent-encoded UTF-8
  filenames; an empty prefix; a URL outside the prefix; a duplicate path.
- `parse-list.awk` — a blob listing, a file-share listing, directory entries,
  a trailing `\r`.
- `decide.awk` — verified delete; missing at destination; size mismatch; job
  wrote to the wrong container; reconcile adding a stranded file; `DESTCHECK=0`.

**Chart tests.** `helm lint`, then `helm template` against each of the four
`ci/*-values.yaml` files, asserting the rendered `--from-to`, both base URLs,
and that `--trailing-dot` is absent from the Blob→Blob rendering.

**Static checks.** `shellcheck` on the shell scripts, `hadolint` on the
Dockerfile.

**Container checks.** Build without pushing, then run the five `CONTAINER.md`
commands plus `azcopy copy --help`, asserting that `--from-to` and
`--trailing-dot` still exist and that the pinned version matches the ARG.

## 7. SAS documentation

`helm/azcopy-move/README.md` gains a section with a permission matrix and the
`az` commands for every side.

| Side | Command | Permissions |
|---|---|---|
| blob source | `az storage container generate-sas` | `rdl` |
| blob destination | `az storage container generate-sas` | `rcwl` |
| file source | `az storage share generate-sas` | `rdl` |
| file destination | `az storage share generate-sas` | `rcwl` |

It also documents:

- the account-key path, with `az storage account keys list`;
- the user delegation SAS (`--auth-mode login --as-user`), which avoids handing
  out the account key but works for Blob only and expires within seven days —
  Azure Files has no user delegation SAS and needs the account key;
- that `d` on the source is only needed once `cleanup.enabled` is `true`, since
  a dry run calls no delete API;
- that a SAS expires and nothing in the chart warns you.

## 8. Continuous integration

### 8.1 Shared composite actions

`dobbo-ca/.github` is the home for reusable CI. It currently ships
`actions/semver-bump` and a Go-only reusable workflow. This design adds three
composite actions there and modifies one, then moves the `v1` tag.

**`actions/semver-bump` — modified, backward compatible.**

New inputs, both defaulting to today's behaviour:

| Input | Default | Effect |
|---|---|---|
| `tag-prefix` | `""` | tags are `<prefix><version>`, e.g. `chart/v0.2.0` |
| `include-path` | `""` | passed to `git cliff --include-path`, so only matching commits bump |

The `before` computation currently greps `^v?[0-9]+\.[0-9]+\.[0-9]+$`, which
never matches a prefixed tag. It becomes prefix-aware. A new `tag` output
carries the full prefixed tag while `version` stays bare.

This action already releases other repos. The change must be verified with
`gh workflow run ... -f dry_run=true` on an existing consumer before the `v1`
tag moves.

**`actions/container-build` — new.** Wraps buildx: login, build, push, and
emits the digest. Inputs: `registry`, `image`, `context`, `dockerfile`,
`platforms`, `tags` (multiline), `build-args`, `push`, `github-token`.

**`actions/helm-build` — new.** A generic version of the local action in
`enshrouded`, which hardcodes an enshrouded test-values file. Inputs:
`chart-path`, `chart-name`, `version`, `app-version`, `oci-path`, `registry`,
`values-files` (for the template check), `push`, `github-token`.

**`actions/release-labels` — new.** Labels a pull request with what a merge will
publish. Inputs: `chart-paths`, `image-paths` (glob lists), the three label
names, and `github-token`. It lists the PR's changed files, matches the globs,
creates any missing label, then applies and removes labels so the result is
exact on every run.

| Changed | Labels |
|---|---|
| `helm/**` | `release:chart` |
| `containers/**` | `release:image` |
| both | `release:chart`, `release:image` |
| neither | `release:none` |

Two independent labels plus an explicit `release:none` cover four states with
three names, and an unlabelled PR always means the action failed to run. The
job needs `pull-requests: write`.

### 8.2 Two version lines

The chart and the image version independently, so a chart-only fix does not
republish an identical image under a new tag.

```
chart/v0.2.0   <- .cliff-chart.toml, include-path helm/**
image/v0.4.1   <- .cliff-image.toml, include-path containers/**
```

Each config sets a `tag_pattern` matching only its own prefix, so the two lines
never see each other's tags.

`Chart.yaml` keeps a `version:` field because Helm requires one, but it is a
placeholder. `helm package --version "$VERSION"` overwrites it with the value
`semver-bump` resolved, so nobody edits it by hand.

`.github/workflows/release.yml` runs one job per line. Each job guards on the
ref so a `chart/v*` tag does not trigger the image job or the reverse.

### 8.3 Published tags

| Artifact | Tags |
|---|---|
| chart | `ghcr.io/dobbo-ca/azcopy-move/azcopy-move:<chart semver>` |
| image | `ghcr.io/dobbo-ca/azcopy-move/azcopy:<image semver>` and `:<AZCOPY_VERSION>` |

The `<AZCOPY_VERSION>` tag is a moving alias — a later image release with the
same azcopy rebuilds it. Nothing may pin to it.

The chart's `appVersion` is `AZCOPY_VERSION`, read from the Dockerfile ARG,
which is the conventional meaning of the field.

Because `appVersion` names azcopy rather than the image, the chart cannot
default `image.tag` to `.Chart.AppVersion`. Instead the chart release job
rewrites `values.yaml` immediately before `helm package`:

```sh
IMAGE_VERSION=$(git tag --list 'image/v*' --sort=-v:refname | head -1 | sed 's|^image/v||')
yq -i '.image.tag = strenv(IMAGE_VERSION)' helm/azcopy-move/values.yaml
```

The packaged chart therefore always pins an immutable image semver, while the
git working copy keeps `image.tag: ""`. Pinning by digest instead is a
follow-up, not part of this work.

### 8.4 Pull request workflow

`.github/workflows/pr.yml` runs `release-labels`, `shellcheck`, `hadolint`, the
awk golden tests, the chart lint and four-direction template matrix, and a
no-push container build followed by the `CONTAINER.md` verification commands.

## 9. Customer wrapper chart

The generic chart carries no customer values. Each customer gets an umbrella
chart outside any git repository.

```
<customer-wrapper-dir>/azcopy-move-<customer>/
├── Chart.yaml        name: azcopy-move-<customer>
│                     dependencies:
│                       - name: azcopy-move
│                         version: "0.1.0"
│                         repository: "oci://ghcr.io/dobbo-ca/azcopy-move"
├── values.yaml       real account, container, prefix, share, schedule
├── Makefile          deps check secret diff install run-now logs suspend resume
├── check-sas.sh      validates sv=, sig=, permissions; warns on near expiry
├── README.md         what this is, and how to rotate the SAS
└── .gitignore
```

It has no templates of its own. All configuration is a `azcopy-move:` block in
`values.yaml`.

`<customer-wrapper-dir>` is not a git repository, so the real account
names cannot reach a remote by accident. The `.gitignore` is a second guard.

**Secrets stay out of band.** `make secret` runs `kubectl create secret generic
--from-file` against the token files already in
`<customer-wrapper-dir>/azcopy-secrets/`, and `values.yaml` sets
`sas.existingSecret`. No token reaches a values file, a Helm release, or a shell
argument list. `make install` runs `helm upgrade --install --create-namespace`,
so the namespace is a Makefile variable rather than a template.

`check-sas.sh` carries over the validation from the retired `deploy.sh`: reject a
leading `?`, require `sv=` and `sig=`, require each needed permission letter, and
warn when the expiry is inside 48 hours. The same script ships in the public repo
under `hack/` for anyone else minting tokens.

`deploy.sh` and `deploy.env` retire. The Makefile replaces them.

**Cutover.** The live release is a single-purpose chart in a customer-specific
namespace. The new wrapper installs into namespace `azcopy-move`. The old release must be
uninstalled after the new one runs a clean cycle, not before, and both must
never be unsuspended at once — two concurrent drains would copy and delete the
same objects.

## 10. Scrubbing

The source material carries a customer's storage account name, container name
and kubeconfig path in `deploy.env.example`, `README.md` and `values.yaml`
comments. Nothing published may contain them. Public examples use `<account>`,
`<container>`, `<share>`. A CI grep asserts the known identifiers are absent.

## 11. Out of scope

- Local filesystem and PVC endpoints (`--from-to` `*Local`). The verify step
  would need a filesystem listing path.
- Alerting on a failed run, and any SAS expiry check inside the cluster.
- Workload identity or OIDC authorization.
- More than one source/destination pair per release. A second pair is a second
  Helm release, or a `dependencies` alias in the wrapper chart.
- Migrating `enshrouded` to the new shared `helm-build` action.

## 12. Assumptions to verify during implementation

1. `tdnf install azcopy-<version>` accepts an exact version on Azure Linux 3.0
   and 10.32.4 is present. Section 5 gives the fallback.
2. `azcopy` rejects `--trailing-dot` for a `BlobBlob` transfer. If it merely
   ignores the flag, the conditional in section 3.2 is still correct but stops
   being load-bearing.
3. `azcopy list --machine-readable --running-tally` emits the same line format
   for a file share as for a blob container.
4. `azcopy rm --list-of-files --recursive` works against a file share, so
   File→Blob can delete its source.
5. `git cliff --include-path` combined with a prefix-scoped `tag_pattern`
   produces two independent version lines in one repository.
