# Shared CI staged for `dobbo-ca/.github`

`azcopy-move`'s workflows (`.github/workflows/pr.yml`, `.github/workflows/release.yml`)
already reference these as `dobbo-ca/.github/actions/<name>@v1`. They will 404
until a human lands this directory's contents in that separate repo — deliberately,
since `dobbo-ca/.github` has other live consumers and this session does not
push to it.

## What's here

| File | Target path in `dobbo-ca/.github` | Status |
|---|---|---|
| `container-build/action.yml` | `actions/container-build/action.yml` | new |
| `helm-build/action.yml` | `actions/helm-build/action.yml` | new |
| `release-labels/action.yml` | `actions/release-labels/action.yml` | new |
| `semver-bump.patch.md` | patch for `actions/semver-bump/action.yml` | modifies existing |

## Landing sequence

1. **Copy the three new action directories** into `dobbo-ca/.github/actions/`
   verbatim.
2. **Apply the diff in `semver-bump.patch.md`** to the existing
   `actions/semver-bump/action.yml`. It is backward compatible — every
   existing caller keeps working unchanged, see that file for the full
   rationale and the rollout/verification steps (dry-run against
   `graphify-go` and `editorlint/action` before moving `v1`).
3. **Commit and push to `main`** in `dobbo-ca/.github`.
4. **Cut an immutable rollback tag** at the current `v1` SHA, e.g. `v1.1.0`,
   before moving anything — there is no rollback point today, `v1` is the
   only tag in that repo.
5. **Move `v1`** to the new commit:
   ```sh
   git tag -f v1 <sha>
   git push --force origin refs/tags/v1
   ```
   `semver-bump.patch.md` has the verification steps to run against existing
   consumers between steps 3 and 5 — do not skip them, this action already
   releases six repos across `dobbo-ca` and `editorlint`.

## Repo-specific setup this unblocks, once `v1` moves

**Seed nothing before the first CI run — the `initial_tag` configs already
handle it.** `.cliff-chart.toml` and `.cliff-image.toml` (at the repo root of
`azcopy-move`) both carry `[bump] initial_tag`, which is enough on its own for
git-cliff to resolve a first version on a tagless repo (verified: a zero-tag
repo with `initial_tag = "chart/v0.1.0"` resolves `--bumped-version` to
`chart/v0.1.0`). No manual tag seeding is required.

Do not pre-seed `image/v0.0.0`. `release.yml`'s chart-release job resolves the
image tag to pin with `git tag --list 'image/v*' --sort=-v:refname | grep -E
'^image/v[0-9]+\.[0-9]+\.[0-9]+$' | head -1`, which only errors when the
result is empty. A seeded `image/v0.0.0` tag matches that grep, so a chart
release run before any real image has been published would silently pin
`ghcr.io/dobbo-ca/azcopy-move/azcopy:0.0.0` — a tag no build ever pushes —
instead of failing loudly. The first image release must be a real
`image/v<semver>` tag produced by the image job before any chart release
runs.

**`tag-prefix` values used by `release.yml`:** `chart/v` for the chart line,
`image/v` for the image line — the trailing `v` is deliberate so
`semver-bump`'s `version` output stays bare (`0.2.0`), which is what
`helm package --version` and an OCI tag both need, while its `tag` output
keeps the full ref (`chart/v0.2.0`).

**`include-path` values:** `helm/**` for the chart line, `containers/**` for
the image line. A release commit for either line should still touch a file
inside its own glob (e.g. bump something under `helm/` for a chart release):
a release commit that only touches a root-level file makes its own tag
invisible to the path filter on later runs. `semver-bump.patch.md` passes
`--unreleased` to `git-cliff --bumped-version`, which keeps the *version
number* correct even when that happens (it computes off the unreleased range
rather than rebasing off the prior tag), but the historical changelog body
still loses the release boundary. See the `git-cliff-two-lines`
verified-assumption notes for the reproduction.

**`image.tag` pin fix.** The naive `git tag --list 'image/v*' --sort=-v:refname
| head -1` sorts a prerelease (`image/v0.3.0-beta.9`) above a final release
and would pin the packaged chart to a beta image. `release.yml`'s
`chart-release` job filters with an anchored grep,
`grep -E '^image/v[0-9]+\.[0-9]+\.[0-9]+$'`, before taking the newest —
do not remove that filter if this step is ever edited.

## Why these three actions and not more

`container-build` and `helm-build` are both single-purpose wrappers with no
`azcopy-move`-specific assumptions baked in, so any other repo (Go binaries,
other charts) can adopt them later without a fork. `release-labels` is
similarly generic: it takes glob lists and label names as inputs rather than
hardcoding `release:chart` / `release:image` — this repo's `pr.yml` is what
supplies those literal values.

`helm-build` is a generalization of the local action in
`enshrouded/.github/actions/helm-build/action.yml`, which hardcodes an
enshrouded test-values file for its template-check step. The shared version
takes `values-files` as an input instead. Migrating `enshrouded` itself to the
shared action is out of scope for this work (spec §11).
