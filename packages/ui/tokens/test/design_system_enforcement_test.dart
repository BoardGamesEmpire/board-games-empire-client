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

    // A test for the test. Three review rounds found rules that passed while
    // enforcing less than their documentation claimed — a scanner reporting a
    // clean tree is indistinguishable from one that is looking in the wrong
    // place, so the rules get their own fixtures rather than being trusted.
    //
    // Add a case here whenever a rule changes. "The suite is green" says
    // nothing on its own; these say what green means.
    group('the rules catch what they claim', () {
      const shouldFire = <String, String>{
        // spacing — constructors, the BgeGap escape hatch, and properties
        'SizedBox(height: 16)': 'spacing',
        'EdgeInsets.all(24)': 'spacing',
        'EdgeInsetsDirectional.only(start: 16)': 'spacing',
        'const BgeGap.custom(12)': 'spacing',
        'OverflowBar(spacing: 8)': 'spacing',
        'Column(spacing: 12)': 'spacing',
        'Wrap(runSpacing: 4)': 'spacing',
        // Mixed token-and-literal: the shape a half-finished migration
        // leaves behind, and the one a regex cannot see past.
        'EdgeInsets.fromLTRB(BgeTokens.of(context).spaceMd, 12, 0, 0)':
            'spacing',
        'SizedBox(width: MediaQuery.of(context).size.width, height: 24)':
            'spacing',
        'BoxConstraints(maxWidth: MediaQuery.of(context).size.width, '
                'minWidth: 100)':
            'width',
        // color — every way to name one that is not a scheme role
        'color: Colors.black54': 'color',
        'Color(0xFF2B8FF0)': 'color',
        'Color.fromARGB(255, 1, 2, 3)': 'color',
        'Color.fromRGBO(1, 2, 3, 1)': 'color',
        'Color.from(alpha: 1, red: 1, green: 0, blue: 0)': 'color',
        'CupertinoColors.systemRed': 'color',
        // type — both shapes, including the one that never says TextStyle
        "TextStyle(fontFamily: 'monospace', fontSize: 12)": 'type',
        'textTheme.bodySmall?.copyWith(fontSize: 12)': 'type',
        'TextStyle(color: Theme.of(context).colorScheme.primary, fontSize: 12)':
            'type',
        // radius / width
        'BorderRadius.circular(12)': 'radius',
        'BoxConstraints(maxWidth: 480)': 'width',
      };

      const shouldNotFire = <String>[
        // The tokenized forms. If any of these fire, the rule is unusable and
        // the codebase cannot satisfy its own gate.
        'const BgeGap.md()',
        'const BgeGap.sm(axis: Axis.horizontal)',
        'EdgeInsets.all(BgeTokens.of(context).spaceLg)',
        'SizedBox(height: tokens.spaceMd)',
        'OverflowBar(spacing: BgeTokens.of(context).spaceSm)',
        'color: Theme.of(context).colorScheme.primary',
        'Color.lerp(synced, other.synced, t)',
        'BorderRadius.circular(tokens.radiusMd)',
        'BoxConstraints(maxWidth: tokens.contentMaxWidth)',
        // Non-dimensional arguments are none of this rule's business. Reading
        // the whole argument list would report the stroke width here as
        // literal spacing, and a rule that cries wolf gets switched off.
        'SizedBox.square(dimension: t.spaceMd, child: Spinner(strokeWidth: 2))',
        'SizedBox(width: double.infinity, child: FilledButton(onPressed: f))',
        'EdgeInsets.all(tokens.spaceMd)',
        // Zero is "none", not a scale value. There is no token for nothing,
        // and `EdgeInsets.zero` cannot express a single zero side.
        'EdgeInsets.fromLTRB(t.spaceMd, t.spaceSm, t.spaceMd, 0)',
        'BoxConstraints(minHeight: 0)',
        // The one sanctioned type override: a token reference, not a literal.
        'copyWith(fontFamily: BgeTypography.monospaceFamily)',
        'TextStyle(fontSize: size, height: height)',
      ];

      shouldFire.forEach((source, ruleId) {
        test('flags $source', () {
          final hits = _scanSource(source).map((v) => v.rule.id).toSet();
          expect(
            hits,
            contains(ruleId),
            reason: '"$source" must trip the "$ruleId" rule',
          );
        });
      });

      for (final source in shouldNotFire) {
        test('allows $source', () {
          expect(
            _scanSource(source).map((v) => v.rule.id),
            isEmpty,
            reason: '"$source" is the tokenized form and must be legal',
          );
        });
      }
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
  // The generated scheme table: these `Color(0x…)` values ARE the palette
  // every other file consumes through `colorScheme`, so they are definitions
  // rather than call sites. The one remaining entry.
  'packages/ui/tokens/lib/src/bge_color_schemes.dart': ['color'],
};

// This list started at seven entries covering most of the token package, and
// every removal was forced by the staleness check rather than noticed by
// reading:
//
//   * five were dead on arrival — blanket exemptions for rules that could
//     never have fired in those files;
//   * `bge_text_field.dart` stopped needing one once its 1×1 semantics anchor
//     was given a name instead of being written inline;
//   * `bge_typography.dart` stopped needing one once the `type` rule matched
//     literal values rather than any mention of `fontSize:`/`fontFamily:` —
//     the file names its sizes, so it never wrote a literal to begin with.
//
// The pattern is worth remembering: an exemption was usually a sign the RULE
// was wrong, not that the file was special.

class _Rule {
  const _Rule(this.id, this.pattern, this.message);

  final String id;

  /// Source pattern, or null when the rule is only reachable through
  /// [_scanDimensionalConstructors] — some shapes cannot be matched with a
  /// regex at all, because a nested call truncates `[^)]*`.
  final RegExp? pattern;

  final String message;
}

final List<_Rule> _rules = [
  // Spacing-valued PROPERTIES. Flex, Wrap, OverflowBar and friends take
  // `spacing:`/`runSpacing:`/`gap:` directly, which no constructor pattern
  // sees — an `OverflowBar(spacing: 8)` slipped through on that.
  _Rule(
    'spacing',
    RegExp(
      r'\b(spacing|runSpacing|gap|horizontalSpacing|verticalSpacing):\s*\d',
    ),
    'literal spacing',
  ),
  _Rule(
    'color',
    // Every way to write a colour that is not a scheme role. `Colors.` and
    // `CupertinoColors.` are the platform palettes; `Color(0x…)` and the
    // `Color.fromARGB`/`fromRGBO`/`from` factories are raw channel values.
    // All bypass the scheme, so none responds to theme, high contrast, or a
    // palette swap. `Color.lerp` is deliberately NOT here — it interpolates
    // colours it was given rather than inventing one.
    RegExp(
      r'\bColors\.\w+|\bCupertinoColors\.\w+|\bColor\(0x|\bColor\.from\w*\(',
    ),
    'literal color',
  ),
  _Rule(
    'radius',
    RegExp(r'(BorderRadius|Radius)\.circular\(\s*\d'),
    'literal radius',
  ),
  // Reached only via `_scanDimensionalConstructors` — `BoxConstraints` takes
  // its widths as arguments that a regex cannot reliably reach past a nested
  // `MediaQuery.of(context)`.
  const _Rule('width', null, 'literal layout width'),
  _Rule(
    'type',
    // Matches the ARGUMENT, not the enclosing constructor. Anchoring on
    // `TextStyle(` missed both of the common shapes: `copyWith(fontSize: 12)`
    // never mentions TextStyle, and in
    // `TextStyle(color: Theme.of(context)…, fontSize: 12)` the `[^)]*` ran
    // out at the `)` of `of(context)` long before reaching the size.
    //
    // Deliberately literal-only — a number for size, a quoted string for
    // family. `fontFamily: BgeTypography.monospaceFamily` is a token
    // reference and must stay legal, or the one sanctioned override becomes
    // impossible to write.
    RegExp(r'''\bfontSize:\s*\d|\bfontFamily:\s*['"]'''),
    'literal type (font size or family)',
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

/// Constructors whose arguments are dimensions, and the rule each reports as.
///
/// These cannot be done with a regex. `[^)]*` stops at the FIRST `)`, so a
/// nested token lookup hides everything after it —
/// `EdgeInsets.fromLTRB(BgeTokens.of(context).spaceMd, 12, 0, 0)` passed the
/// gate because the scan ran out at the `)` of `of(context)`. Mixed
/// token-and-literal constructors are exactly the shape a half-finished
/// migration leaves behind, so missing them defeats the point.
const Map<String, String> _dimensionalConstructors = {
  'SizedBox': 'spacing',
  'EdgeInsets': 'spacing',
  'EdgeInsetsDirectional': 'spacing',
  // The escape hatch is only an escape hatch if reaching for it is visible.
  'BgeGap': 'spacing',
  'BoxConstraints': 'width',
};

/// Named arguments of those constructors that carry a dimension.
///
/// Everything else — `child:`, `key:`, `axis:` — is skipped. Without this,
/// `SizedBox.square(dimension: t.spaceMd, child: CircularProgressIndicator(
/// strokeWidth: 2))` would report the stroke width as literal spacing, and a
/// rule that cries wolf gets switched off.
const Set<String> _dimensionalArgs = {
  'width',
  'height',
  'dimension',
  'left',
  'top',
  'right',
  'bottom',
  'start',
  'end',
  'horizontal',
  'vertical',
  'minWidth',
  'maxWidth',
  'minHeight',
  'maxHeight',
};

/// Splits a balanced argument list on top-level commas.
List<String> _topLevelArgs(String args) {
  final out = <String>[];
  var depth = 0;
  var start = 0;
  for (var i = 0; i < args.length; i++) {
    final c = args[i];
    if (c == '(' || c == '[' || c == '{') {
      depth++;
    } else if (c == ')' || c == ']' || c == '}') {
      depth--;
    } else if (c == ',' && depth == 0) {
      out.add(args.substring(start, i));
      start = i + 1;
    }
  }
  out.add(args.substring(start));
  return out.where((a) => a.trim().isNotEmpty).toList();
}

/// Bare numeric literals — not parts of identifiers, and not hex colours
/// (those are the `color` rule's business).
final _bareNumber = RegExp(r'(?<![\w.$])\d+(?:\.\d+)?');

/// Whether [value] contains a NON-ZERO numeric literal.
///
/// Zero is exempt on purpose: `EdgeInsets.fromLTRB(t.spaceMd, t.spaceSm,
/// t.spaceMd, 0)` and `minHeight: 0` are saying "none", and there is no token
/// for nothing. `EdgeInsets.zero` covers the all-sides case but cannot express
/// a single zero side, so demanding a token here would make correct code
/// unwritable — the fastest way to get an enforcement rule deleted.
bool _hasNonZeroLiteral(String value) =>
    _bareNumber.allMatches(value).any((m) => double.parse(m.group(0)!) != 0);

/// Finds literal dimensions inside [_dimensionalConstructors].
List<_Violation> _scanDimensionalConstructors(String source) {
  final found = <_Violation>[];
  final opener = RegExp(
    r'\b(' + _dimensionalConstructors.keys.join('|') + r')(?:\.\w+)?\s*\(',
  );

  for (final m in opener.allMatches(source)) {
    final ruleId = _dimensionalConstructors[m.group(1)]!;
    final rule = _rules.firstWhere((r) => r.id == ruleId);

    // Walk to the matching close paren, so nested calls cannot truncate us.
    var depth = 0;
    var end = -1;
    for (var i = m.end - 1; i < source.length; i++) {
      final c = source[i];
      if (c == '(') {
        depth++;
      } else if (c == ')') {
        depth--;
        if (depth == 0) {
          end = i;
          break;
        }
      }
    }
    if (end == -1) continue;

    for (final arg in _topLevelArgs(source.substring(m.end, end))) {
      final colon = arg.indexOf(':');
      final String value;
      if (colon != -1 &&
          RegExp(r'^\s*\w+\s*$').hasMatch(arg.substring(0, colon))) {
        final name = arg.substring(0, colon).trim();
        if (!_dimensionalArgs.contains(name)) continue;
        value = arg.substring(colon + 1);
      } else {
        // Positional: `EdgeInsets.all(24)`, `BgeGap.custom(12)`.
        value = arg;
      }
      if (_hasNonZeroLiteral(value)) {
        final line = '\n'.allMatches(source.substring(0, m.start)).length + 1;
        found.add(_Violation('', line, rule, '${m.group(0)}…${value.trim()}'));
        break;
      }
    }
  }
  return found;
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

  final found = <_Violation>[
    for (final v in _scanDimensionalConstructors(stripped))
      if (!exempt.contains(v.rule.id)) v,
  ];
  for (final rule in _rules) {
    if (exempt.contains(rule.id)) continue;
    final pattern = rule.pattern;
    if (pattern == null) continue;
    for (final match in pattern.allMatches(stripped)) {
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
