# Container requirements — azcopy

Hand this to whoever builds the image. The `Dockerfile` in this directory
already implements all of it; this document states the requirements so they can
be checked or re-implemented on a different base.

## Purpose

A single-purpose image for a Kubernetes CronJob. It runs POSIX shell scripts
that call `azcopy` to copy a storage prefix to a destination and then delete
the verified source objects.

## Hard requirements

| Requirement | Value | Why |
|---|---|---|
| `azcopy` on `PATH` | pinned by `ARG AZCOPY_VERSION` | the only tool the scripts call |
| POSIX shell at `/bin/sh` | any | scripts are `#!/bin/sh`, no bash features |
| `awk` | gawk, mawk or busybox awk | all parsing and the delete decision |
| `sed`, `grep`, `sort`, `wc`, `tr`, `head`, `tee`, `date`, `mkdir`, `dirname` | coreutils | used by the scripts |
| CA certificates | any current bundle | TLS to `*.core.windows.net` |
| libc | **glibc** | see "Alpine" below |
| Non-root user | uid 1000, gid 1000 | Kyverno `require-run-as-nonroot` |
| Architecture | `linux/amd64` | only platform verified against the tdnf pin |

## Explicitly NOT required

- **No PowerShell.** Removed; it cost roughly 300 MB of base image.
- **No Azure CLI.** Zero `az` calls in the scripts. Credentials arrive as
  pre-minted SAS tokens, so nothing needs to talk to ARM.
- **No `curl`, `python`, `jq`, or a package manager at runtime.**
- **No Kubernetes client.** The pod never calls the API server, and its
  ServiceAccount token is not mounted.

## Alpine will not work

Microsoft publishes azcopy packages for `dnf` (RHEL), `zypper` (SUSE), `apt`
(Ubuntu, Debian) and `tdnf` (Azure Linux). **There is no `apk` package and musl
is not a supported target.** Do not substitute an Alpine base to save space.

## Recommended base

```
mcr.microsoft.com/azurelinux/base/core:3.0
```

Reasons, in order:

1. `tdnf install azcopy-<version>` is an officially packaged, GPG-signed path,
   so there is no tarball download at build time and the distro carries
   security patches.
2. glibc.
3. An unpinned `tdnf install azcopy` can resolve to a prerelease build ahead of
   the newest stable version — the `ARG AZCOPY_VERSION` pin in the Dockerfile
   exists specifically to avoid that, and must never be dropped.

`debian:12-slim` with the `packages.microsoft.com` apt repository is an
acceptable alternative and slightly larger.

## Runtime contract

The chart supplies all of this; the image must not fight it.

- **Read-only root filesystem.** Everything writable is an `emptyDir`:
  `/work` and `/tmp`.
- `HOME=/work`, `AZCOPY_JOB_PLAN_LOCATION=/work/plans`,
  `AZCOPY_LOG_LOCATION=/work/logs`. Do not bake a different `HOME`.
- `SOURCE_ENDPOINT`, `SOURCE_CONTAINER`, `SOURCE_PREFIX`, `DEST_ENDPOINT`,
  `DEST_CONTAINER`, `DEST_PREFIX` and `FROM_TO` are supplied by the chart at
  runtime; the scripts read them and build no hostnames of their own.
- Scripts are mounted at `/scripts` from a ConfigMap, mode `0555`. Do not copy
  them into the image; they would be shadowed.
- Entry point is `/bin/sh /scripts/invoke-migration.sh`.
- Container security context: `allowPrivilegeEscalation: false`,
  `capabilities: drop: [ALL]`, `readOnlyRootFilesystem: true`.
- Pod security context: `seccompProfile: RuntimeDefault`.

## Build and verify

```bash
docker build --platform linux/amd64 -t ghcr.io/dobbo-ca/containers/azcopy-move:10.32.6 .

# All seven must succeed.
docker run --rm --user 1000:1000 ghcr.io/dobbo-ca/containers/azcopy-move:10.32.6 -c 'azcopy --version'
docker run --rm --user 1000:1000 ghcr.io/dobbo-ca/containers/azcopy-move:10.32.6 -c 'awk --version | head -1'
docker run --rm --user 1000:1000 ghcr.io/dobbo-ca/containers/azcopy-move:10.32.6 -c 'id'
docker run --rm --user 1000:1000 ghcr.io/dobbo-ca/containers/azcopy-move:10.32.6 -c \
  'for c in sed grep sort wc tr head tee date mkdir dirname; do command -v $c || { echo MISSING $c; exit 1; }; done'
# A bare "--tmpfs /work" mounts root-owned and uid 1000 cannot write to it, which
# reports a failure the cluster would not have. Kubernetes gives the emptyDir to
# the pod's fsGroup, so give the tmpfs the same owner to match.
docker run --rm --user 1000:1000 --read-only \
  --tmpfs /work:uid=1000,gid=1000 --tmpfs /tmp:uid=1000,gid=1000 \
  ghcr.io/dobbo-ca/containers/azcopy-move:10.32.6 -c 'touch /work/x && echo writable-ok'
docker run --rm --user 1000:1000 ghcr.io/dobbo-ca/containers/azcopy-move:10.32.6 -c \
  'azcopy copy --help' # must expose --from-to and --trailing-dot
docker run --rm --user 1000:1000 ghcr.io/dobbo-ca/containers/azcopy-move:10.32.6 -c \
  'azcopy --version' # reported version must match the Dockerfile's ARG AZCOPY_VERSION pin
```

`id` must report `uid=1000 gid=1000`.

Then push, and set `image.repository` and `image.tag` in the chart's
`values.yaml`. Pin an immutable tag or a digest; never `latest`.

## Size expectation

Measured, uncompressed, `linux/amd64`, azcopy 10.32.6: **64 MB**. The PowerShell
version it replaces was roughly 400 MB.
