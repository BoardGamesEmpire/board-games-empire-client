#!/usr/bin/env bash
# Reports what the bug agent's commands can write. Run it from the
# workspace root, as a command the agent runs, so it sees the real isolation
# that CLAUDE_CODE_SUBPROCESS_ENV_SCRUB starts, not sandbox-check.sh's
# imitation of it. A fix run on #847 found the moved SDK's bin/cache
# read-only, though sandbox-check.sh passed.
#
# Prints one line per probe and never fails, so the whole picture comes
# back in one run. Everything it creates is removed again.
set -u

sdk=.bug-agent-env/flutter

probe() {
  local label=$1 target=$2
  if (touch "$target") 2>/dev/null; then
    echo "writable  $label ($target)"
    rm -f "$target"
  else
    echo "READ-ONLY $label ($target)"
  fi
}

echo "== where things are"
echo "pwd: $PWD"
echo "HOME: ${HOME:-unset}"
echo "flutter: $(command -v flutter || echo 'not on PATH')"
for path in . .bug-agent-env "$sdk" "$sdk/bin/cache" .bug-agent-env/home /tmp; do
  if [ -e "$path" ]; then
    echo "$(stat -c '%m  %U  %A' "$path")  $(readlink -f "$path")"
  else
    echo "missing  $path"
  fi
done

echo "== writes"
probe 'checkout root' ./.isolation-probe
probe 'tracked package dir' packages/core/models/.isolation-probe
probe 'gitignored dot-dir' .dart_tool/.isolation-probe
probe 'env dir' .bug-agent-env/.isolation-probe
probe 'SDK root' "$sdk/.isolation-probe"
probe 'SDK bin/cache' "$sdk/bin/cache/.isolation-probe"
probe 'engine.stamp' "$sdk/bin/cache/engine.stamp"
probe 'SDK .git' "$sdk/.git/.isolation-probe"
probe 'moved HOME' .bug-agent-env/home/.isolation-probe
probe '/tmp' /tmp/.isolation-probe

# A nested repository made here: if this is read-only while the checkout
# root is writable, the isolation treats nested git repos specially.
echo "== nested git repository"
nested=.isolation-probe-nested
if mkdir -p "$nested/sub" 2>/dev/null && git -C "$nested" init -q 2>/dev/null; then
  probe 'nested repo root' "$nested/.isolation-probe"
  probe 'nested repo subdir' "$nested/sub/.isolation-probe"
else
  echo "could not create $nested"
fi
rm -rf "$nested"

echo "== mounts covering the checkout"
grep -F "$PWD" /proc/self/mountinfo || echo "no mount entry names $PWD"

echo "== flutter --version"
flutter --version --no-version-check 2>&1 | tail -5
