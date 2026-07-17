import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:native_platform/native_platform.dart';

void main() {
  late Directory dir;
  Future<Directory> provider() async => dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('bge_log_test');
  });
  tearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  LogRecord rec(String message) => LogRecord(Level.WARNING, message, 'bge.t');
  String path(String name) => '${dir.path}${Platform.pathSeparator}$name';

  test(
    'writes formatted lines to <baseName>.log and flushes on close',
    () async {
      final sink = RotatingFileLogSink(directoryProvider: provider)
        ..emit(rec('one'))
        ..emit(rec('two'));
      await sink.close();

      final file = File(path('bge.log'));
      expect(file.existsSync(), isTrue);
      final contents = file.readAsStringSync();
      expect(contents, contains('one'));
      expect(contents, contains('two'));
    },
  );

  test('rotates once the active file would exceed maxBytes', () async {
    final sink = RotatingFileLogSink(
      directoryProvider: provider,
      maxBytes: 60,
      maxFiles: 2,
    );
    for (var i = 0; i < 12; i++) {
      sink.emit(rec('line-$i-padding-padding'));
    }
    await sink.close();

    expect(File(path('bge.log')).existsSync(), isTrue);
    expect(File(path('bge.1.log')).existsSync(), isTrue);
  });

  test('prunes rotated files beyond maxFiles', () async {
    final sink = RotatingFileLogSink(
      directoryProvider: provider,
      maxBytes: 40,
      maxFiles: 2,
    );
    for (var i = 0; i < 40; i++) {
      sink.emit(rec('padding-padding-$i'));
    }
    await sink.close();

    // Only the active file plus maxFiles rotations survive.
    expect(File(path('bge.3.log')).existsSync(), isFalse);
  });
}
