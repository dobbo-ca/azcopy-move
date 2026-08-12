# `actions/semver-bump` patch

Target repo: `dobbo-ca/.github`, file `actions/semver-bump/action.yml`.

This diff is backward compatible: every existing caller (`dobbo-ca/.github`'s
own `release-go.yml`, `dobbo-ca/graphify-go`, `dobbo-ca/azure-go-cli`,
`dobbo-ca/jiratui`, `editorlint/action`, `editorlint/editorlint`) omits the two
new inputs, so `tag-prefix` and `include-path` default to `""` and the action
behaves exactly as it does today. `azcopy-move` is the first consumer to pass
non-empty values, which is what lets `chart/v*` and `image/v*` exist as two
independent version lines in one repository.

Verified against a real clone driven with local bare remotes (see the
`semver-bump-compat` verified-assumption notes for the full transcript): the
four pre-existing call shapes (`release`, `beta`, `release-on-merge`, no-op)
produce byte-identical `version` output before and after, with `tag` added as
a new output. The prefixed variants were also driven end-to-end (`chart/v*`
beta, no-op via `include-path` scoping the commit out, idempotent re-run
reusing an existing tag, `release` and `release-on-merge` modes).

## Diff

This is real `git diff` output, produced against a live clone of
`dobbo-ca/.github` and verified with `git apply --check` — apply it with
`git apply <file>` (default `-p1`), not by hand. The `index` line's blob
hashes are from the verification clone and are informational only; `git
apply` matches on the context lines, not the hashes, so this applies cleanly
against `main`'s current content regardless of drift since verification.

```diff
diff --git a/actions/semver-bump/action.yml b/actions/semver-bump/action.yml
index 669104c..031031e 100644
--- a/actions/semver-bump/action.yml
+++ b/actions/semver-bump/action.yml
@@ -15,6 +15,12 @@ inputs:
   dry-run:
     description: 'true => compute only, never create or push a tag.'
     default: 'false'
+  tag-prefix:
+    description: 'Literal text before the semver in a tag, e.g. "chart/v" => chart/v0.2.0. Empty (default) => unprefixed tags.'
+    default: ''
+  include-path:
+    description: 'Glob passed to git-cliff --include-path; only commits touching it bump. Empty (default) => all paths.'
+    default: ''
 outputs:
   version:
     description: 'Resolved version. beta => X.Y.Z-beta.N ; release => the pushed tag ; release-on-merge => X.Y.Z. Empty when nothing to release.'
@@ -22,6 +28,9 @@ outputs:
   changed:
     description: 'true when a release/beta should proceed.'
     value: ${{ steps.r.outputs.changed }}
+  tag:
+    description: 'Full git tag: <tag-prefix><version>. Equals version when tag-prefix is empty. Empty when nothing to release.'
+    value: ${{ steps.r.outputs.tag }}
   is_beta:
     description: 'true for a beta prerelease.'
     value: ${{ steps.r.outputs.is_beta }}
@@ -42,6 +51,8 @@ runs:
         MODE: ${{ inputs.mode }}
         CONFIG: ${{ inputs.config }}
         DRY_RUN: ${{ inputs.dry-run }}
+        PREFIX: ${{ inputs.tag-prefix }}
+        INCLUDE_PATH: ${{ inputs.include-path }}
       run: |
         set -euo pipefail
 
@@ -54,27 +65,44 @@ runs:
         fi
 
         emit() { # $1 version  $2 changed  $3 is_beta  $4 is_release
+          local tag="${1:+${PREFIX}$1}"
           {
             echo "version=$1"
+            echo "tag=$tag"
             echo "changed=$2"
             echo "is_beta=$3"
             echo "is_release=$4"
           } >> "$GITHUB_OUTPUT"
-          echo "semver-bump: mode=$mode version='$1' changed=$2 beta=$3 release=$4"
+          echo "semver-bump: mode=$mode version='$1' tag='$tag' changed=$2 beta=$3 release=$4"
         }
 
         # release: the human-pushed tag IS the version; nothing to compute or push.
+        # $PREFIX is stripped so 'version' stays bare and 'tag' keeps the full ref.
         if [ "$mode" = release ]; then
-          emit "${GITHUB_REF#refs/tags/}" true false true
+          ref_tag="${GITHUB_REF#refs/tags/}"
+          emit "${ref_tag#"$PREFIX"}" true false true
           exit 0
         fi
 
         # beta / release-on-merge: compute next FINAL version.
         # tag_pattern in $CONFIG excludes prerelease tags, so betas never become the base.
-        # 'before' = highest existing FINAL tag (prefix-agnostic; ignores X.Y.Z-beta.N
-        # prereleases and moving major aliases like v0/v1). Empty on a repo with none.
-        before="$(git tag --list --sort=-v:refname | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' | head -n1 || true)"
-        next="$(git cliff --config "$CONFIG" --bumped-version 2>/dev/null || echo '')"
+        # 'before' = highest existing FINAL tag carrying $PREFIX (ignores X.Y.Z-beta.N
+        # prereleases, moving major aliases like v0/v1, and the other version line's
+        # prefix). Empty on a repo with none. $PREFIX must be regex-literal.
+        # git-cliff echoes the matched tag verbatim from --bumped-version, so $next
+        # is prefixed too and compares/sorts against $before as-is.
+        before="$(git tag --list --sort=-v:refname | grep -E "^${PREFIX}v?[0-9]+\.[0-9]+\.[0-9]+$" | head -n1 || true)"
+        # --unreleased is required, not optional: without it, a release commit
+        # that lands outside its own include_paths makes its own tag invisible
+        # to the path filter, git-cliff rebases off the PRIOR tag, and recomputes
+        # a version that's <= one that already exists. Verified strictly safer —
+        # it still honours tag_pattern and still returns the initial_tag on a
+        # zero-tag repo. See the git-cliff-two-lines verified-assumption notes.
+        cliff_args=(--config "$CONFIG" --unreleased)
+        if [ -n "$INCLUDE_PATH" ]; then
+          cliff_args+=(--include-path "$INCLUDE_PATH")
+        fi
+        next="$(git cliff "${cliff_args[@]}" --bumped-version 2>/dev/null || echo '')"
         echo "last-final='$before' next='$next'"
 
         if [ -z "$next" ] || [ "$next" = "$before" ]; then
@@ -95,16 +123,18 @@ runs:
           fi
         fi
 
+        bare="${next#"$PREFIX"}"
         if [ "$mode" = beta ]; then
-          version="${next}-beta.${GITHUB_RUN_NUMBER}"
+          version="${bare}-beta.${GITHUB_RUN_NUMBER}"
           is_beta=true;  is_release=false
         else
-          version="$next"                 # release-on-merge
+          version="$bare"                 # release-on-merge
           is_beta=false; is_release=true
         fi
+        tag="${PREFIX}${version}"
 
         if [ "$DRY_RUN" = true ]; then
-          echo "dry-run: would create tag $version"
+          echo "dry-run: would create tag $tag"
           emit "$version" true "$is_beta" "$is_release"
           exit 0
         fi
@@ -114,8 +144,8 @@ runs:
         # tag already exists on the remote, don't recreate/repush it — 'git tag'
         # would abort (tag exists) or the push would be non-ff rejected, failing
         # the re-run under set -e. Reuse the existing tag and emit the version.
-        if git ls-remote --exit-code --tags origin "refs/tags/$version" >/dev/null 2>&1; then
-          echo "tag $version already exists on remote — reusing (idempotent re-run)"
+        if git ls-remote --exit-code --tags origin "refs/tags/$tag" >/dev/null 2>&1; then
+          echo "tag $tag already exists on remote — reusing (idempotent re-run)"
           emit "$version" true "$is_beta" "$is_release"
           exit 0
         fi
@@ -123,6 +153,6 @@ runs:
         # Annotated tags require a committer identity (github-actions[bot]).
         git config user.name  'github-actions[bot]'
         git config user.email 'github-actions[bot]@users.noreply.github.com'
-        git tag -a "$version" -m "$version"
-        git push origin "refs/tags/$version"
+        git tag -a "$tag" -m "$tag"
+        git push origin "refs/tags/$tag"
         emit "$version" true "$is_beta" "$is_release"
```

