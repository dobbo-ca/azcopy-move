# azcopy-move

A container image with `azcopy` and nothing else, plus a Helm chart that runs
it as a Kubernetes CronJob. The chart copies a prefix from an Azure Blob
container or Azure Files share to another, verifies what actually arrived,
then deletes only the verified source objects.

All four directions work: Blob→File, Blob→Blob, File→Blob, File→File, across
two different storage accounts, with a per-side endpoint override for private
endpoints and sovereign clouds.

Authorization is SAS only. There is no workload identity and no OIDC.

See `helm/azcopy-move/README.md` for the value model, worked examples, the
SAS commands, and the values table. See `containers/azcopy/CONTAINER.md` for
the image's requirements.

## Published artifacts

Two things get published, independently versioned:

| Artifact | Path |
|---|---|
| Helm chart | `ghcr.io/dobbo-ca/charts/azcopy-move` |
| Container image | `ghcr.io/dobbo-ca/containers/azcopy-move` |

The image also carries a moving alias tag equal to its pinned `azcopy`
version, e.g. `:10.32.6`. A later image release with the same `azcopy`
version rebuilds that tag in place. Do not pin to it — pin the image semver.

## Quick start

```bash
helm install move oci://ghcr.io/dobbo-ca/charts/azcopy-move \
  --version 0.1.0 \
  -n azcopy-move --create-namespace \
  -f values.yaml
```

Read `helm/azcopy-move/README.md` first. It covers the source/destination
value model, the SAS Secret you must create out of band before installing,
and the safe rollout (`cleanup.enabled=false` first).

## Two version lines

The chart and the image version independently:

```
chart/v0.2.0   <- anything under helm/**
image/v0.4.1   <- anything under containers/**
```

A chart-only fix does not republish an identical image under a new tag, and
vice versa.

On a pull request, the `release-labels` action tells you which line(s) a
merge will publish:

| Label | Meaning |
|---|---|
| `release:chart` | the PR touches `helm/**`; merging bumps and publishes the chart |
| `release:image` | the PR touches `containers/**`; merging bumps and publishes the image |
| both labels | the PR touches both; both get published |
| `release:none` | the PR touches neither; nothing gets published |

An unlabelled PR means the labelling action failed to run, not that nothing
will be published — check the workflow run.

## Build the container locally

```bash
docker build --platform linux/amd64 -t azcopy-move-local:10.32.6 containers/azcopy
```

See `containers/azcopy/CONTAINER.md` for the full requirements and the
verification commands the build must pass.
