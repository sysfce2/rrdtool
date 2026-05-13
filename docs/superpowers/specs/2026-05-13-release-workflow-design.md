# Release Workflow Automation — Design

**Status:** proposed
**Date:** 2026-05-13
**Inspired by:** [byonk](https://github.com/oetiker/byonk)'s `release.yml`

## Goal

Turn rrdtool's release into a single click in the GitHub Actions "Run workflow" menu. The workflow must:

1. Refuse to run if CI is not green on `master` HEAD.
2. Compute the new version, finalize `CHANGES`, propagate version strings into all source locations, commit, and tag — all without human edits.
3. Produce the source tarball, the Windows MSVC binaries, RPM packages (AlmaLinux), and DEB packages (Ubuntu / Debian), all attached to a single GitHub Release with extracted release notes.

## Constraints

- **Master only.** Branches like `1.9` are no longer used. The workflow runs only when dispatched from `refs/heads/master`.
- **CI is the gate.** A release must not happen if `Linux Build` or `Windows CI` failed on the commit at master HEAD.
- **One Release, all artifacts.** Source tarball, MSVC x64/x86 zips, distro-tagged `.rpm` and `.deb` files, all attached to the same GitHub Release.
- **Binary packages run in distro containers.** rrdtool's dependency tree (cairo, pango, libdbi, lua, tcl, ruby, perl, python, etc.) is too large to install on the host runner cleanly; per-distro containers isolate it.

## Non-goals

- MSYS2 release artifacts (MSYS2 stays in CI as a smoke test only).
- Source packages (`*.src.rpm`, `*.dsc`/`*.tar.xz`). Only binary `.rpm` and `.deb` are produced. The source tarball is the canonical source distribution.
- Changes to `build-test-linux.yml`, `ci-workflow.yml`, `code-coverage.yml`, `codeql-analysis.yml`. These remain push/PR-triggered.

## Workflow shape

One new file, `.github/workflows/release.yml`. Job graph:

```
check-ci ──► prepare ──► build-source ──┐
                    ├──► build-windows ─┤
                    ├──► build-rpm     ─┤
                    └──► build-deb     ─┴──► create-release
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

   Implementation: a single perl `-0777` script that captures the master block's contents, writes the empty master block first, then the renamed version block with the captured contents. Small enough to inline in the workflow.

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

### Job: `build-rpm`

Needs: `prepare`, `build-source` (consumes the source tarball). Runs on `ubuntu-latest` with a distro container:

```yaml
build-rpm:
  needs: [prepare, build-source]
  runs-on: ubuntu-latest
  continue-on-error: true
  strategy:
    fail-fast: false
    matrix:
      image: [almalinux:9]   # add almalinux:8 / fedora:latest later if needed
  container:
    image: ${{ matrix.image }}
```

The existing `rrdtool.spec` is the seed. `rpmbuild -ta` extracts the source tarball, runs `%prep`, `%build`, `%install`, and produces a stack of binary RPMs (one per subpackage: main, devel, doc, perl, python, tcl, lua, ruby, cached).

Steps:

1. Install build dependencies via `dnf`:
   ```
   dnf install -y epel-release
   dnf install -y --enablerepo=crb \
     gcc gcc-c++ make autoconf automake libtool rpm-build groff \
     gettext gettext-devel intltool \
     openssl-devel freetype-devel libpng-devel zlib-devel \
     cairo-devel pango-devel libxml2-devel glib2-devel libdbi-devel \
     perl-devel perl-ExtUtils-MakeMaker \
     python3-devel tcl-devel lua-devel ruby ruby-devel
   ```
   (`epel-release` and `--enablerepo=crb` give us `libdbi-devel` on Alma 9 — it's in CRB.)
2. Download the `source-tarball` artifact.
3. Move it into `~/rpmbuild/SOURCES/`.
4. `rpmbuild --nodeps -ta --without php rrdtool-X.Y.Z.tar.gz`
   - `--without php` skips the obsolete PHP4 bindings the spec still references.
   - `--nodeps` is included because some `Requires:` (e.g. `dejavu-lgc-fonts`) may not be installable at build time; it's a build-time skip only.
5. Collect resulting `.rpm` files (excluding `.src.rpm`) from `~/rpmbuild/RPMS/<arch>/`. The dist tag from rpmbuild (`.el9`, `.fc40`, etc.) already disambiguates filenames across distros.
6. Upload as artifact `rpm-${{ matrix.image }}` (slashes stripped to e.g. `rpm-almalinux-9`).

### Job: `build-deb`

Needs: `prepare`, `build-source`. Runs on `ubuntu-latest` with a distro container:

```yaml
build-deb:
  needs: [prepare, build-source]
  runs-on: ubuntu-latest
  continue-on-error: true
  strategy:
    fail-fast: false
    matrix:
      image: [ubuntu:22.04, ubuntu:24.04, debian:12]
  container:
    image: ${{ matrix.image }}
```

The repo's `debian/` directory contains only a README — there is **no** Debian source packaging in-tree. So `dpkg-buildpackage` is not viable without significant new work. Instead we use **`fpm`** (Effing Package Management), the standard tool for converting a `make install DESTDIR=...` tree into a `.deb`. This produces a single-package `.deb` containing the binaries, libraries, headers, man pages, and language bindings together — without the subpackage split the RPM spec provides. That's acceptable for an upstream-provided package; downstream Debian maintainers maintain their own properly-split packaging.

Steps:

1. Install build deps + fpm:
   ```
   apt-get update
   apt-get install -y build-essential autoconf automake libtool pkg-config \
     gettext intltool groff \
     libcairo2-dev libpango1.0-dev libxml2-dev libglib2.0-dev libdbi-dev \
     libfreetype6-dev libpng-dev zlib1g-dev \
     libperl-dev python3-dev tcl-dev liblua5.1-0-dev ruby ruby-dev \
     ruby-rubygems
   gem install --no-document fpm
   ```
2. Download `source-tarball` artifact.
3. Extract, `./configure --prefix=/usr --sysconfdir=/etc --localstatedir=/var --disable-static --with-pic`, `make`, `make install DESTDIR=$PWD/stage`.
4. Run `fpm` to produce the `.deb`:
   ```
   fpm -s dir -t deb -n rrdtool -v X.Y.Z \
       --iteration 1~${DISTRO_TAG} \
       --license "GPL-2.0-or-later with exceptions" \
       --maintainer "Tobias Oetiker <tobi@oetiker.ch>" \
       --vendor "oss.oetiker.ch" \
       --url "https://oss.oetiker.ch/rrdtool/" \
       --description "Round Robin Database Tool" \
       --depends "libcairo2" --depends "libpango-1.0-0" \
       --depends "libxml2" --depends "libpng16-16" \
       --depends "libfreetype6" --depends "libdbi1" \
       -C stage usr
   ```
   `DISTRO_TAG` is one of `ubuntu22.04`, `ubuntu24.04`, `debian12`, computed from `${{ matrix.image }}` so the iteration suffix marks which distro built it.
5. Upload as artifact `deb-${{ matrix.image }}` (slashes stripped). Resulting filename: `rrdtool_X.Y.Z-1~ubuntu22.04_amd64.deb` etc.

### Job: `create-release`

Needs: `prepare`, `build-source`, `build-windows`, `build-rpm`, `build-deb`. Runs on `ubuntu-latest`. Permissions: `contents: write`.

Since `build-rpm` and `build-deb` use `continue-on-error: true` (see "Failure-mode policy" below), this job runs even if one of those matrix entries failed. `if: always() && needs.build-source.result == 'success' && needs.build-windows.result == 'success'` enforces that the source and Windows builds must succeed.

1. Checkout the tag (sparse, just `CHANGES`).
2. `actions/download-artifact@v6` with `pattern: '*'`, `merge-multiple: true`, into `dist/`. Collects `rrdtool-X.Y.Z.tar.gz`, the Windows zips, all successful `.rpm` files, and all successful `.deb` files.
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

### Failure-mode policy for binary packages

`build-rpm` and `build-deb` use **`continue-on-error: true`** at the job level, plus `fail-fast: false` in their matrices. Rationale: the source tarball is the canonical release; an outdated `rrdtool.spec`, missing apt mirror, or single-distro container hiccup should not prevent a release that the maintainer has explicitly green-lit. When an `.rpm` or `.deb` job fails, the Release still publishes with whatever binary packages succeeded plus the source tarball and Windows artifacts. The failed job is visible in the workflow run, giving a clean signal for follow-up cleanup without blocking the release.

`build-source` and `build-windows` do **not** get `continue-on-error` — those are the established artifacts users depend on. Their failure aborts the release.

## Files added / removed / changed

| File | Action |
|---|---|
| `.github/workflows/release.yml` | **new** — the orchestrator with six jobs |
| `.github/workflows/release-source.yml` | **delete** — folded into `release.yml`; the `push: tags` trigger is no longer needed because tags only come from `release.yml` itself |
| `.github/workflows/release-windows.yml` | **delete** — folded into `release.yml`; the `push: tags` trigger likewise disappears. The CI smoke build for MSVC stays in `ci-workflow.yml` |
| `conftools/bump-version.sh` | **new** — version-propagation logic extracted from `rrdtool-release` |
| `rrdtool-release` | **refactor** — call `conftools/bump-version.sh` for the propagation step; SCP-to-james and local sanity build stay intact for the maintainer's local workflow |
| `docs/superpowers/specs/2026-05-13-release-workflow-design.md` | **new** — this document |

`build-test-linux.yml`, `ci-workflow.yml`, `code-coverage.yml`, `codeql-analysis.yml` are not touched. `rrdtool.spec` and `debian/` are not touched in this iteration (the spec is dated and may need fixes that surface from the first `build-rpm` run, but those can come as follow-ups).

## Edge cases & risks

- **`workflow_dispatch` race with concurrent master pushes.** Between `check-ci` finishing and `prepare` pushing the release commit, someone could push to master. The release commit would still apply (it's a normal commit on top of HEAD-at-checkout), but the tag would point at a different commit than the one that passed CI. **Mitigation:** `prepare` re-checks `git rev-parse HEAD` matches the SHA `check-ci` validated; if not, abort. Cheap and removes the race.

- **Tag collision.** If `v$NEW` already exists (e.g., someone made a release out-of-band), `git tag` fails. The job aborts before pushing. Manual cleanup needed; not designed to auto-resolve.

- **`CHANGES` doesn't start with the expected master block.** The perl rewrite is structural; if the file has been reorganized, it errors out. The maintainer fixes `CHANGES` and re-dispatches.

- **Pipeline duration.** Windows MSVC build is ~10–15 min, RPM and DEB matrices run in parallel. Total release time ~15–20 min. Acceptable.

- **`rrdtool.spec` is dated.** It hasn't been touched recently and may produce build warnings or fail outright on AlmaLinux 9. `continue-on-error: true` on `build-rpm` means a failure here doesn't block the release; the issue gets surfaced for follow-up. Same applies to `build-deb`.

- **`fpm`-built `.deb` is non-canonical.** It's a single combined package, not the split-package layout Debian users expect from `apt`. This is upstream's package, not Debian's. Anyone wanting a "proper" Debian package uses the Debian-maintained archive. Documenting this in the GitHub Release description is worthwhile (future work, low priority).

- **No rollback.** If `create-release` fails after `prepare` has pushed the tag, the tag stays. The maintainer deletes the tag (`git push origin :v$NEW`) and re-dispatches. The bumped commit on master stays — that's harmless; the version is what it is.

## Future cleanup (deferred)

The local `rrdtool-release` maintainer script is refactored in this iteration to source `bump-version.sh` and otherwise left intact, so the SCP-to-james pipeline keeps working during the transition. Once the GitHub Release flow is trusted, the script can shrink to just the version-propagation helper, and the SCP step either moves into a dedicated "publish to james" workflow or gets removed. Not part of this iteration.
