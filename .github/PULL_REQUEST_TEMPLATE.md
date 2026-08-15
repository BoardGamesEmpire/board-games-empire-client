## What

<!-- What changes, and why. Link the issue: "Closes #123". -->

## How

<!-- The approach, and anything a reviewer would otherwise have to reverse
     engineer. If you rejected an obvious alternative, say why — that is
     usually the most useful part of a description. -->

## Verification

<!-- What you actually ran, and what it said. Not "tests pass" — the commands
     and their outcome. If something is untested, say so here rather than
     leaving it to be discovered. -->

- [ ] `melos run analyze` / `melos run analyze:dart`
- [ ] `melos run format:check`
- [ ] `melos run test`
- [ ] `melos run check:constraints`
- [ ] `melos run test:goldens` (if anything visual changed)
- [ ] `melos run check:palette` (if the palette or its generator changed)

## Checklist

- [ ] No hardcoded user-facing strings — new strings are ARB-backed with an
      `@key` description
- [ ] No literal colors, spacing, type, or radii at call sites — values come
      from `ui_tokens` (enforced by the design-system test)
- [ ] Drift schema changed → ran `melos run schema:dump` and committed the JSON
- [ ] Goldens changed intentionally → ran `melos run goldens:update` and
      committed only `test/**/goldens/ci/`
- [ ] Changed a melos script that CI reimplements → updated
      `.github/workflows/ci.yaml` to match
