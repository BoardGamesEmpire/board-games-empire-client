import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/portability.dart';
import 'package:logging/logging.dart';
import 'package:native_platform/src/data_export/file_picker_user_data_export_sink.dart';

void main() {
  final bytes = Uint8List.fromList([1, 2, 3]);

  test('passes the file name and bytes through', () async {
    String? seenName;
    Uint8List? seenBytes;
    final sink = FilePickerUserDataExportSink(
      saveFile: ({required fileName, required bytes}) async {
        seenName = fileName;
        seenBytes = bytes;
        return Uri.file('/tmp/export.json');
      },
    );

    await sink.save(fileName: 'bge-export.json', bytes: bytes);

    expect(seenName, 'bge-export.json');
    expect(seenBytes, bytes);
  });

  test('a cancelled dialog is cancelled', () async {
    final sink = FilePickerUserDataExportSink(
      saveFile: ({required fileName, required bytes}) async => null,
    );

    expect(
      await sink.save(fileName: 'a.json', bytes: bytes),
      UserDataExportSaveResult.cancelled,
    );
  });

  test('a chosen location is saved', () async {
    final sink = FilePickerUserDataExportSink(
      saveFile: ({required fileName, required bytes}) async =>
          Uri.file('/tmp/a.json'),
    );

    expect(
      await sink.save(fileName: 'a.json', bytes: bytes),
      UserDataExportSaveResult.saved,
    );
  });

  test('a dialog error propagates', () async {
    final sink = FilePickerUserDataExportSink(
      saveFile: ({required fileName, required bytes}) async =>
          throw StateError('no dialog'),
    );

    await expectLater(
      sink.save(fileName: 'a.json', bytes: bytes),
      throwsStateError,
    );
  });

  group("the picker's temporary files", () {
    late List<String> calls;

    setUp(() => calls = []);

    Future<void> clear() async => calls.add('clear');

    test("clears the picker's temporary files after a save", () async {
      final sink = FilePickerUserDataExportSink(
        saveFile: ({required fileName, required bytes}) async {
          calls.add('save');
          return Uri.file('/tmp/a.json');
        },
        clearTemporaryFiles: clear,
      );

      expect(
        await sink.save(fileName: 'a.json', bytes: bytes),
        UserDataExportSaveResult.saved,
      );
      expect(calls, ['save', 'clear']);
    });

    test("clears the picker's temporary files after a cancel", () async {
      final sink = FilePickerUserDataExportSink(
        saveFile: ({required fileName, required bytes}) async {
          calls.add('save');
          return null;
        },
        clearTemporaryFiles: clear,
      );

      expect(
        await sink.save(fileName: 'a.json', bytes: bytes),
        UserDataExportSaveResult.cancelled,
      );
      expect(calls, ['save', 'clear']);
    });

    test("clears the picker's temporary files after a failed save, and the "
        'failure still propagates', () async {
      final sink = FilePickerUserDataExportSink(
        saveFile: ({required fileName, required bytes}) async {
          calls.add('save');
          throw StateError('no dialog');
        },
        clearTemporaryFiles: clear,
      );

      await expectLater(
        sink.save(fileName: 'a.json', bytes: bytes),
        throwsStateError,
      );
      expect(calls, ['save', 'clear']);
    });

    test('a failing clean-up does not fail a completed save', () async {
      final records = <LogRecord>[];
      final previousLevel = Logger.root.level;
      Logger.root.level = Level.ALL;
      final subscription = Logger.root.onRecord.listen(records.add);
      addTearDown(() async {
        await subscription.cancel();
        Logger.root.level = previousLevel;
      });
      final failure = StateError('tmp is read-only');
      final sink = FilePickerUserDataExportSink(
        saveFile: ({required fileName, required bytes}) async =>
            Uri.file('/tmp/a.json'),
        clearTemporaryFiles: () async => throw failure,
      );

      expect(
        await sink.save(fileName: 'a.json', bytes: bytes),
        UserDataExportSaveResult.saved,
      );
      expect(
        records,
        contains(
          isA<LogRecord>()
              .having((r) => r.level, 'level', Level.WARNING)
              .having((r) => r.error, 'error', same(failure)),
        ),
      );
    });
  });
}
