@TestOn('browser')
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/portability.dart';
import 'package:web_platform/web_storage_composition.dart';

void main() {
  final bytes = Uint8List.fromList([123, 125]);

  test('clicks a download for the file name and reports downloaded', () async {
    String? url;
    String? name;
    final sink = DownloadUserDataExportSink(
      click: (u, n) {
        url = u;
        name = n;
      },
      revoke: (_) {},
    );

    final result = await sink.save(fileName: 'bge-export.json', bytes: bytes);

    expect(result, UserDataExportSaveResult.downloaded);
    expect(url, startsWith('blob:'));
    expect(name, 'bge-export.json');
  });

  test(
    'revokes the object URL only after the delay, so the download can start',
    () {
      fakeAsync((async) {
        String? clicked;
        final revoked = <String>[];
        final sink = DownloadUserDataExportSink(
          click: (u, _) => clicked = u,
          revoke: revoked.add,
        );

        unawaited(sink.save(fileName: 'a.json', bytes: bytes));
        async
          ..flushMicrotasks()
          ..elapse(
            DownloadUserDataExportSink.revokeDelay - const Duration(seconds: 1),
          );
        expect(revoked, isEmpty);

        async.elapse(const Duration(seconds: 1));
        expect(revoked, [clicked]);
      });
    },
  );

  test('revokes the object URL at once when the click throws', () async {
    String? clicked;
    final revoked = <String>[];
    final sink = DownloadUserDataExportSink(
      click: (u, _) {
        clicked = u;
        throw StateError('blocked');
      },
      revoke: revoked.add,
    );

    await expectLater(
      sink.save(fileName: 'a.json', bytes: bytes),
      throwsStateError,
    );

    expect(revoked, [clicked]);
  });
}
