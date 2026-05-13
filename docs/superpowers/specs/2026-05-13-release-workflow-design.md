# Release Workflow Automation — Design

**Status:** proposed
**Date:** 2026-05-13
**Inspired by:** [byonk](https://github.com/oetiker/byonk)'s `release.yml`

## Goal

Turn rrdtool's release into a single click in the GitHub Actions "Run workflow" menu. The workflow must:

1. Refuse to run if CI is not green on `master` HEAD.
2. Compute the new version, finalize `CHANGES`, propagate version strings into all source locations, commit, and tag — all without human edits.
3. Produce the source tarball, the Windows MSVC binaries, RPM packages (AlmaLinux), and DEB packages (Ubuntu / Debian) — the latter two targeting `/opt/rrdtool` so they coexist with distribution-maintained `rrdtool` packages — all attached to a single GitHub Release with extracted release notes.

## Constraints

- **Master only.** Branches like `1.9` are no longer used. The workflow runs only when dispatched from `refs/heads/master`.
- **CI is the gate.** A release must not happen if `Linux Build` or `Windows CI` failed on the commit at master HEAD.
- **One Release, all artifacts.** Source tarball, MSVC x64/x86 zips, distro-tagged `.rpm` and `.deb` files, all attached to the same GitHub Release.
- **Binary packages run in distro containers.** rrdtool's dependency tree (cairo, pango, libdbi, etc.) is large; per-distro containers isolate it.
- **`/opt/rrdtool` install prefix.** Our packages install into `/opt/rrdtool/` and do not touch `/usr/...`. They coexist with the distribution-maintained `rrdtool` packages — users can have both installed simultaneously. Neither the RPM `Conflicts:` header nor the DEB `Conflicts:` field is set, intentionally — both packages can be installed alongside the distro version.
- **C-only build, no language bindings in packages.** Distros' rrdtool packages split bindings into language-native packages (`python3-rrdtool`, `librrds-perl`, `lua-rrd`, etc.) installed into FHS-canonical paths (`/usr/lib/python3/dist-packages/`, `@INC`). Our `/opt/rrdtool/lib/...` paths would not be on language search paths without per-user env setup, which makes shipping bindings under `/opt` more confusing than useful. The /opt build is `rrdtool`, `rrdupdate`, `rrdcgi`, `rrdcached`, `librrd.so`, headers, manpages — the C tooling, nothing else. Users wanting bindings install them from their distro or from CPAN/PyPI/gems.

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

### Shared build approach for `/opt` packages

Both RPM and DEB jobs follow the same shape, only differing in the packager invoked at the end. The shared configure invocation is:

```bash
./configure \
  --prefix=/opt/rrdtool \
  --sysconfdir=/opt/rrdtool/etc \
  --localstatedir=/opt/rrdtool/var \
  --datarootdir=/opt/rrdtool/share \
  --mandir=/opt/rrdtool/share/man \
  --disable-static \
  --disable-rpath \
  --disable-perl \
  --disable-python \
  --disable-ruby \
  --disable-lua \
  --disable-tcl \
  --with-pic
make
make install DESTDIR="$PWD/stage"
```

After `make install` the staged tree contains only `stage/opt/rrdtool/...`. We then add an `ld.so.conf.d` snippet so the runtime linker finds `librrd.so`:

```bash
mkdir -p stage/etc/ld.so.conf.d
echo "/opt/rrdtool/lib" > stage/etc/ld.so.conf.d/rrdtool-opt.conf
```

That's the only file outside `/opt/rrdtool/` we install. (Adding `/etc/profile.d/rrdtool-opt.sh` for `PATH` is tempting but invasive — users who want it can `ln -s /opt/rrdtool/bin/rrdtool /usr/local/bin/rrdtool` themselves. Skipping by default.)

### Job: `build-rpm`

Needs: `prepare`, `build-source`. Runs on `ubuntu-latest` with a distro container:

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

A new spec file `conftools/rrdtool-opt.spec` is added to the repo. It's deliberately minimal — none of the FHS gymnastics of the existing `rrdtool.spec`, no subpackage split, no PHP4. Sketch:

```spec
%global _prefix /opt/rrdtool
%global _sysconfdir /opt/rrdtool/etc
%global _localstatedir /opt/rrdtool/var
%global _datarootdir /opt/rrdtool/share
%global _mandir /opt/rrdtool/share/man

Name:     rrdtool
Version:  @VERSION@
Release:  1%{?dist}
Summary:  Round Robin Database Tool (upstream /opt build)
License:  GPL-2.0-or-later WITH FLOSS-exception-1.0
URL:      https://oss.oetiker.ch/rrdtool/
Source0:  rrdtool-%{version}.tar.gz

Prefix:   /opt/rrdtool
AutoReq:  yes

BuildRequires: gcc, make, autoconf, automake, libtool, pkgconfig
BuildRequires: groff, gettext-devel, intltool
BuildRequires: cairo-devel >= 1.2, pango-devel >= 1.14
BuildRequires: freetype-devel, libpng-devel, zlib-devel, libxml2-devel
BuildRequires: glib2-devel, libdbi-devel

%description
RRDtool is the OpenSource industry standard high performance data
logging and graphing system for time series data.

This package installs RRDtool under /opt/rrdtool so it does not
conflict with the distribution-provided rrdtool package. Add
/opt/rrdtool/bin to PATH (or symlink the binaries from /usr/local/bin)
to use it. The shared library is registered via /etc/ld.so.conf.d.

%prep
%setup -q -n rrdtool-%{version}

%build
./configure \
  --prefix=/opt/rrdtool \
  --sysconfdir=/opt/rrdtool/etc \
  --localstatedir=/opt/rrdtool/var \
  --datarootdir=/opt/rrdtool/share \
  --mandir=/opt/rrdtool/share/man \
  --disable-static \
  --disable-rpath \
  --disable-perl --disable-python --disable-ruby --disable-lua --disable-tcl \
  --with-pic
make %{?_smp_mflags}

%install
make install DESTDIR=%{buildroot}
mkdir -p %{buildroot}/etc/ld.so.conf.d
echo "/opt/rrdtool/lib" > %{buildroot}/etc/ld.so.conf.d/rrdtool-opt.conf

%post   -p /sbin/ldconfig
%postun -p /sbin/ldconfig

%files
/opt/rrdtool
/etc/ld.so.conf.d/rrdtool-opt.conf
```

`@VERSION@` is substituted at workflow time using `sed`. The spec lives in `conftools/` so `make dist` doesn't ship it inside the tarball (Fedora maintainers maintain their own spec; ours is for the /opt build only).

Steps in the job:

1. **Install build deps**:
   ```
   dnf install -y epel-release
   dnf config-manager --set-enabled crb
   dnf install -y \
     rpm-build rpmdevtools gcc make autoconf automake libtool pkgconfig \
     groff gettext gettext-devel intltool \
     cairo-devel pango-devel freetype-devel libpng-devel zlib-devel \
     libxml2-devel glib2-devel libdbi-devel
   ```
2. **Set up rpmbuild tree** (`rpmdev-setuptree`), substitute version into the spec, copy spec to `~/rpmbuild/SPECS/`, copy `source-tarball` to `~/rpmbuild/SOURCES/`.
3. **`rpmbuild -bb ~/rpmbuild/SPECS/rrdtool-opt.spec`** — builds the binary RPM(s).
4. **Collect** `.rpm` files from `~/rpmbuild/RPMS/x86_64/`. Filename has the dist tag (e.g. `rrdtool-1.9.1-1.el9.x86_64.rpm`) so multiple matrix entries don't collide.
5. **Upload** as artifact `rpm-${{ matrix.image }}` (slashes stripped).

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

The repo's `debian/` directory contains only a README — there is no in-tree Debian source packaging, and the Debian Project maintains their own `/usr`-targeted source package separately on salsa.debian.org. For our `/opt` build we use **`fpm`** (Effing Package Management), the standard tool for converting a `make install DESTDIR=...` tree into a `.deb`.

Steps:

1. **Install build deps + fpm**:
   ```
   apt-get update
   apt-get install -y \
     build-essential autoconf automake libtool pkg-config \
     gettext intltool groff dc \
     libcairo2-dev libpango1.0-dev libxml2-dev libglib2.0-dev libdbi-dev \
     libfreetype6-dev libpng-dev zlib1g-dev \
     ruby ruby-dev ruby-rubygems
   gem install --no-document fpm
   ```
   (Build-dep list mirrors Debian's working set: `libpango1.0-dev` transitively pulls cairo, freetype, glib, png.)
2. **Download `source-tarball` artifact.**
3. **Extract and build** with the shared configure invocation (above), `make`, `make install DESTDIR=$PWD/stage`, plus the `ld.so.conf.d` snippet.
4. **Run `fpm` to produce the `.deb`**:
   ```
   fpm -s dir -t deb -n rrdtool -v X.Y.Z \
       --iteration 1~${DISTRO_TAG} \
       --license "GPL-2.0-or-later WITH FLOSS-exception-1.0" \
       --maintainer "Tobias Oetiker <tobi@oetiker.ch>" \
       --vendor "oss.oetiker.ch" \
       --url "https://oss.oetiker.ch/rrdtool/" \
       --description "Round Robin Database Tool (upstream /opt build)" \
       --depends "libcairo2" --depends "libpango-1.0-0" \
       --depends "libxml2" --depends "libpng16-16" \
       --depends "libfreetype6" --depends "libdbi1" \
       --after-install /tmp/ldconfig.sh \
       --after-remove /tmp/ldconfig.sh \
       -C stage opt etc
   ```
   `DISTRO_TAG` is one of `ubuntu22.04`, `ubuntu24.04`, `debian12` (derived from `${{ matrix.image }}`).

   `/tmp/ldconfig.sh` is a one-liner created earlier in the job (`#!/bin/sh` + `/sbin/ldconfig`). It runs after install and after removal so the linker cache picks up `/opt/rrdtool/lib`.

   **Note**: this `.deb` is intentionally non-canonical (single package, doesn't match Debian's split). It's an upstream/opt package. Users wanting the FHS-compliant split layout use the Debian-maintained packages.

5. **Upload** as artifact `deb-${{ matrix.image }}` (slashes stripped). Resulting filename: `rrdtool_X.Y.Z-1~ubuntu22.04_amd64.deb`, etc.

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
| `conftools/rrdtool-opt.spec` | **new** — RPM spec for the `/opt/rrdtool` build (separate from the legacy `rrdtool.spec` which is FHS-targeted and unused by the new workflow) |
| `rrdtool-release` | **refactor** — call `conftools/bump-version.sh` for the propagation step; SCP-to-james and local sanity build stay intact for the maintainer's local workflow |
| `docs/superpowers/specs/2026-05-13-release-workflow-design.md` | **new** — this document |

`build-test-linux.yml`, `ci-workflow.yml`, `code-coverage.yml`, `codeql-analysis.yml` are not touched. The legacy `rrdtool.spec` and empty `debian/` directory are left untouched — they remain for historical reference and any downstream user who may still be consuming the old spec. They are explicitly not the basis for the new packaging.

## Edge cases & risks

- **`workflow_dispatch` race with concurrent master pushes.** Between `check-ci` finishing and `prepare` pushing the release commit, someone could push to master. The release commit would still apply (it's a normal commit on top of HEAD-at-checkout), but the tag would point at a different commit than the one that passed CI. **Mitigation:** `prepare` re-checks `git rev-parse HEAD` matches the SHA `check-ci` validated; if not, abort. Cheap and removes the race.

- **Tag collision.** If `v$NEW` already exists (e.g., someone made a release out-of-band), `git tag` fails. The job aborts before pushing. Manual cleanup needed; not designed to auto-resolve.

- **`CHANGES` doesn't start with the expected master block.** The perl rewrite is structural; if the file has been reorganized, it errors out. The maintainer fixes `CHANGES` and re-dispatches.

- **Pipeline duration.** Windows MSVC build is ~10–15 min, RPM and DEB matrices run in parallel. Total release time ~15–20 min. Acceptable.

- **The new `rrdtool-opt.spec` is minimal but untested in production.** First-run failures will surface real issues (missing BuildRequires, configure flag typos, RPM macro quirks). `continue-on-error: true` on `build-rpm` means these don't block the release. Same applies to `build-deb` (configure on a fresh Ubuntu/Debian container may surface a missing dep we didn't anticipate).

- **`/opt`-install packages are non-canonical by design.** They're a single combined package, don't follow FHS, don't conflict with the distribution rrdtool. Distro-package users won't find them via `apt show rrdtool` or `dnf info rrdtool` because they're not the same package — different upstream channel. Documenting this in the GitHub Release description is worthwhile (future work, low priority).

- **No language bindings in `/opt` packages.** Users wanting Perl/Python/Tcl/Lua/Ruby bindings install them from their distro packages or from CPAN/PyPI/gems. Those bindings link against the distro's `librrd`, not ours — which is fine because the C library ABI is stable across these point versions. If someone needs upstream bindings against the upstream library, they build from source. Adding binding packages later is a feasible extension but explicitly out of scope here.

- **No rollback.** If `create-release` fails after `prepare` has pushed the tag, the tag stays. The maintainer deletes the tag (`git push origin :v$NEW`) and re-dispatches. The bumped commit on master stays — that's harmless; the version is what it is.

## Future cleanup (deferred)

The local `rrdtool-release` maintainer script is refactored in this iteration to source `bump-version.sh` and otherwise left intact, so the SCP-to-james pipeline keeps working during the transition. Once the GitHub Release flow is trusted, the script can shrink to just the version-propagation helper, and the SCP step either moves into a dedicated "publish to james" workflow or gets removed. Not part of this iteration.
