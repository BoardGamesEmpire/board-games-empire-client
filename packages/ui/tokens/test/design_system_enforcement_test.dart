@Tags(['enforcement'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Enforces the design-system rules across every package's `lib/` (#165).
///
/// ## Why this exists
///
/// `CONTRIBUTING.md` and the PR-template checklist have *stated* "no literal
/// colors or spacing at call sites" for as long as `ui_tokens` has existed.
/// When #165 audited it, adherence was **zero**: no feature package even
/// depended on `ui_tokens`, and there were 40+ literal `SizedBox` gaps and a
/// `maxWidth: 480` copy-pasted into eleven screens.
///
/// So the evidence on this codebase is unambiguous: a written rule with no
/// mechanism does not hold. This is the mechanism. It is deliberately blunt —
/// source-text matching, no analyzer plugin, no new dependency — because it
/// runs inside the existing `melos run test` gate and a rule that runs is
/// worth more than a rule that is elegant.
///
/// ## The allowlist
///
/// [_allowlist] is the escape hatch, and it exists on purpose: without one,
/// the first genuinely-justified literal gets the whole test deleted. Every
/// entry needs a written reason. If you are adding one, the question to answer
/// is "why can this value not come from a token?" — "it is easier" is not an
/// answer, but "this is a 1×1 semantics anchor, not a spacing decision" is.
///
/// ## What this cannot catch
///
/// Regex over source text, not a parse tree. It sees `SizedBox(height: 16)`
/// and not `SizedBox(height: someLocal)` where `someLocal = 16`. That is fine:
/// the goal is to stop the easy, thoughtless literal, not to be a type system.
/// Goldens (#32) cover what things actually look like.
void main() {
  final root = _workspaceRoot();

  group('design system enforcement', () {
    late List<_Violation> violations;

    setUpAll(() {
      violations = _scan(root);
    });

    test('no literal spacing, colors, radii or type at call sites', () {
      expect(
        violations,
        isEmpty,
        reason:
            '\n${violations.map((v) => v.describe(root)).join('\n')}\n\n'
            'Each of these should come from a token:\n'
            '  spacing  -> const BgeGap.md() / BgeTokens.of(context).spaceMd\n'
            '  colors   -> Theme.of(context).colorScheme.<role>\n'
            '  radii    -> BgeTokens.of(context).radiusMd\n'
            '  type     -> Theme.of(context).textTheme.<role>\n'
            '  widths   -> BgeTokens.of(context).contentMaxWidth\n\n'
            'If a literal is genuinely correct, add it to _allowlist in\n'
            'test/design_system_enforcement_test.dart WITH A REASON.\n',
      );
    });

    test('the allowlist has not gone stale', () {
      // An allowlist entry that no longer earns its keep is worse than no
      // entry: it silently disables a rule for a whole file, forever, on the
      // strength of a justification that may no longer apply.
      //
      // Checking only that the file still EXISTS is not enough — that was the
      // first version of this test, and it would have happily kept a blanket
      // exemption alive long after the literal it excused was deleted. So each
      // (file, rule) pair is re-run: if the rule no longer fires there, the
      // exemption is dead and must go.
      final stale = <String>[];

      for (final entry in _allowlist.entries) {
        final file = File('$root/${entry.key}');
        if (!file.existsSync()) {
          stale.add('${entry.key} — file no longer exists');
          continue;
        }
        final hits = _scanSource(file.readAsStringSync());
        for (final ruleId in entry.value) {
          // Same scanner the real check uses — a staleness test with its own
          // matching logic would drift from the rules it claims to audit.
          final fires = hits.any((v) => v.rule.id == ruleId);
          if (!fires) {
            stale.add(
              '${entry.key} — exempt from "$ruleId", but that rule no longer '
              'fires here',
            );
          }
        }
      }

      expect(
        stale,
        isEmpty,
        reason:
            'Dead allowlist entries — remove them:\n${stale.join('\n')}\n\n'
            'An exemption should disappear along with the code that needed '
            'it, or it quietly becomes a permanent hole.\n',
      );
    });
  });
}

/// Files exempted from specific rules, each with the reason it is exempt.
///
/// Keyed by workspace-relative path; the value lists the exempt rule ids.
const Map<String, List<String>> _allowlist = {
  // The token layer defines the values every other package consumes; literals
  // in these two files are the definitions, not call sites.
  //
  // This list started with seven entries covering the whole token package.
  // Five of them were dead on arrival — blanket exemptions for rules that
  // could never have fired there — and the staleness check found them. Keep it
  // to files that genuinely trip a rule.
  'packages/ui/tokens/lib/src/bge_color_schemes.dart': ['color'],
  'packages/ui/tokens/lib/src/bge_typography.dart': ['type'],
};

class _Rule {
  const _Rule(this.id, this.pattern, this.message);
  final String id;
  final RegExp pattern;
  final String message;
}

final List<_Rule> _rules = [
  _Rule(
    'spacing',
    RegExp(
      // Constructors that take spacing positionally or by side...
      r'(SizedBox|EdgeInsets|EdgeInsetsDirectional)[\w.]*\([^)]*?\b\d'
      // ...and spacing-valued PROPERTIES. Flex, Wrap, OverflowBar and friends
      // take `spacing:`/`runSpacing:`/`gap:` directly, which the constructor
      // patterns above never see — the first version of this rule missed an
      // `OverflowBar(spacing: 8)` while claiming spacing was enforced.
      r'|\b(spacing|runSpacing|gap|horizontalSpacing|verticalSpacing):\s*\d',
    ),
    'literal spacing',
  ),
  _Rule(
    'color',
    // `Colors.` (the Material palette) or a raw ARGB literal. Both bypass the
    // scheme, so neither responds to theme, high contrast, or a palette swap.
    RegExp(r'\bColors\.\w+|\bColor\(0x'),
    'literal color',
  ),
  _Rule(
    'radius',
    RegExp(r'(BorderRadius|Radius)\.circular\(\s*\d'),
    'literal radius',
  ),
  _Rule(
    'type',
    RegExp(r'TextStyle\([^)]*\b(fontSize|fontFamily):'),
    'literal type (font size or family)',
  ),
  _Rule(
    'width',
    RegExp(r'BoxConstraints\([^)]*(maxWidth|minWidth):\s*\d'),
    'literal layout width',
  ),
];

class _Violation {
  _Violation(this.file, this.line, this.rule, this.text);
  final String file;
  final int line;
  final _Rule rule;
  final String text;

  String describe(String root) {
    final normalizedRoot = root.replaceAll(r'\', '/');
    final rel = file.startsWith('$normalizedRoot/')
        ? file.substring(normalizedRoot.length + 1)
        : file;
    return '  $rel:$line — ${rule.message}: ${text.trim()}';
  }
}

List<_Violation> _scan(String root) {
  final violations = <_Violation>[];
  final normalizedRoot = root.replaceAll(r'\', '/');

  // BOTH trees. `apps/` is thin by design — three `main.dart` wrappers of a
  // dozen lines each — but "small" is not "exempt", and an unscanned directory
  // is exactly where the next literal lands, precisely because nobody expects
  // UI code there.
  final roots = [
    Directory('$root/packages'),
    Directory('$root/apps'),
  ].where((d) => d.existsSync());

  // `followLinks: false` matters here: `apps/*/*/flutter/ephemeral/` contains
  // `.plugin_symlinks/` pointing into the pub cache, so following links walks
  // straight into third-party plugin source and reports their literals as ours.
  for (final entity in roots.expand(
    (d) => d.listSync(recursive: true, followLinks: false),
  )) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;

    // Normalized to forward slashes before any path check. Windows is a
    // supported desktop target, and `FileSystemEntity.path` uses backslashes
    // there — so every `/lib/` test below would fail, every file would be
    // skipped, and the suite would report a clean tree while enforcing
    // nothing. A gate that silently passes is worse than no gate.
    final path = entity.path.replaceAll(r'\', '/');
    // Only shipped code. Tests legitimately construct arbitrary sizes to
    // exercise layout, and generated output is not hand-written.
    if (!path.contains('/lib/')) continue;
    if (path.contains('/.dart_tool/')) continue;
    if (path.contains('/l10n/')) continue;
    // Build output and vendored plugin sources are not ours to police.
    if (path.contains('/ephemeral/')) continue;
    if (path.contains('/.plugin_symlinks/')) continue;
    if (path.contains('/build/')) continue;
    if (path.endsWith('.g.dart') || path.endsWith('.freezed.dart')) continue;

    // Also normalized, since `_allowlist` keys are forward-slash paths.
    final rel = path.substring(normalizedRoot.length + 1);
    final exempt = _allowlist[rel] ?? const <String>[];

    violations.addAll(
      _scanSource(
        entity.readAsStringSync(),
        exempt: exempt,
      ).map((v) => _Violation(path, v.line, v.rule, v.text)),
    );
  }
  return violations;
}

/// Scans one file's source. Exposed for the allowlist staleness check.
///
/// Matches against the WHOLE source, not line by line. `dart format` wraps
/// constructors across lines as a matter of course, so a line-based scan never
/// sees the thing it is looking for:
///
/// ```dart
/// style: const TextStyle(
///   fontFamily: 'monospace',   // line-based scan: no `TextStyle(` on this line
///   fontSize: 12,              // and no `fontSize:` on the line that has it
/// ),
/// ```
///
/// That is not a hypothetical — six of the seven original allowlist entries
/// turned out to be exempting rules that could never have fired, because the
/// code they guarded was formatted across lines.
List<_Violation> _scanSource(String source, {List<String> exempt = const []}) {
  // Strip line comments before matching. Doc comments discuss these values
  // constantly ("no literal colors", "16dp gap"), and a scanner that flags its
  // own documentation gets switched off. Done by blanking the comment rather
  // than deleting the line, so line numbers survive.
  final stripped = source
      .split('\n')
      .map((l) {
        final i = l.indexOf('//');
        // Not string-aware — a `//` inside a string literal blanks the rest of
        // the line. Acceptable: the cost is a missed violation, never a false
        // one, and URLs in strings are the common case.
        return i == -1 ? l : l.substring(0, i);
      })
      .join('\n');

  final found = <_Violation>[];
  for (final rule in _rules) {
    if (exempt.contains(rule.id)) continue;
    for (final match in rule.pattern.allMatches(stripped)) {
      final line =
          '\n'.allMatches(stripped.substring(0, match.start)).length + 1;
      found.add(_Violation('', line, rule, match.group(0)!));
    }
  }
  return found;
}

/// Walks up from the test's working directory to the pub workspace root.
String _workspaceRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 8; i++) {
    final pubspec = File('${dir.path}/pubspec.yaml');
    if (pubspec.existsSync() &&
        pubspec.readAsStringSync().contains('\nworkspace:')) {
      return dir.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  throw StateError(
    'Could not locate the workspace root from ${Directory.current.path}. '
    'This test scans every package, so it needs the root pubspec.',
  );
}
