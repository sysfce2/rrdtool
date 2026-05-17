#!/bin/sh
# Propagate VERSION (e.g. 1.9.1) into all hard-coded version locations
# across the source tree. Idempotent: running twice with the same version
# is a no-op the second time.
#
# Usage: bash conftools/bump-version.sh <version>
#
# Extracted from the maintainer's `rrdtool-release` script so the same
# logic can run inside CI release jobs.

set -e

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "usage: $0 <version>" >&2
    exit 2
fi

case "$VERSION" in
    [0-9]*.[0-9]*.[0-9]*) ;;
    *)
        echo "error: VERSION must look like X.Y.Z (got: '$VERSION')" >&2
        exit 2
        ;;
esac

NUMVERS=$(printf '%s\n' "$VERSION" | perl -n -e 'my @x=split /\./;printf "%d.%d%03d", @x')
CURRENT_YEAR=$(date +"%Y")

set -x

# Perl bindings: $VERSION = NUMVERS
perl -i -p -e 's/^\$VERSION.+/\$VERSION='"$NUMVERS"';/' bindings/perl-*/*.pm

# C source: in-source RRDtool version string + Copyright year
perl -i -p -e \
    's/RRDtool \d\S+/RRDtool '"$VERSION"'/;
     s/Copyright.+?Oetiker.+\d{4}/Copyright by Tobi Oetiker, 1997-'"$CURRENT_YEAR"'/' \
    src/*.h src/*.c

# Legacy rpm spec (kept for downstream consumers per design doc)
perl -i -p -e 's/^Version:.+/Version: '"$VERSION"'/' rrdtool.spec

# rrdbuild documentation: tarball name + version tag
perl -i -p -e 's/rrdtool-[\.\d]+\d(pre\d+)?(rc\d+)?/rrdtool-'"$VERSION"'/g;
               s/v\d+\.\d+\.\d+/v'"$VERSION"'/' doc/rrdbuild.pod

# MSVC: copyright year in resource files
perl -i -p -e 's/Copyright \(c\).+?Oetiker/Copyright (c) 1997-'"$CURRENT_YEAR"' Tobias Oetiker/' win32/*.rc

# MSVC: PACKAGE_* macros and NUMVERS in win32/rrd_config.h
perl -i -p -e \
    's/PACKAGE_MAJOR.+\d{1}/PACKAGE_MAJOR       '"$(echo "$VERSION" | cut -d. -f1)"'/;
     s/PACKAGE_MINOR.+\d{1}/PACKAGE_MINOR       '"$(echo "$VERSION" | cut -d. -f2)"'/;
     s/PACKAGE_REVISION.+\d{1}/PACKAGE_REVISION    '"$(echo "$VERSION" | cut -d. -f3)"'/;
     s/PACKAGE_VERSION.+\d{1}\"/PACKAGE_VERSION     "'"$VERSION"'"/;
     s/NUMVERS.+\d{1}/NUMVERS             '"$NUMVERS"'/' \
    win32/rrd_config.h
