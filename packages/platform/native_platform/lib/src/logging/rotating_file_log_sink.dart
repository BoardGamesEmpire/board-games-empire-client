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
    try {
      final wasEmpty = _pending.isEmpty;
      _pending.add(_formatter.formatLine(record));
      // Bound the pre-open buffer: drop oldest until the file is open.
      while (_sink == null && _pending.length > _preOpenBufferLimit) {
        _pending.removeFirst();
      }
      // Coalesce drains: normally kick one only on the empty->non-empty
      // transition (a drain in flight re-checks _pending as it runs, so a
      // burst no longer chains no-op flushes). ALSO kick when the file is
      // not open and no open is in flight (_sink == null && _openFuture ==
      // null) — the "before first open OR after a failed open" state, where
      // a prior drain reset _openFuture and left _pending non-empty. Without
      // this, coalescing would strand the buffered logs until close(),
      // which production may never reach.
      if (_pending.isNotEmpty &&
          (wasEmpty || (_sink == null && _openFuture == null))) {
        _scheduleDrain();
      }
    } on Object {
      // LogSink.emit must not throw. The async drain is already guarded;
      // this guards the synchronous format/enqueue path (e.g. a throwing
      // custom formatter) so a bad record cannot crash the caller.
    }
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
    try {
      await _openFuture;
    } on Object {
      // A failed open (transient path_provider/filesystem error) must not
      // leave the sink permanently inert: clear the memoised future so a
      // later emit retries. Pending lines stay buffered for that retry; the
      // rethrow is swallowed by _scheduleDrain's catchError.
      _openFuture = null;
      rethrow;
    }
  }

  Future<void> _open() async {
    final dir = await _directoryProvider();
    final file = File('${dir.path}${Platform.pathSeparator}$baseName.log');
    _file = file;
    _currentBytes = await file.exists() ? await file.length() : 0;
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

    // Async filesystem APIs: _rotate runs on the main isolate (inside the
    // serialised drain), so the sync *Sync variants would block frames on
    // slow or networked home directories.
    final oldest = File('$base.$maxFiles.log');
    if (await oldest.exists()) await oldest.delete();
    for (var i = maxFiles - 1; i >= 1; i--) {
      final from = File('$base.$i.log');
      if (await from.exists()) await from.rename('$base.${i + 1}.log');
    }
    final current = _file ?? File('$base.log');
    if (await current.exists()) await current.rename('$base.1.log');

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
