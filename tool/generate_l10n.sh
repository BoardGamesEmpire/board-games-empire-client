#!/usr/bin/env bash
# Runs `flutter gen-l10n` in every package that owns an l10n.yaml: the
# first codegen stage (#33), which must finish before build_runner runs.
# CI's generate job and the bug agent's setup action
# (.github/actions/bug-agent-setup) both call it, so the two stage
# localizations one way (#849). Run it after `flutter pub get`.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

# Null-delimited so paths with spaces are safe, and the find runs OUTSIDE
# the loop's command substitution so a failure (e.g. a missing dir)
# actually aborts the script instead of silently yielding an empty list.
while IFS= read -r -d '' f; do
  pkg=$(dirname "$f")
  echo "gen-l10n: $pkg"
  (cd "$pkg" && flutter gen-l10n)
done < <(find packages apps -name l10n.yaml -not -path '*/.dart_tool/*' -print0)
