#!/usr/bin/env bash
# Runs `flutter gen-l10n` in every package that owns an l10n.yaml: the
# first codegen stage (#33), which must finish before build_runner runs.
# CI's generate job and the bug agent's setup action
# (.github/actions/bug-agent-setup) both call it, so the two stage
# localizations one way (#849). Run it after `flutter pub get`.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# Null-delimited so paths with spaces are safe. find writes the list as its
# own command, so a failure (e.g. a missing dir) aborts the script before
# any gen-l10n runs. Fed to the loop through `< <(find …)`, its exit status
# would be dropped and the script would succeed on a partial list.
list=$(mktemp)
trap 'rm -f "$list"' EXIT
find packages apps -name l10n.yaml -not -path '*/.dart_tool/*' -print0 >"$list"

while IFS= read -r -d '' f; do
  pkg=$(dirname "$f")
  echo "gen-l10n: $pkg"
  (cd "$pkg" && flutter gen-l10n)
done <"$list"
