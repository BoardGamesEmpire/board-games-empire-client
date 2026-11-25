// The browser half of the remembered persist() refusal (#320): the record
// in the page's real `localStorage`.
//
// Run with `melos run test:web` (`flutter test --platform chrome`).
@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:web/web.dart' as web;
import 'package:web_platform/src/storage/local_storage_persist_refusals.dart';

void main() {
  const key = LocalStoragePersistRefusals.key;

  setUp(() => web.window.localStorage.removeItem(key));
  tearDown(() => web.window.localStorage.removeItem(key));

  test('reads null when nothing was refused', () {
    expect(LocalStoragePersistRefusals().read(), isNull);
  });

  test('a written refusal reads back in a later instance, as a page load '
      'would', () {
    final refusedAt = DateTime.utc(2026, 11, 24, 12, 30);

    LocalStoragePersistRefusals().write(refusedAt);

    expect(LocalStoragePersistRefusals().read(), refusedAt);
  });

  test('writing null forgets the refusal', () {
    final refusals = LocalStoragePersistRefusals()
      ..write(DateTime.utc(2026, 11, 24))
      ..write(null);

    expect(refusals.read(), isNull);
    expect(web.window.localStorage.getItem(key), isNull);
  });

  test('a value it cannot parse reads as no refusal', () {
    web.window.localStorage.setItem(key, 'not a date');

    expect(LocalStoragePersistRefusals().read(), isNull);
  });
}
