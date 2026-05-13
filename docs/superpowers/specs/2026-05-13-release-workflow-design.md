# Release Workflow Automation — Design

**Status:** proposed
**Date:** 2026-05-13
**Inspired by:** [byonk](https://github.com/oetiker/byonk)'s `release.yml`

## Goal

Turn rrdtool's release into a single click in the GitHub Actions "Run workflow" menu. The workflow must:

1. Refuse to run if CI is not green on `master` HEAD.
2. Compute the new version, finalize `CHANGES`, propagate version strings into all source locations, commit, and tag — all without human edits.
3. Produce the source tarball and the Windows MSVC binaries, attach them both to a single GitHub Release with extracted release notes.

Out of scope for this iteration: RPM and DEB packages. Those are sketched in the "Future extensions" section so the workflow can grow into them without restructuring.

## Constraints

- **Master only.** Branches like `1.9` are no longer used. The workflow runs only when dispatched from `refs/heads/master`.
- **CI is the gate.** A release must not happen if `Linux Build` or `Windows CI` failed on the commit at master HEAD.
- **One Release, all artifacts.** Source tarball + MSVC x64 zip + MSVC x86 zip attached to the same Release.
- **No SCP-to-james coupling.** The local `rrdtool-release` script's `scp` step is parallel/legacy, not on the critical path. The GitHub Release becomes the canonical drop.

## Non-goals

- DEB or RPM builds (sketched, deferred).
- MSYS2 release artifacts (MSYS2 stays in CI as a smoke test only).
- Changes to `build-test-linux.yml`, `ci-workflow.yml`, `code-coverage.yml`, `codeql-analysis.yml`. These remain push/PR-triggered.

## Workflow shape

One new file, `.github/workflows/release.yml`, with five jobs:

```
check-ci ──► prepare ──► build-source ──┐
                    └──► build-windows ─┴──► create-release
```

### Inputs

| Input | Type | Values | Purpose |
|---|---|---|---|
| `release_type` | choice | `bugfix`, `feature`, `major` | Selects SemVer bump from the latest `v*` tag |

### Job: `check-ci`

Runs on `ubuntu-latest`. First step is a branch guard:

```bash
if [ "${{ github.ref }}" != "refs/heads/master" ]; then
  echo "::error::Releases must be dispatched from master"
  exit 1
fi
```

Then verifies that the two workflows we depend on were `success` for the commit at `github.sha`:

- `Linux Build` (`.github/workflows/build-test-linux.yml`)
- `Windows CI` (`.github/workflows/ci-workflow.yml`)

Implementation: use `gh run list --workflow=<name> --branch=master --commit=$SHA --status=success --limit=1 --json conclusion` and assert the result is non-empty. If a run is `in_progress` for the same commit, poll for up to 30 minutes using `gh run watch`. If failed or missing, fail with a clear error pointing at the failed run URL.

Why a pre-flight API check instead of `workflow_run` chaining: `workflow_run` only fires on auto-dispatch from completed runs, which doesn't compose with `workflow_dispatch`. The API check is what gives a manual trigger the "must be green" property.

### Job: `prepare`

Needs: `check-ci`. Runs on `ubuntu-latest`. Permissions: `contents: write`.

Steps:

1. **Checkout** master with `fetch-depth: 0` so tags are available.

2. **Compute new version**:

   ```bash
   LATEST=$(git tag -l 'v[0-9]*.[0-9]*.[0-9]*' | sort -V | tail -1)
   LATEST=${LATEST:-v0.0.0}
   IFS=. read -r MAJOR MINOR PATCH <<< "${LATEST#v}"
   case "${{ inputs.release_type }}" in
     major)   NEW=$((MAJOR+1)).0.0 ;;
     feature) NEW=${MAJOR}.$((MINOR+1)).0 ;;
     bugfix)  NEW=${MAJOR}.${MINOR}.$((PATCH+1)) ;;
   esac
   ```

   Outputs `version` (e.g. `1.9.1`) and `tag` (e.g. `v1.9.1`) for downstream jobs.

3. **Write `VERSION`** with the new value.

4. **Propagate the version** by calling `conftools/bump-version.sh "$NEW"`. This new script contains the perl substitutions currently inlined in `rrdtool-release` (lines 8–19):
   - `bindings/perl-*/*.pm` — `$VERSION = NUMVERS;`
   - `src/*.h`, `src/*.c` — `RRDtool X.Y.Z` strings and copyright year
   - `rrdtool.spec` — `Version:` line
   - `doc/rrdbuild.pod` — `rrdtool-X.Y.Z` references and `vX.Y.Z`
   - `win32/*.rc` — copyright year
   - `win32/rrd_config.h` — `PACKAGE_MAJOR`, `PACKAGE_MINOR`, `PACKAGE_REVISION`, `PACKAGE_VERSION`, `NUMVERS`

   Extracting this into a script gives one tested code path for both CI and the local maintainer script. `rrdtool-release` is refactored to source it.

5. **Finalize `CHANGES`**: rewrite the leading block

   ```
   RRDtool - master ...
   ====================
   Bugfixes
   --------
   ...
   Features
   --------
   ...
   ```

   into

   ```
   RRDtool - master ...
   ====================
   Bugfixes
   --------

   Features
   --------

   RRDtool X.Y.Z - YYYY-MM-DD
   ==========================
   Bugfixes
   --------
   ...
   Features
   --------
   ...
   ```

   That is: rename the existing master block's heading to the new version+date (with `=` underline matching title length), and prepend a fresh empty master block above it.

   Implementation: a single perl `-0777` script that captures the master block's contents, writes the empty master block first, then the renamed version block with the captured contents. See `appendix-changes-rewrite.pl` (will be the in-workflow script body, not a separate file — small enough to inline).

6. **Commit, tag, push**:

   ```bash
   git config user.name "github-actions[bot]"
   git config user.email "github-actions[bot]@users.noreply.github.com"
   git add -u                            # only modified tracked files
   git commit -m "release v$NEW"
   git tag -a "v$NEW" -m "release v$NEW"
   git push origin master --follow-tags
   ```

   `git add -u` stages only tracked files that the bump touched. `prepare` does not run `./bootstrap`, so there are no untracked build artifacts to accidentally include.

### Job: `build-source`

Needs: `prepare`. Runs on `ubuntu-latest`.

1. Checkout `${{ needs.prepare.outputs.tag }}`.
2. Install build deps (same set as today's release-source.yml: `autopoint build-essential gettext libpango1.0-dev ghostscript`).
3. `./bootstrap && ./configure && make dist`.
4. Upload `rrdtool-X.Y.Z.tar.gz` as a workflow artifact named `source-tarball`.

The "re-extract and rebuild from tarball" sanity check that `build-test-linux.yml` already performs on every push to master is not duplicated here — the CI gate guarantees it passed at master HEAD, and the release commit only changes version strings, so it cannot break the build.

### Job: `build-windows`

Needs: `prepare`. Runs on `windows-2022` with the same matrix as today's `release-windows.yml`:

```yaml
matrix:
  vcpkg_triplet: [x64-windows, x86-windows]
```

Steps:

1. Checkout `${{ needs.prepare.outputs.tag }}` with `submodules: true`.
2. `vcpkg build` (johnwason/vcpkg-action@v7) with the existing `vcpkgCommitId` `84bab45d415d22042bd0b9081aea57f362da3f35`.
3. `nmake -f win32\Makefile_vcpkg.msc` with the matrix configuration.
4. `win32\collect_rrdtool_vcpkg_files.bat ${{ matrix.configuration }}`.
5. **New**: zip the collected `rrdtool-X.Y.Z-${{ matrix.configuration }}_vcpkg/` directory into `rrdtool-X.Y.Z-${{ matrix.configuration }}_vcpkg.zip` (today the workflow uploads the directory as a tree, which isn't a useful release artifact).
6. Upload the zip as a workflow artifact named `windows-${{ matrix.configuration }}`.

### Job: `create-release`

Needs: `prepare`, `build-source`, `build-windows`. Runs on `ubuntu-latest`. Permissions: `contents: write`.

1. Checkout the tag (sparse, just `CHANGES`).
2. `actions/download-artifact@v6` with `pattern: '*'`, `merge-multiple: true`, into `dist/`.
3. **Extract release notes** keyed on the version (not the first-three-lines heuristic the current workflow uses, which would now grab the empty master placeholder):

   ```bash
   awk -v v="$VERSION" '
     $0 ~ "^RRDtool " v " " { found=1 }
     found && /^RRDtool / && $0 !~ "^RRDtool " v " " { exit }
     found { print }
   ' CHANGES > releasenotes
   ```

4. `ncipollo/release-action@v1` with:
   - `tag: ${{ needs.prepare.outputs.tag }}`
   - `artifacts: "dist/*"`
   - `bodyFile: releasenotes`
   - `discussionCategory: "Release Issues"`
   - `name: "RRDtool Version ${{ needs.prepare.outputs.version }}"`

## Files added / removed / changed

| File | Action |
|---|---|
| `.github/workflows/release.yml` | **new** — the orchestrator |
| `.github/workflows/release-source.yml` | **delete** — folded into `release.yml`; the `push: tags` trigger is no longer needed because tags only come from `release.yml` itself |
| `.github/workflows/release-windows.yml` | **delete** — folded into `release.yml`; the `push: tags` trigger likewise disappears. The CI smoke build for MSVC stays in `ci-workflow.yml` |
| `conftools/bump-version.sh` | **new** — version-propagation logic extracted from `rrdtool-release` |
| `rrdtool-release` | **refactor** — call `conftools/bump-version.sh` for the propagation step; SCP-to-james and local sanity build stay intact for the maintainer's local workflow |
| `docs/superpowers/specs/2026-05-13-release-workflow-design.md` | **new** — this document |

`build-test-linux.yml`, `ci-workflow.yml`, `code-coverage.yml`, `codeql-analysis.yml` are not touched.

## Future extensions: RPM and DEB

Both fit cleanly as additional `needs: prepare` siblings of `build-source` / `build-windows`, with their artifacts joined into `create-release`'s file list. The design choice to make is **how to run them** given rrdtool's large dependency tree (tcl, lua, libdbi, pango, etc.).

Recommendation: **container-based jobs**, one matrix entry per target distro.

```yaml
build-rpm:
  needs: prepare
  runs-on: ubuntu-latest
  strategy:
    matrix:
      image: [almalinux:8, almalinux:9]
  container:
    image: ${{ matrix.image }}
  steps:
    - dnf install -y autoconf automake libtool gcc make rpm-build \
        tcl-devel lua-devel pango-devel libdbi-devel ...
    - checkout tag
    - ./bootstrap && ./configure && make dist
    - rpmbuild -ta rrdtool-X.Y.Z.tar.gz
    - upload .rpm with distro suffix

build-deb:
  needs: prepare
  runs-on: ubuntu-latest
  strategy:
    matrix:
      image: [ubuntu:22.04, ubuntu:24.04, debian:12]
  container:
    image: ${{ matrix.image }}
  steps:
    - apt install -y debhelper + the dev-dep tree
    - checkout tag
    - dpkg-buildpackage -us -uc -b
    - upload .deb with distro suffix
```

The existing `rrdtool.spec` and `debian/` directory are the seeds. The container approach handles the dependency mess because each distro's job is self-contained — no host package coordination.

If GitHub-hosted runners' `container:` proves too restrictive (older Almalinux 8 vcpkg pinning, etc.), fall back to a `runs-on: ubuntu-latest` job that drives `podman run --rm -v $PWD:/src ...` explicitly. Same shape, different driver.

This iteration does **not** implement RPM or DEB. The job graph is designed so they can be added without restructuring.

## Edge cases & risks

- **`workflow_dispatch` race with concurrent master pushes.** Between `check-ci` finishing and `prepare` pushing the release commit, someone could push to master. The release commit would still apply (it's a normal commit on top of HEAD-at-checkout), but the tag would point at a different commit than the one that passed CI. **Mitigation:** `prepare` re-checks `git rev-parse HEAD` matches the SHA `check-ci` validated; if not, abort. Cheap and removes the race.

- **Tag collision.** If `v$NEW` already exists (e.g., someone made a release out-of-band), `git tag` fails. The job aborts before pushing. Manual cleanup needed; not designed to auto-resolve.

- **`CHANGES` doesn't start with the expected master block.** The perl rewrite is structural; if the file has been reorganized, it errors out. The maintainer fixes `CHANGES` and re-dispatches.

- **The Windows MSVC build is slow** (~10–15 min). Total release time ~20–25 min including the source tarball. Acceptable for a release flow.

- **No rollback.** If `create-release` fails after `prepare` has pushed the tag, the tag stays. The maintainer deletes the tag (`git push origin :v$NEW`) and re-dispatches. The bumped commit on master stays — that's harmless; the version is what it is.

## Future cleanup (deferred)

The local `rrdtool-release` maintainer script is refactored in this iteration to source `bump-version.sh` and otherwise left intact, so the SCP-to-james pipeline keeps working during the transition. Once the GitHub Release flow is trusted, the script can shrink to just the version-propagation helper, and the SCP step either moves into a dedicated "publish to james" workflow or gets removed. Not part of this iteration.
