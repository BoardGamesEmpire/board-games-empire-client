#!/usr/bin/env bash
# Installs the Flutter release that tool/flutter_sdk.sha256 names into a
# directory, after checking the archive against that committed digest.
#
# Usage:
#   tool/install_flutter.sh <dest>             # afterwards <dest>/bin/flutter exists
#   tool/install_flutter.sh --print-version    # prints the pinned version
#
# Two callers, so the download, the check and the reading of the digest
# line have one definition:
#   * .github/actions/setup-flutter, which every CI job uses (#426);
#   * tool/goldens/Dockerfile, the golden-test image (#159).
#
# Why a committed digest: CI used to install Flutter through
# subosito's setup action, whose nested actions/cache can't be pinned to
# a SHA (#426). A download is only as trustworthy as what checks it, so,
# as with the drift web assets (#418), the expected sha256 is committed
# and the archive is refused unless it matches. check_sdk_constraints.dart
# holds the file to the root pubspec's pin.
#
# Reads flutter_sdk.sha256 from this script's own directory, so it runs
# from any cwd and from a copy of the two files (the Dockerfile copies
# them). Linux x64 only: that is the one archive the digest names.
#
# A <dest> that already holds this release (it carries the marker this
# script writes last) is left alone, so a CI cache hit or a re-run costs
# nothing. A <dest> that exists without that marker is refused rather
# than overwritten: it is another release, or an extract that never
# finished.
#
# Refs #426, #159.

set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <dest> | --print-version" >&2
  exit 64 # EX_USAGE
fi
dest=$1

here=$(cd "$(dirname "$0")" && pwd)
digest_file="$here/flutter_sdk.sha256"
line=$(cat "$digest_file")
# The same shape check_sdk_constraints.dart requires, so a malformed line
# stops here, before it becomes an archive name or an SDK path.
if ! [[ $line =~ ^[0-9a-f]{64}\ \ (flutter_linux_([0-9]+\.[0-9]+\.[0-9]+)-stable\.tar\.xz)$ ]]; then
  echo "$digest_file must be one line: <64 hex chars>, two spaces, flutter_linux_<version>-stable.tar.xz" >&2
  exit 1
fi
archive=${BASH_REMATCH[1]}
version=${BASH_REMATCH[2]}

# The setup action names its cache directory after the version. It asks
# here rather than parsing the file a second way.
if [ "$dest" = --print-version ]; then
  echo "$version"
  exit 0
fi

base_url=https://storage.googleapis.com/flutter_infra_release/releases/stable/linux

# The marker is the digest line itself, so it names the exact archive,
# not just a version.
marker=.flutter_sdk.sha256

if [ "$(uname -sm)" != "Linux x86_64" ]; then
  echo "install_flutter.sh installs the Linux x64 archive only; this is $(uname -sm)." >&2
  exit 1
fi

if [ -e "$dest" ]; then
  if [ -f "$dest/$marker" ] && [ "$(cat "$dest/$marker")" = "$line" ]; then
    echo "Flutter $version is already installed in $dest."
    exit 0
  fi
  echo "$dest exists but does not hold Flutter $version from $digest_file." >&2
  echo "Remove it, or install somewhere else." >&2
  exit 1
fi

# The archive goes to a temp dir; the extract goes beside <dest>, so the
# final move is a rename on one filesystem and <dest> appears only once
# it is whole.
mkdir -p "$(dirname "$dest")"
work=$(mktemp -d)
staging=$(mktemp -d "$(dirname "$dest")/.install_flutter.XXXXXX")
trap 'rm -rf "$work" "$staging"' EXIT

echo "Downloading $archive"
curl --fail --silent --show-error --location \
  --output "$work/$archive" "$base_url/$archive"

# sha256sum -c reads the committed line and finds the archive by name in
# the current directory.
(cd "$work" && sha256sum --check --strict --quiet "$digest_file")

tar -xJf "$work/$archive" -C "$staging"
rm "$work/$archive"
# Written last, so only a finished extract carries it.
printf '%s\n' "$line" > "$staging/flutter/$marker"
mv "$staging/flutter" "$dest"
echo "Installed Flutter $version in $dest."
