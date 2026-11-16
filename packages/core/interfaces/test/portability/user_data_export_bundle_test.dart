import 'dart:convert';

import 'package:interfaces/portability.dart';
import 'package:test/test.dart';

UserDataExportBundle _bundle({
  String serverName = 'Example BGE',
  String exportedAt = '2026-05-17T19:33:00.000Z',
}) => UserDataExportBundle(
  json: {
    'schemaVersion': 1,
    'exportedAt': exportedAt,
    'serverName': serverName,
    'categories': {
      'profile': {'username': 'alice'},
    },
  },
  unconfirmedKeys: const [],
);

void main() {
  group('UserDataExportBundle', () {
    test('toBytes is UTF-8 JSON indented by two spaces, ending in a '
        'newline', () {
      final bundle = _bundle(serverName: 'Café');

      expect(
        utf8.decode(bundle.toBytes()),
        '${const JsonEncoder.withIndent('  ').convert(bundle.json)}\n',
      );
    });

    test('fileName is bge-export-<slug>-<UTC minute>.json', () {
      expect(
        _bundle(serverName: 'Example BGE!').fileName,
        'bge-export-example-bge-2026-05-17-1933.json',
      );
    });

    test('fileName uses the UTC minute of an offset timestamp', () {
      expect(
        _bundle(exportedAt: '2026-01-02T00:05:30+02:00').fileName,
        'bge-export-example-bge-2026-01-01-2205.json',
      );
    });

    test('fileName falls back to "server" when the name has no letters or '
        'digits', () {
      expect(
        _bundle(serverName: '★★').fileName,
        startsWith('bge-export-server-'),
      );
    });

    test("fileName caps a long server name's slug at 60 characters", () {
      String slugOf(String name) {
        final fileName = _bundle(serverName: name).fileName;
        return fileName.substring(
          'bge-export-'.length,
          fileName.length - '-2026-05-17-1933.json'.length,
        );
      }

      final plain = slugOf('a' * 200);
      expect(plain, 'a' * 60);

      // The dash lands at the 60th character, so the cut leaves it
      // trailing and it must be trimmed.
      final straddling = slugOf('${'a' * 59} ${'b' * 140}');
      expect(straddling, 'a' * 59);
      expect(straddling, isNot(endsWith('-')));

      // The dash lands at the 61st character, so nothing is left to trim.
      final after = slugOf('${'a' * 60} ${'b' * 139}');
      expect(after, 'a' * 60);
    });
  });
}
