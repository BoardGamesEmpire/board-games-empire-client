#!/usr/bin/env bash
# Runs the bug agent's verify commands in the shape of its sandbox (#849),
# after .github/actions/bug-agent-setup has run. Run it from the workspace
# root; .github/workflows/bug-agent-setup-check.yml does.
#
# Claude Code runs the agent's commands under bubblewrap: the root file
# system read-only, the checkout and /tmp writable, and no network. Each
# command below is one that .github/workflows/bug-agent.yml's `fix-tools`
# allow, in the form its `notes` give where they name one. Afterwards the
# tree must have no unignored changes, because the fix job collects the fix
# with `git add -A`.
set -euo pipefail

# The bubblewrap flags Claude Code's own sandbox passes, apart from its
# filesystem and network allowances.
sandboxed() {
  bwrap --ro-bind / / --dev /dev --proc /proc \
    --bind "$PWD" "$PWD" --bind /tmp /tmp \
    --unshare-net --unshare-pid --new-session --die-with-parent \
    --chdir "$PWD" -- bash -c "$1"
}

run() {
  echo "::group::$1"
  sandboxed "$2"
  echo "::endgroup::"
}

# Codegen that changes nothing proves little, so one output of each
# generator is deleted first and must come back: a fix that changes a
# freezed model or an ARB file regenerates offline.
regenerates() {
  local output=$1 label=$2 command=$3
  rm -f "$output"
  run "$label" "$command"
  if [ ! -f "$output" ]; then
    echo "::error::$label did not regenerate $output."
    exit 1
  fi
}

run 'flutter test (key_storage)' \
  'cd packages/storage/key_storage && flutter test --no-pub --exclude-tags golden'
run 'flutter test with l10n (auth)' \
  'cd packages/features/auth && flutter test --no-pub --exclude-tags golden test/widgets/auth_screen_test.dart'
run 'flutter test with freezed (models)' \
  'cd packages/core/models && flutter test --no-pub'
run 'flutter analyze (auth)' \
  'cd packages/features/auth && flutter analyze --no-pub .'
run 'dart analyze (auth)' \
  'dart analyze --fatal-infos packages/features/auth'
run 'dart format (key_storage)' \
  'dart format --output=none --set-exit-if-changed packages/storage/key_storage'
run 'format_workspace --check' \
  'dart run tool/format_workspace.dart --check'
run 'check_test_files' \
  'dart run tool/check_test_files.dart'
regenerates packages/features/auth/lib/l10n/auth_localizations.dart \
  'flutter gen-l10n (auth)' \
  'cd packages/features/auth && flutter gen-l10n'
regenerates packages/core/models/lib/src/dto/auth/auth_user.freezed.dart \
  'build_runner build' \
  'build_runner build --workspace'

changes=$(git status --porcelain)
if [ -n "$changes" ]; then
  echo "::error::The sandboxed commands left changes that aren't gitignored, which the fix job would collect as part of a fix:"
  echo "$changes"
  exit 1
fi
echo "Every command passed in the sandbox, and the tree is clean."
