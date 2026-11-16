/// Makes every change to the analytics catalog a diff a reviewer reads
/// (#17).
///
/// A written rule with no mechanism behind it does not hold in this repo
/// (#165), so the catalog is checked by tests rather than by review alone.
/// `catalog_snapshot.json` records every event's name, property keys, value
/// kinds and token vocabularies. Renaming an event, adding a property or
/// adding a member to an enum a token draws from changes the rendered
/// catalog, and this test fails until the snapshot is updated in the same
/// change.
///
/// To update the snapshot after an intended change, run
///
///     UPDATE_ANALYTICS_CATALOG=1 flutter test --no-pub test/catalog_governance_test.dart
///
/// from this package, then review and commit the JSON.
///
/// This is a text snapshot, not a golden: it is not tagged `golden` and
/// runs in the normal `melos run test`. It reads files with `dart:io`, so it
/// runs on the VM only.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:analytics/analytics.dart';
import 'package:test/test.dart';

import 'support/catalog_samples.dart';

void main() {
  test('the catalog matches the committed snapshot', () {
    final rendered = _renderCatalog(catalogSamples);
    final file = File('test/catalog_snapshot.json');
    if (Platform.environment['UPDATE_ANALYTICS_CATALOG'] == '1') {
      file.writeAsStringSync(rendered);
    }
    expect(
      file.existsSync(),
      isTrue,
      reason: 'Run with UPDATE_ANALYTICS_CATALOG=1 to create the snapshot.',
    );
    expect(
      rendered,
      file.readAsStringSync(),
      reason:
          'The analytics catalog changed. If that was intended, re-run '
          'with UPDATE_ANALYTICS_CATALOG=1 and commit the snapshot (#17).',
    );
  });

  test('every catalog class is final and has exactly one sample', () {
    final source = File('lib/src/analytics_event.dart').readAsStringSync();
    // `sealed` admits subtypes from the whole library, parts included, so
    // a part file would be a place this scan cannot see.
    expect(
      source,
      isNot(contains(RegExp(r'^\s*part\s', multiLine: true))),
      reason: 'the catalog library must stay one file',
    );
    // Every declaration whose header names AnalyticsEvent, whatever its
    // modifiers or keyword, so a plain, base or abstract subtype is caught
    // rather than skipped.
    final subtypes = {
      for (final m in RegExp(
        r'^[ \t]*((?:\w+[ \t]+)*?)(class|mixin|enum)\s+(\w+)[^{;]*?'
        r'\b(?:extends|implements|with|on)\b[^{;]*?\bAnalyticsEvent\b',
        multiLine: true,
      ).allMatches(source))
        m.group(3)!: '${m.group(1)}${m.group(2)}',
    };
    // A subtype that isn't final can be extended outside the library,
    // which reopens the closed catalog.
    expect(
      [
        for (final MapEntry(:key, :value) in subtypes.entries)
          if (value != 'final class') '$value $key',
      ],
      isEmpty,
      reason: 'every event is declared `final class` (#17)',
    );
    final sampled = catalogSamples
        .map((e) => e.runtimeType.toString())
        .toList();
    expect(sampled.toSet(), subtypes.keys.toSet());
    expect(sampled, hasLength(subtypes.length), reason: 'one sample per class');
  });
}

/// Pretty JSON with a two-space indent and a trailing newline. Events are
/// sorted by name and each event's properties by key, so the file's order
/// never depends on declaration order.
String _renderCatalog(List<AnalyticsEvent> events) {
  final sorted = [...events]..sort((a, b) => a.name.compareTo(b.name));
  final catalog = {
    for (final event in sorted)
      event.name: {
        for (final key in event.properties.keys.toList()..sort())
          key: _describe(event.properties[key]!),
      },
  };
  return '${const JsonEncoder.withIndent('  ').convert(catalog)}\n';
}

Map<String, Object> _describe(AnalyticsValue value) => {
  'kind': value.kind.name,
  if (value case AnalyticsToken(:final vocabularyNames))
    'vocabulary': vocabularyNames,
};
