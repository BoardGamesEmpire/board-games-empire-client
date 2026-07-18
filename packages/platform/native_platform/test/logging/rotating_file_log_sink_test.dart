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

  test(
    'recovers after a failed first open: a later emit reschedules a drain '
    'and both records eventually flush',
    () async {
      var attempts = 0;
      Future<Directory> flakyProvider() async {
        attempts++;
        if (attempts == 1) {
          throw const FileSystemException('binding not ready');
        }
        return dir;
      }

      final sink = RotatingFileLogSink(directoryProvider: flakyProvider)
        ..emit(rec('first')); // schedules a drain; open attempt #1 fails
      await pumpEventQueue(); // let the failed drain settle
      sink.emit(rec('second')); // must reschedule despite wasEmpty == false
      await sink.close();

      expect(attempts, greaterThanOrEqualTo(2));
      final contents = File(path('bge.log')).readAsStringSync();
      expect(contents, contains('first'));
      expect(contents, contains('second'));
    },
  );

  test(
    'a rotation failure preserves the un-written line and lets the sink '
    'reopen so later logs still write',
    () async {
      var failProvider = false;
      Future<Directory> flakyProvider() async {
        if (failProvider) throw const FileSystemException('rotate boom');
        return dir;
      }

      // Padded so every line comfortably exceeds maxBytes regardless of the
      // timestamp width, forcing a rotation on each write after the first.
      const pad = 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx';
      final sink = RotatingFileLogSink(
        directoryProvider: flakyProvider,
        maxBytes: 50,
        maxFiles: 2,
      )..emit(rec('one-$pad'));
      await pumpEventQueue(); // first line written; file now over maxBytes

      failProvider = true;
      sink.emit(rec('two-$pad')); // triggers rotation -> provider throws
      await pumpEventQueue();

      failProvider = false;
      sink.emit(rec('three-$pad')); // sink must reopen and drain the backlog
      await sink.close();

      final written = [
        File(path('bge.log')),
        File(path('bge.1.log')),
        File(path('bge.2.log')),
      ].where((f) => f.existsSync()).map((f) => f.readAsStringSync()).join();
      // The line whose rotation failed is not lost, and recovery wrote too.
      expect(written, contains('two-'));
      expect(written, contains('three-'));
    },
  );
}
