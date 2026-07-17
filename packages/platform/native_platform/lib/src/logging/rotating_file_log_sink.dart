import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:observability/observability.dart';

/// A [LogSink] that appends formatted lines to a size-rotating file set
/// under a platform directory (issue #100) — the desktop persistent log.
///
/// `dart:io` lives here, in a native-only package, so it never reaches a
/// web build. The active file is `<baseName>.log`; on crossing [maxBytes]
/// it rotates `.log` -> `.1.log` -> ... -> `.<maxFiles>.log`, deleting the
/// oldest beyond [maxFiles].
///
/// Opening is lazy: the directory lookup (path_provider) needs the Flutter
/// binding, which is not up when the sink is constructed at the very top
/// of bootstrap, so the first [emit] triggers the async open and records
/// arriving before it lands are held in a bounded in-memory buffer
/// ([preOpenBufferLimit], oldest dropped past the cap). Writes are
/// serialised through a single future chain so rotation and appends never
/// interleave. Every drain flushes, because production has no guaranteed
/// [close] (hot restart does not fire dispose).
class RotatingFileLogSink implements LogSink {
  RotatingFileLogSink({
    required Future<Directory> Function() directoryProvider,
    this.baseName = 'bge',
    this.maxBytes = 1 << 20,
    this.maxFiles = 3,
    LogRecordFormatter formatter = const LogRecordFormatter(),
    int preOpenBufferLimit = 200,
  }) : assert(maxBytes > 0, 'maxBytes must be positive'),
       assert(maxFiles >= 1, 'maxFiles must be at least 1'),
       assert(preOpenBufferLimit >= 0, 'preOpenBufferLimit must be >= 0'),
       _directoryProvider = directoryProvider,
       _formatter = formatter,
       _preOpenBufferLimit = preOpenBufferLimit;

  final Future<Directory> Function() _directoryProvider;
  final String baseName;
  final int maxBytes;
  final int maxFiles;
  final LogRecordFormatter _formatter;
  final int _preOpenBufferLimit;

  final Queue<String> _pending = Queue<String>();
  Future<void> _drain = Future<void>.value();
  Future<void>? _openFuture;
  IOSink? _sink;
  File? _file;
  int _currentBytes = 0;
  bool _closed = false;

  @override
  void emit(LogRecord record) {
    if (_closed) return;
    _pending.add(_formatter.formatLine(record));
    // Bound the pre-open buffer: drop oldest until the file is open.
    while (_sink == null && _pending.length > _preOpenBufferLimit) {
      _pending.removeFirst();
    }
    _scheduleDrain();
  }

  void _scheduleDrain() {
    _drain = _drain.then((_) => _flushPending()).catchError((_) {});
  }

  Future<void> _flushPending() async {
    await _ensureOpen();
    if (_sink == null) return;
    while (_pending.isNotEmpty) {
      final line = _pending.removeFirst();
      final bytes = utf8.encode(line).length + 1;
      if (_currentBytes > 0 && _currentBytes + bytes > maxBytes) {
        await _rotate();
      }
      // Re-read after a possible rotation: _rotate swaps in a fresh sink.
      final sink = _sink;
      if (sink == null) return;
      sink.writeln(line);
      _currentBytes += bytes;
    }
    await _sink?.flush();
  }

  Future<void> _ensureOpen() async {
    if (_sink != null) return;
    _openFuture ??= _open();
    await _openFuture;
  }

  Future<void> _open() async {
    final dir = await _directoryProvider();
    final file = File('${dir.path}${Platform.pathSeparator}$baseName.log');
    _file = file;
    _currentBytes = file.existsSync() ? await file.length() : 0;
    _sink = file.openWrite(mode: FileMode.append);
  }

  Future<void> _rotate() async {
    final open = _sink;
    if (open != null) {
      await open.flush();
      await open.close();
      _sink = null;
    }
    final dir = await _directoryProvider();
    final base = '${dir.path}${Platform.pathSeparator}$baseName';

    final oldest = File('$base.$maxFiles.log');
    if (oldest.existsSync()) oldest.deleteSync();
    for (var i = maxFiles - 1; i >= 1; i--) {
      final from = File('$base.$i.log');
      if (from.existsSync()) from.renameSync('$base.${i + 1}.log');
    }
    final current = _file ?? File('$base.log');
    if (current.existsSync()) current.renameSync('$base.1.log');

    final fresh = File('$base.log');
    _file = fresh;
    _currentBytes = 0;
    _sink = fresh.openWrite(mode: FileMode.append);
  }

  @override
  Future<void> close() async {
    // Stop accepting new records, then let the in-flight chain settle and
    // drain whatever remains. _flushPending intentionally does NOT gate on
    // _closed, so this final flush still writes.
    _closed = true;
    await _drain;
    await _flushPending().catchError((_) {});
    final sink = _sink;
    _sink = null;
    if (sink != null) {
      try {
        await sink.flush();
        await sink.close();
      } on Object {
        // Best-effort flush on teardown.
      }
    }
  }
}