## Design notes

1. `local tag="${1:+${PREFIX}$1}"` inside `emit` rather than a 5th positional
   argument. All six `emit` call sites stay unchanged, and the empty-version
   no-op paths get `tag=` for free. Do not write `[ -n "$1" ] && tag=...` —
   under `set -e` that fails the step when the version is empty. Keep `local`:
   `tag` is also used at caller scope, and shell functions share scope.
2. `^${PREFIX}v?[0-9]+...` keeps the `v?` rather than folding the `v` into
   `$PREFIX`. With `PREFIX=""` the regex is byte-identical to today's; with
   `PREFIX="chart/v"` the `v?` is harmlessly optional. One regex serves both
   `chart/` and `chart/v` conventions.
3. A bash array for the cliff args, not `${INCLUDE_PATH:+--include-path "$INCLUDE_PATH"}`
   — the unquoted-expansion form leaves the glob exposed to pathname expansion
   in some shells; the array is unambiguous.
4. `$PREFIX` is interpolated unescaped into a `grep -E` pattern. `chart/v` and
   `image/v` are regex-literal (no metacharacters), so this is safe for both
   values this repo uses. A `tag-prefix` containing `.`, `+`, `*` etc. is not
   supported by this patch.
5. `--unreleased` is always passed, not made conditional on `$INCLUDE_PATH`.
   Without it, a release commit for one version line that lands outside its
   own `include_paths` (e.g. a chart release whose commit only touches a root
   `VERSION` file) makes that line's own tag invisible to the path filter;
   `--bumped-version` then rebases off the *prior* tag and can return a
   version <= one that already exists, permanently wedging that line's
   releases. `--unreleased` is verified strictly safer — it still honours
   `tag_pattern` and still returns `initial_tag` on a zero-tag repo.

## Rollout sequence (do not reorder)

1. Land this diff on `main` in `dobbo-ca/.github`.
2. Point one consumer at the commit SHA (not `v1`) and run
   `gh workflow run release.yml -f dry_run=true` on `dobbo-ca/graphify-go`
   (the cheapest signal — `mode: auto`, dry-run passthrough). Assert the log
   line still reads `version='v0.x.y-beta.N'` with the `v`.
3. Do the same for `editorlint/action` (`mode: release-on-merge`) — it
   re-derives `before` itself downstream and consumes `outputs.version`, so it
   is the consumer most likely to notice a shape change.
4. Cut an immutable `v1.1.0` tag at the current `v1` SHA as a rollback point
   (there is none today — `v1` is the only tag in the repo).
5. Move the tag: `git tag -f v1 <sha> && git push --force origin refs/tags/v1`.

See `docs/shared-ci/README.md` for the azcopy-move-specific setup this patch
enables (seeding `chart/v0.0.0` / `image/v0.0.0`-equivalent, `tag-prefix`
values, and the `image.tag` lookup fix).
