# Release Workflow Automation — Design

**Status:** proposed
**Date:** 2026-05-13
**Inspired by:** [byonk](https://github.com/oetiker/byonk)'s `release.yml`

## Goal

Turn rrdtool's release into a single click in the GitHub Actions "Run workflow" menu. The workflow must:

1. Refuse to run if CI is not green on `master` HEAD.
2. Compute the new version, finalize `CHANGES`, propagate version strings into all source locations, commit, and tag — all without human edits.
3. Produce the source tarball, the Windows MSVC binaries, RPM packages (AlmaLinux), and DEB packages (Ubuntu / Debian) — the latter two installing into `/opt/rrdtool` (binaries, library, and Perl/Python/Tcl/Lua/Ruby bindings, all rooted under that prefix) so they coexist with distribution-maintained `rrdtool` packages without touching the system. All artifacts attach to a single GitHub Release with extracted release notes.

## Constraints

- **Master only.** Branches like `1.9` are no longer used. The workflow runs only when dispatched from `refs/heads/master`.
- **CI is the gate.** A release must not happen if `Linux Build` or `Windows CI` failed on the commit at master HEAD.
- **One Release, all artifacts.** Source tarball, MSVC x64/x86 zips, distro-tagged `.rpm` and `.deb` files, all attached to the same GitHub Release.
- **Binary packages run in distro containers.** rrdtool's dependency tree (cairo, pango, libdbi, etc.) is large; per-distro containers isolate it.
- **`/opt/rrdtool` install prefix, nothing outside.** Our packages install entirely under `/opt/rrdtool/` — no `/etc/ld.so.conf.d/` entries, no `/etc/profile.d/`, no `/usr/...`. They coexist with the distribution-maintained `rrdtool` packages — users can have both installed simultaneously. Neither the RPM `Conflicts:` header nor the DEB `Conflicts:` field is set, intentionally.
- **Bindings included, installed under `/opt`.** Perl, Python, Tcl, Lua, and Ruby bindings are built and installed under `/opt/rrdtool/lib/<lang>/...` — rrdtool's `configure` was designed for exactly this. By **not** passing `--enable-perl-site-install`, `--enable-ruby-site-install`, `--enable-lua-site-install`, or `--enable-tcl-site`, the bindings land in `$prefix/lib/perl`, `$prefix/lib/ruby`, `$prefix/lib/lua/$lua_version`, etc. — never in the system's `@INC`, `sys.path`, or equivalents. The distribution's bindings are untouched.
- **`librrd.so` discoverability without `ld.so.conf`.** rrdtool's own binaries (`rrdtool`, `rrdupdate`, `rrdcgi`, `rrdcached`) get `RPATH=/opt/rrdtool/lib` baked in by libtool during the build (we do **not** pass `--disable-rpath`). The library knows where to find itself. For third-party consumers, the installed `librrd.pc` is post-processed to add `-Wl,-rpath,${libdir}` to its `Libs:` line — anyone compiling against `/opt/rrdtool` via `pkg-config` gets the rpath embedded in their binary automatically. No system-wide linker config needed.

## Non-goals

- MSYS2 release artifacts (MSYS2 stays in CI as a smoke test only).
- Source packages (`*.src.rpm`, `*.dsc`/`*.tar.xz`). Only binary `.rpm` and `.deb` are produced. The source tarball is the canonical source distribution.
- Changes to `build-test-linux.yml`, `ci-workflow.yml`, `code-coverage.yml`, `codeql-analysis.yml`. These remain push/PR-triggered.

## Workflow shape

One new file, `.github/workflows/release.yml`. Job graph:

```
                    ┌─► build-source  ─┐
                    ├─► build-windows ─┤
check-ci ──► compute-version ─┤                  ├─► publish
                    ├─► build-rpm     ─┤
                    └─► build-deb     ─┘
```

Every build job runs on its own GitHub Actions runner with its own checkout of the rrdtool-1.x repo. Each one independently runs `conftools/bump-version.sh "$NEW"` and the `CHANGES` rewrite against its working tree before building — these are idempotent, deterministic given the same input version, so all jobs end up with byte-identical bumped trees. No artifact-passing between build jobs.

**The tag is created and pushed ONLY by the `publish` job, after every build has succeeded.** No `continue-on-error` anywhere. If any build fails, the workflow aborts and no release exists, no tag was pushed — the maintainer fixes the issue and re-dispatches; nothing to clean up.

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

### Job: `compute-version`

Needs: `check-ci`. Runs on `ubuntu-latest`. Read-only — does not modify any files or push anything. Just produces the new version string for downstream jobs.

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

Outputs: `version` (e.g. `1.9.1`), `tag` (e.g. `v1.9.1`), `date` (`YYYY-MM-DD`, captured here so all jobs use the same date even if they run across midnight).

### Shared bump step (used by every build job)

Each build job, immediately after checkout, runs the same bump-in-place block before building:

```bash
echo "$NEW" > VERSION
./conftools/bump-version.sh "$NEW"
# Rewrite CHANGES: rename leading master block to versioned, prepend
# fresh empty master placeholder. Inlined perl script omitted here for
# brevity — see "Finalize CHANGES" below.
```

Nothing is committed here; the modifications live only in the runner's working tree, get baked into whatever artifact the job produces, and are discarded when the runner is torn down. The actual commit-and-push happens once at the end, in `publish`.

### Job: `build-source`

Needs: `compute-version`. Runs on `ubuntu-latest`. Produces the canonical `rrdtool-X.Y.Z.tar.gz` release artifact.

Steps:

1. **Checkout** master (the same SHA `check-ci` validated).
2. **Install build deps**: `autopoint build-essential gettext libpango1.0-dev ghostscript`.
3. **Apply the version bump in-place** (not committed):
   - Write `VERSION` with the new value.
   - Run `conftools/bump-version.sh "$NEW"` — propagates version into `bindings/perl-*/*.pm`, `src/*.h`, `src/*.c`, `rrdtool.spec`, `doc/rrdbuild.pod`, `win32/*.rc`, `win32/rrd_config.h`. (Script is idempotent — running it twice with the same version is a no-op the second time.)
   - **Finalize `CHANGES`**: rewrite the leading block
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
     A single perl `-0777` script captures the master block's contents, writes the empty master placeholder first, then the renamed version block. Small enough to inline in the workflow.

4. **Build the tarball**: `./bootstrap && ./configure && make dist` — produces `rrdtool-X.Y.Z.tar.gz` containing the bumped sources.
5. **Upload** `rrdtool-X.Y.Z.tar.gz` as a workflow artifact named `source-tarball`.

The "re-extract and rebuild from tarball" sanity check that `build-test-linux.yml` already performs on every push to master is not duplicated here — the CI gate guarantees it passed at master HEAD, and the version-string-only bump cannot break the build.

### Job: `build-windows`

Needs: `compute-version`. Runs on `windows-2022` with the same matrix as today's `release-windows.yml`:

```yaml
matrix:
  vcpkg_triplet: [x64-windows, x86-windows]
```

Steps:

1. **Checkout** master.
2. **Apply the shared bump step** (run `bump-version.sh` via the perl that already runs on Windows MSYS — or rewrite the script in pure perl). The MSVC build path then sees the updated `win32/rrd_config.h` etc.
3. **`vcpkg build`** (johnwason/vcpkg-action@v7) with the existing `vcpkgCommitId` `84bab45d415d22042bd0b9081aea57f362da3f35`.
4. **`nmake -f win32\Makefile_vcpkg.msc`** with the matrix configuration.
5. **`win32\collect_rrdtool_vcpkg_files.bat ${{ matrix.configuration }}`**.
6. **New**: zip the collected `rrdtool-X.Y.Z-${{ matrix.configuration }}_vcpkg/` directory into `rrdtool-X.Y.Z-${{ matrix.configuration }}_vcpkg.zip` (today the workflow uploads the directory as a tree, which isn't a useful release artifact).
7. Upload the zip as a workflow artifact named `windows-${{ matrix.configuration }}`.

`bump-version.sh` is shell+perl. The GitHub-hosted `windows-2022` runners ship Git Bash + perl, so a `bash conftools/bump-version.sh "$NEW"` step works from PowerShell or cmd by invoking bash. If that proves fragile, the script's perl substitutions get reimplemented in a `.pl` file callable directly — same logic, fewer shell layers.

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
  --with-pic
make
make install DESTDIR="$PWD/stage"
```

Critical defaults (chosen by **not** passing flags):

| Flag we deliberately omit | Effect |
|---|---|
| `--enable-perl-site-install` | Perl modules go to `$prefix/lib/perl`, **not** the system `@INC` |
| `--enable-ruby-site-install` | Ruby modules go to `$prefix/lib/ruby`, **not** the system gem path |
| `--enable-lua-site-install` | Lua modules go to `$prefix/lib/lua/$lua_version`, **not** the system Lua paths |
| `--enable-tcl-site` | Tcl bindings install under `$prefix`, **not** in the Tcl auto-load tree |
| `--disable-rpath` | libtool bakes `RPATH=/opt/rrdtool/lib` into our binaries, so they find `librrd.so` without any system linker config |

For Python: `AM_PATH_PYTHON` honours `--prefix`, so the module lands at `/opt/rrdtool/lib/python3.X/site-packages/rrdtool.so` (or similar; the exact subpath includes the Python version found by configure).

After `make install` the staged tree is entirely under `stage/opt/rrdtool/`. **Two post-install touches:**

1. **Add `-Wl,-rpath,${libdir}` to the installed `librrd.pc`** so consumers' binaries link with the rpath baked in:

   ```bash
   sed -i 's|^Libs: -L\${libdir} -lrrd$|Libs: -L${libdir} -lrrd -Wl,-rpath,${libdir}|' \
     stage/opt/rrdtool/lib/pkgconfig/librrd.pc
   ```

   This is intentionally only done in the `/opt`-packaged build — the upstream `src/librrd.pc.in` stays unchanged so FHS-canonical builds (the existing Debian/Fedora packaging) aren't affected.

2. **Install a sourceable environment-setup helper** at `stage/opt/rrdtool/bin/rrdtool-env.sh`:

   ```sh
   #!/bin/sh
   # Source me to use /opt/rrdtool from your shell:
   #   . /opt/rrdtool/bin/rrdtool-env.sh
   ROOT=/opt/rrdtool
   export PATH="$ROOT/bin${PATH:+:$PATH}"
   export MANPATH="$ROOT/share/man${MANPATH:+:$MANPATH}"
   export PKG_CONFIG_PATH="$ROOT/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
   export PERL5LIB="$ROOT/lib/perl${PERL5LIB:+:$PERL5LIB}"
   PY_SP=$(ls -d "$ROOT"/lib/python*/site-packages 2>/dev/null | head -1)
   [ -n "$PY_SP" ] && export PYTHONPATH="$PY_SP${PYTHONPATH:+:$PYTHONPATH}"
   RB_ARCH=$(ls -d "$ROOT"/lib/ruby/*-* 2>/dev/null | head -1)
   export RUBYLIB="$ROOT/lib/ruby${RB_ARCH:+:$RB_ARCH}${RUBYLIB:+:$RUBYLIB}"
   LUA_VDIR=$(ls -d "$ROOT"/lib/lua/5.* 2>/dev/null | head -1)
   [ -n "$LUA_VDIR" ] && export LUA_CPATH="$LUA_VDIR/?.so;${LUA_CPATH:-;;}"
   export TCLLIBPATH="$ROOT/lib${TCLLIBPATH:+ $TCLLIBPATH}"
   ```

   Users opt in with `. /opt/rrdtool/bin/rrdtool-env.sh` (or add it to `~/.bashrc`). One file, no system mutation.

**Documentation in the package description** explains the usage pattern: source the env script, or set `PKG_CONFIG_PATH` directly and compile with rpath baked in via `pkg-config --libs librrd`. The GitHub Release body gets a short "Using the /opt packages" section too.

### Job: `build-rpm`

Needs: `build-source`. Runs on `ubuntu-latest` with a distro container:

```yaml
build-rpm:
  needs: build-source
  runs-on: ubuntu-latest
  strategy:
    fail-fast: true
    matrix:
      image: [almalinux:9]   # add almalinux:8 / fedora:latest later if needed
  container:
    image: ${{ matrix.image }}
```

A new spec file `conftools/rrdtool-opt.spec` is added to the repo. It's deliberately minimal — no FHS gymnastics, no subpackage split, no PHP4. Sketch:

```spec
Name:     rrdtool
Version:  @VERSION@
Release:  1%{?dist}
Summary:  Round Robin Database Tool (upstream /opt build)
License:  GPL-2.0-or-later WITH FLOSS-exception-1.0
URL:      https://oss.oetiker.ch/rrdtool/
Source0:  rrdtool-%{version}.tar.gz

Prefix:   /opt/rrdtool
AutoReqProv: no

BuildRequires: gcc, make, autoconf, automake, libtool, pkgconfig
BuildRequires: groff, gettext-devel, intltool
BuildRequires: cairo-devel >= 1.2, pango-devel >= 1.14
BuildRequires: freetype-devel, libpng-devel, zlib-devel, libxml2-devel
BuildRequires: glib2-devel, libdbi-devel
# binding build-deps
BuildRequires: perl-devel, perl-ExtUtils-MakeMaker
BuildRequires: python3-devel
BuildRequires: tcl-devel
BuildRequires: lua-devel
BuildRequires: ruby, ruby-devel

%description
RRDtool is the OpenSource industry standard high performance data
logging and graphing system for time series data.

This package installs RRDtool entirely under /opt/rrdtool so it does
not conflict with the distribution-provided rrdtool package. Source
/opt/rrdtool/bin/rrdtool-env.sh in your shell to put it on PATH and
make its language bindings (Perl, Python, Tcl, Lua, Ruby) discoverable.

For C/C++ consumers, set PKG_CONFIG_PATH=/opt/rrdtool/lib/pkgconfig
and compile with `pkg-config --cflags --libs librrd`; the resulting
binary has /opt/rrdtool/lib baked in via -Wl,-rpath.

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
  --with-pic
make %{?_smp_mflags}

%install
make install DESTDIR=%{buildroot}
# add rpath to consumer pkg-config args
sed -i 's|^Libs: -L\${libdir} -lrrd$|Libs: -L${libdir} -lrrd -Wl,-rpath,${libdir}|' \
  %{buildroot}/opt/rrdtool/lib/pkgconfig/librrd.pc
# install env-setup helper (content created by the workflow before rpmbuild)
install -m 0755 %{_sourcedir}/rrdtool-env.sh \
  %{buildroot}/opt/rrdtool/bin/rrdtool-env.sh

%files
/opt/rrdtool
```

`@VERSION@` is substituted at workflow time using `sed`. `AutoReqProv: no` is important — without it, rpmbuild would scan our binaries' RPATH and emit dependencies like `librrd.so.X()(64bit)` which only the /opt-installed librrd can satisfy, breaking install on hosts that have the distro rrdtool installed. We explicitly list runtime dependencies on the system libraries we link against (cairo, pango, libxml2, libpng, freetype, libdbi, zlib) via `Requires:` lines (omitted from the sketch for brevity; included in the actual spec).

The spec lives in `conftools/` so `make dist` doesn't ship it inside the tarball.

Steps in the job:

1. **Install build deps**:
   ```
   dnf install -y epel-release
   dnf config-manager --set-enabled crb
   dnf install -y \
     rpm-build rpmdevtools gcc make autoconf automake libtool pkgconfig \
     groff gettext gettext-devel intltool \
     cairo-devel pango-devel freetype-devel libpng-devel zlib-devel \
     libxml2-devel glib2-devel libdbi-devel \
     perl-devel perl-ExtUtils-MakeMaker \
     python3-devel \
     tcl-devel \
     lua-devel \
     ruby ruby-devel
   ```
2. **Checkout** master and apply the shared bump step.
3. **Make the source tarball locally** (`./bootstrap && ./configure && make dist`) — `rpmbuild -ba` needs a tarball as input. Costs ~30s; cheaper than artifact-passing complexity.
4. **Set up rpmbuild tree** (`rpmdev-setuptree`), render the env-helper template into `~/rpmbuild/SOURCES/rrdtool-env.sh`, substitute `@VERSION@` in `conftools/rrdtool-opt.spec` and copy to `~/rpmbuild/SPECS/`, move `rrdtool-X.Y.Z.tar.gz` to `~/rpmbuild/SOURCES/`.
5. **`rpmbuild -ba ~/rpmbuild/SPECS/rrdtool-opt.spec`** — builds the binary RPM.
6. **Collect** the `.rpm` from `~/rpmbuild/RPMS/x86_64/`. Filename has the dist tag (e.g. `rrdtool-1.9.1-1.el9.x86_64.rpm`) so multiple matrix entries don't collide.
7. **Upload** as artifact `rpm-${{ matrix.image }}` (slashes stripped).

### Job: `build-deb`

Needs: `build-source`. Runs on `ubuntu-latest` with a distro container:

```yaml
build-deb:
  needs: build-source
  runs-on: ubuntu-latest
  strategy:
    fail-fast: true
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
     libperl-dev \
     python3-dev python3-setuptools \
     tcl-dev \
     liblua5.1-0-dev \
     ruby ruby-dev ruby-rubygems
   gem install --no-document fpm
   ```
   (Build-dep list mirrors Debian's working set: `libpango1.0-dev` transitively pulls cairo, freetype, glib, png. Adding language `-dev` packages enables binding builds.)
2. **Checkout** master and apply the shared bump step.
3. **`./bootstrap`**, then **shared configure invocation** (above), `make`, `make install DESTDIR=$PWD/stage`, plus the two post-install touches (rpath rewrite in `librrd.pc`, render `rrdtool-env.sh` into `stage/opt/rrdtool/bin/`).
4. **Run `fpm` to produce the `.deb`**:
   ```
   fpm -s dir -t deb -n rrdtool -v X.Y.Z \
       --iteration 1~${DISTRO_TAG} \
       --license "GPL-2.0-or-later WITH FLOSS-exception-1.0" \
       --maintainer "Tobias Oetiker <tobi@oetiker.ch>" \
       --vendor "oss.oetiker.ch" \
       --url "https://oss.oetiker.ch/rrdtool/" \
       --description "Round Robin Database Tool (upstream /opt build). \
Source /opt/rrdtool/bin/rrdtool-env.sh to use." \
       --depends "libcairo2" --depends "libpango-1.0-0" \
       --depends "libxml2" --depends "libpng16-16" \
       --depends "libfreetype6" --depends "libdbi1" --depends "zlib1g" \
       --deb-no-default-config-files \
       -C stage opt
   ```
   - `DISTRO_TAG` is one of `ubuntu22.04`, `ubuntu24.04`, `debian12` (derived from `${{ matrix.image }}`).
   - `-C stage opt` packages only the `opt/` subtree — no system files.
   - **No `--after-install` ldconfig hook** — `librrd.so` is found via the binaries' baked-in RPATH and via `librrd.pc`'s rpath args for consumers. ldconfig is not needed.
   - **Dependencies on language bindings are intentionally omitted from the package's `Depends:`.** A user who installs the `.deb` gets `rrdtool` and the C library; the bindings are present on disk but only loaded by a Perl/Python/etc. interpreter that has been pointed at `/opt/rrdtool/lib/<lang>` (via `rrdtool-env.sh` or manually). This is intentional: it means the package installs on a host without Perl/Ruby/Tcl/Lua installed.

   **Note**: this `.deb` is intentionally non-canonical (single package, `/opt`-rooted, no subpackage split). It's an upstream package, not Debian's. Users wanting the FHS-compliant split layout use the Debian-maintained packages from `apt`.

5. **Upload** as artifact `deb-${{ matrix.image }}` (slashes stripped). Resulting filename: `rrdtool_X.Y.Z-1~ubuntu22.04_amd64.deb`, etc.

### Job: `publish`

Needs: `compute-version`, `build-source`, `build-windows`, `build-rpm`, `build-deb`. Runs on `ubuntu-latest`. Permissions: `contents: write`.

This is the **only** job that mutates the repo. It runs only after every preceding job has succeeded — including every matrix entry of `build-windows`, `build-rpm`, and `build-deb`. There is no `continue-on-error` anywhere and no `if: always()`. If a single matrix entry fails, `publish` doesn't run, no tag is pushed, no Release is created.

Steps:

1. **Checkout master** with full history.
2. **Race check**: `git fetch && git rev-parse origin/master` — if it differs from `github.sha` (the SHA that `check-ci` validated and the build jobs derived from), abort. Someone pushed to master during the release; the maintainer reviews and re-dispatches.
3. **Re-apply the version bump** that `build-source` applied to its own workspace:
   - Write `VERSION` with the new value.
   - Run `conftools/bump-version.sh "$NEW"`.
   - Apply the `CHANGES` rewrite (same perl block as `build-source`).
   This is idempotent — produces the same files `build-source` produced, so the committed tree exactly matches what's in the released tarball.
4. **Commit, tag, push**:
   ```bash
   git config user.name "github-actions[bot]"
   git config user.email "github-actions[bot]@users.noreply.github.com"
   git add -u
   git commit -m "release v$NEW"
   git tag -a "v$NEW" -m "release v$NEW"
   git push origin master --follow-tags
   ```
5. **Download all artifacts** with `actions/download-artifact@v6`, `pattern: '*'`, `merge-multiple: true`, into `dist/`. Collects `rrdtool-X.Y.Z.tar.gz`, the Windows zips, every `.rpm`, every `.deb`.
6. **Extract release notes** from `CHANGES` keyed on the version:
   ```bash
   awk -v v="$VERSION" '
     $0 ~ "^RRDtool " v " " { found=1 }
     found && /^RRDtool / && $0 !~ "^RRDtool " v " " { exit }
     found { print }
   ' CHANGES > releasenotes
   ```
7. **Create GitHub Release** with `ncipollo/release-action@v1`:
   - `tag: v${{ needs.compute-version.outputs.version }}`
   - `artifacts: "dist/*"`
   - `bodyFile: releasenotes`
   - `discussionCategory: "Release Issues"`
   - `name: "RRDtool Version ${{ needs.compute-version.outputs.version }}"`

### Failure modes

| What fails | What state is left | Recovery |
|---|---|---|
| `check-ci` (CI not green on master HEAD) | None — nothing started | Maintainer fixes CI, re-dispatches release workflow |
| `compute-version` | None — read-only job | Inspect log, fix, re-dispatch |
| `build-source` | None — work in workflow runner only | Inspect log, fix, re-dispatch |
| Any `build-windows` matrix entry | None — artifacts uploaded but not consumed | Inspect log, fix, re-dispatch |
| Any `build-rpm` / `build-deb` matrix entry | None — same as above | Inspect log, fix, re-dispatch |
| `publish` step 4 (git push) | None — no tag, no commit pushed | Re-dispatch |
| `publish` step 7 (create release) | Tag pushed, no Release created | Re-dispatch; `ncipollo/release-action` is idempotent on existing tags and will create the missing Release. If preferred: delete the tag (`git push origin :v$NEW`) and re-dispatch from scratch. |

The race-window where things can go wrong is small: only between `git push` (step 4) and `create release` (step 7) within the same job, on the same runner. The release-action's idempotence on tag re-use makes step 7 safe to re-run.

## Files added / removed / changed

| File | Action |
|---|---|
| `.github/workflows/release.yml` | **new** — the orchestrator with six jobs |
| `.github/workflows/release-source.yml` | **delete** — folded into `release.yml`; the `push: tags` trigger is no longer needed because tags only come from `release.yml` itself |
| `.github/workflows/release-windows.yml` | **delete** — folded into `release.yml`; the `push: tags` trigger likewise disappears. The CI smoke build for MSVC stays in `ci-workflow.yml` |
| `conftools/bump-version.sh` | **new** — version-propagation logic extracted from `rrdtool-release` |
| `conftools/rrdtool-opt.spec` | **new** — RPM spec for the `/opt/rrdtool` build (separate from the legacy `rrdtool.spec` which is FHS-targeted and unused by the new workflow) |
| `conftools/rrdtool-env.sh.in` | **new** — sourceable environment-setup helper template (rendered to `/opt/rrdtool/bin/rrdtool-env.sh` at install time; used by both the RPM `%install` step and the DEB build's staging step) |
| `rrdtool-release` | **refactor** — call `conftools/bump-version.sh` for the propagation step; SCP-to-james and local sanity build stay intact for the maintainer's local workflow |
| `docs/superpowers/specs/2026-05-13-release-workflow-design.md` | **new** — this document |

`build-test-linux.yml`, `ci-workflow.yml`, `code-coverage.yml`, `codeql-analysis.yml` are not touched. The legacy `rrdtool.spec` and empty `debian/` directory are left untouched — they remain for historical reference and any downstream user who may still be consuming the old spec. They are explicitly not the basis for the new packaging.

## Edge cases & risks

- **`workflow_dispatch` race with concurrent master pushes.** Someone could push to master between `check-ci` running and `publish` running. **Mitigation:** `publish` step 2 re-fetches origin and asserts `origin/master` still matches `github.sha`; if not, abort. Cheap and removes the race.

- **Tag collision.** If `v$NEW` already exists (e.g., someone made a release out-of-band), `git tag` fails. The job aborts before pushing. Manual cleanup needed; not designed to auto-resolve.

- **`CHANGES` doesn't start with the expected master block.** The perl rewrite is structural; if the file has been reorganized, it errors out. The maintainer fixes `CHANGES` and re-dispatches.

- **Pipeline duration.** Windows MSVC build is ~10–15 min, RPM and DEB matrices run in parallel. Total release time ~15–20 min. Acceptable.

- **The new `rrdtool-opt.spec` is minimal but untested in production.** First-run failures will surface real issues (missing BuildRequires, configure flag typos, RPM macro quirks). Because every job hard-fails the workflow, the maintainer will see these immediately and fix-then-re-dispatch — no half-published releases.

- **`/opt`-install packages are non-canonical by design.** They're a single combined package, don't follow FHS, don't conflict with the distribution rrdtool. Distro-package users won't find them via `apt show rrdtool` or `dnf info rrdtool` because they're not the same package — different upstream channel. The GitHub Release body will include a short "Using the /opt packages" section explaining the env script.

- **Bindings need user opt-in to be discoverable.** The `.rpm` and `.deb` install Perl/Python/Tcl/Lua/Ruby bindings under `/opt/rrdtool/lib/<lang>` but the system Perl, Python, etc. don't look there by default. Users source `/opt/rrdtool/bin/rrdtool-env.sh` (or add it to their shell rc, or set `PERL5LIB`/`PYTHONPATH`/etc. themselves). The distribution's bindings remain untouched, so a user using the system `python3 -c 'import rrdtool'` still gets the distro version unless they've sourced our env script. This is the intended behavior.

- **Python binding directory varies by distro.** `AM_PATH_PYTHON` installs the module into `$prefix/lib/python$PYTHON_VERSION/site-packages`, where `$PYTHON_VERSION` is whatever Python the build container shipped (3.9 on Alma 9, 3.10/3.12 on Ubuntu 22.04/24.04, 3.11 on Debian 12). This is intentional: each package is built for a specific Python and the env script auto-discovers the versioned directory at use time.

- **Rollback is built-in by ordering.** Because the tag is only pushed in `publish` step 4, after every build has succeeded, there is no "build failed and we already published a half-release" scenario. The only edge case is if `publish` step 4 succeeds (tag pushed) and step 7 fails (Release-creation) — see "Failure modes" table above for the recovery path.

## Future cleanup (deferred)

The local `rrdtool-release` maintainer script is refactored in this iteration to source `bump-version.sh` and otherwise left intact, so the SCP-to-james pipeline keeps working during the transition. Once the GitHub Release flow is trusted, the script can shrink to just the version-propagation helper, and the SCP step either moves into a dedicated "publish to james" workflow or gets removed. Not part of this iteration.
