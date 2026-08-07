import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:observability/observability.dart';
import 'package:path_provider/path_provider.dart';

/// Durable native [FeedbackSink] (#69, #97): one JSON file per
/// user-approved record, named `<storageKey>.json`.
///
/// Only user-approved reports reach any sink (the #34 privacy contract is
/// upheld by the approval gate upstream); this class just makes them
/// survive restarts until the auth-success drain trigger can send them.
///
/// On-disk shape is the [QueuedFeedbackReport] envelope (#97): the report
/// plus the `bgeServerId` it was approved for.
///
/// [directoryProvider] resolves **lazily at first use**, never at
/// construction — the sink is registered in the root module on the boot
/// hot path, and the production default is a `path_provider` call (a
/// plugin) that must not run there. A read of a directory that was never
/// created reports no pending reports rather than failing.
///
/// ## Writes are atomic
///
/// [persist] writes a temp file and renames it onto the final name;
/// `rename` is atomic on every platform this sink targets, so a reader can
/// only ever observe a complete file. The temp name is unique per call, so
/// two overlapping persists of the same record cannot collide on it.
///
/// This is load-bearing for the reap below (#161). Under a non-atomic
/// write, a [persist] racing a [pending] — entirely plausible, since the
/// drain trigger fires on auth success while the user may be submitting —
/// would expose a truncated file that the reap would then delete,
/// destroying a report the user had just approved. It also means a crash
/// mid-write leaves a stale temp rather than a corrupt `.json`; [pending]
/// reclaims those once they are too old to belong to a live write.
///
/// ## Un-drainable records are reaped, not skipped (#161)
///
/// [pending] **deletes** a record it declines to emit. Every rejection
/// reason makes the record permanently un-[remove]able — [remove]
/// addresses `<storageKey>.json`, so a record with no usable key, or one
/// whose key disagrees with the file it came from, has no address a drain
/// could clear. Skipping without deleting leaves the file on disk for the
/// life of the install.
///
/// This is what makes the #161 "drop, don't migrate" decision true rather
/// than merely intended. A record written before that rename carries its
/// idempotency token under the old field name; the current decoder does
/// not read that name and json_serializable ignores unrecognised keys, so
/// such a record decodes *successfully* with a null
/// [QueuedFeedbackReport.storageKey]. Without the reap it would be
/// silently stranded — never sent, never dropped — instead of discarded.
///
/// One deliberate exception: a **filesystem** fault reading a file is not
/// corruption. A locked or momentarily unreadable file is skipped and
/// retried on the next [pending] call, never deleted.
///
/// Telling that apart from bad data requires reading raw bytes rather than
/// calling `readAsString`. The async `readAsString` hands decoding to the
/// IO service, which reports malformed input as a `FileSystemException` —
/// the same type as a real read fault. Under that API the two are
/// indistinguishable, so malformed bytes would be retried forever instead
/// of reaped, leaking a file that can never decode. [pending] therefore
/// reads bytes and decodes in Dart, where a `FormatException` from
/// `utf8.decode` is unambiguous.
///
/// ## Operations are serialized
///
/// [persist], [pending], and [remove] run one at a time. Every one of them
/// acts on a *pathname* after an `await`, so interleaving turns each into a
/// time-of-check/time-of-use race that loses an approved report:
///
/// - [pending] reads a file that fails to decode, a [persist] for that same
///   storage key renames a fresh valid record onto the path, and the reap
///   deletes the new report instead of the bytes that failed.
/// - [remove] confirms `<storageKey>.json` exists and then deletes it; a
///   [persist] landing in between loses the newly queued copy rather than
///   the record that was just drained.
///
/// Re-checking before acting (re-stat, re-decode) only narrows those
/// windows. Serializing closes them, and the cost is low: each operation
/// touches a handful of small files.
///
/// The lock is per-instance, so it does not order this sink against another
/// process sharing the directory. Nothing else does either — the unique
/// temp name and the atomic rename are what keep that case safe.
class FileFeedbackSink implements FeedbackSink {
  FileFeedbackSink({Future<Directory> Function()? directoryProvider})
    : _directoryProvider = directoryProvider ?? _defaultDirectory;

  final Future<Directory> Function() _directoryProvider;

  /// Suffix of the in-progress write target. Never ends in `.json`, so an
  /// in-flight or crash-orphaned temp can never be mistaken for a record.
  static const String _tempSuffix = '.tmp';

  /// A temp older than this cannot belong to a live write — a persist takes
  /// milliseconds — so [pending] reclaims it.
  ///
  /// Deliberately far longer than any plausible write, because the cost of
  /// the two errors is wildly asymmetric: reaping too eagerly breaks an
  /// in-flight persist and loses an approved report, while reaping too
  /// lazily just defers reclaiming a dead file.
  static const Duration _staleTempAge = Duration(hours: 1);

  /// Distinguishes concurrent writes to the same storage key.
  ///
  /// Two overlapping persists of one record — a resubmission racing a send
  /// that is still in flight, where both fall back to the queue — would
  /// otherwise share a temp path: the first rename moves the shared temp,
  /// the second then fails on a file that is no longer there, and `_queue`
  /// reports [FeedbackPersistenceException] for a record that is in fact
  /// safely queued. Worse, either cleanup path can delete the other
  /// writer's file.
  ///
  /// An isolate-local counter suffices. The collision being prevented is
  /// between two calls on this instance, and a temp left behind by an
  /// earlier process is an orphan nothing depends on — overwriting or
  /// reaping it is harmless.
  int _tempSequence = 0;

  /// The resolved reports directory, memoized. `late final` keeps this
  /// lazy — the provider (a `path_provider` plugin call by default) still
  /// does not run at construction (the boot-hot-path guarantee), but once
  /// a method resolves it, the result is reused rather than re-invoking
  /// the plugin on every persist/pending/remove.
  late final Future<Directory> _directory = _directoryProvider();

  static Future<Directory> _defaultDirectory() async => Directory(
    '${(await getApplicationSupportDirectory()).path}/feedback_reports',
  );

  /// Serializes this sink's filesystem work; see the class doc.
  ///
  /// Held only for the duration of one operation, and never acquired
  /// re-entrantly (no operation calls another), so it cannot deadlock. The
  /// completer is always completed in a `finally`, and never with an error,
  /// so a failing operation releases the lock and surfaces its own error.
  Future<void> _mutex = Future<void>.value();

  Future<T> _serialized<T>(Future<T> Function() action) async {
    final previous = _mutex;
    final completer = Completer<void>();
    _mutex = completer.future;
    await previous;
    try {
      return await action();
    } finally {
      completer.complete();
    }
  }

  @override
  Future<void> persist(QueuedFeedbackReport record) =>
      _serialized(() => _persist(record));

  Future<void> _persist(QueuedFeedbackReport record) async {
    final key = _requireSafeKey(
      record.storageKey,
      source: 'record.report.clientRequestId',
    );
    final dir = await _directory;
    if (!await dir.exists()) await dir.create(recursive: true);

    // Write-then-rename so no reader ever sees a partial record. `flush`
    // because the point of this sink is surviving a restart, including
    // one that wasn't graceful.
    final target = '${dir.path}/$key.json';
    final temp = File('$target.${_tempSequence++}$_tempSuffix');
    try {
      await temp.writeAsString(jsonEncode(record.toJson()), flush: true);
      await temp.rename(target);
    } on Object {
      // Clean up after ourselves rather than leaving it for the
      // age-based reclaim in pending(): this temp is known-dead now, and
      // the threshold there is deliberately an hour.
      try {
        if (await temp.exists()) await temp.delete();
      } on FileSystemException {
        // Swallowed: the original failure is the informative one, and
        // rethrowing this instead would misattribute the cause.
      }
      rethrow;
    }
  }

  @override
  Future<List<QueuedFeedbackReport>> pending() => _serialized(_pending);

  Future<List<QueuedFeedbackReport>> _pending() async {
    final dir = await _directory;
    if (!await dir.exists()) return const [];

    // Async list + async reads so draining pending reports never blocks
    // the UI isolate on disk I/O.
    final entries = await dir
        .list()
        .where((e) => e is File)
        .cast<File>()
        .toList();

    // Records are `.json`; temps are not, so the two can never be
    // confused. A temp is reclaimed only once it is too old to belong to a
    // live write — deleting a mid-flight one would break that persist,
    // and this method cannot otherwise tell the two apart. Age is the only
    // available discriminator, and it has to be applied: every abandoned
    // temp has a distinct name, so "never reclaimed" means unbounded
    // growth on precisely the machine that crashes, which is the machine
    // this sink exists to serve.
    final files = <File>[];
    for (final entry in entries) {
      if (entry.path.endsWith(_tempSuffix)) {
        // Under the lock no persist of *this* sink can be mid-write, so a
        // temp seen here is either abandoned or owned by another process.
        // Age is what separates those.
        final modified = (await entry.stat()).modified;
        if (DateTime.now().difference(modified) > _staleTempAge) {
          await _reap(entry);
        }
        continue;
      }
      if (entry.path.endsWith('.json')) files.add(entry);
    }

    // Oldest-first by write time, matching the MemoryFeedbackSink
    // contract, so a throttle-stopped drain (#97) sends the oldest
    // records rather than an arbitrary cuid2-lexical prefix. Path
    // tie-break keeps the order deterministic within the filesystem's
    // mtime resolution. Note one deliberate nuance vs the memory sink:
    // re-persisting an existing key rewrites the file, so the record
    // re-queues as newest.
    final stamped = <(File, DateTime)>[
      for (final file in files) (file, (await file.stat()).modified),
    ];
    stamped.sort((a, b) {
      final byTime = a.$2.compareTo(b.$2);
      return byTime != 0 ? byTime : a.$1.path.compareTo(b.$1.path);
    });

    final records = <QueuedFeedbackReport>[];
    for (final (file, _) in stamped) {
      // Bytes, not readAsString: the async readAsString hands decoding to
      // the IO service, which reports malformed input as a
      // FileSystemException — indistinguishable from a genuine read fault,
      // so a permanently-undecodable file would be retried forever instead
      // of reaped. Reading raw and decoding here keeps the two classes
      // separable: a FileSystemException from readAsBytes is a real I/O
      // fault, and every data fault surfaces from the decode below.
      final List<int> bytes;
      try {
        bytes = await file.readAsBytes();
      } on FileSystemException {
        // Transient, not corrupt — see the class doc. Skip without
        // reaping so a locked or briefly unreadable file survives to be
        // read on the next call.
        continue;
      }

      final QueuedFeedbackReport record;
      try {
        record = QueuedFeedbackReport.fromJson(
          jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>,
        );
      } on Object {
        // Not valid persisted state: bytes that are not UTF-8
        // (utf8.decode defaults to allowMalformed: false), malformed
        // JSON, a non-object, or a shape this decoder cannot satisfy
        // (including the pre-#97 bare-report shape, whose compatibility
        // path was removed with #161). None of it can ever drain, and
        // atomic writes rule out the benign truncated-file explanation,
        // so reap it.
        await _reap(file);
        continue;
      }

      final key = record.storageKey;
      final expectedName = _isSafeKey(key) ? '$key.json' : null;
      if (expectedName == null || file.uri.pathSegments.last != expectedName) {
        // Un-addressable. Either no usable storage key — which is how
        // every pre-#161 record now presents, its token having been
        // written under a field name this decoder does not read — or a
        // key that disagrees with the file it was read from, which
        // remove() would not target. Both would re-send on every drain
        // and then fail at removal, so reap rather than skip.
        await _reap(file);
        continue;
      }
      records.add(record);
    }
    return records;
  }

  @override
  Future<void> remove(String storageKey) =>
      _serialized(() => _remove(storageKey));

  Future<void> _remove(String storageKey) async {
    // Validate before constructing the path: the key is interpolated
    // into a file name, so a crafted `..`/separator key must not be able
    // to traverse out of the reports directory and delete an arbitrary
    // file. Same guard persist() applies. Use the validated return so
    // the path can't diverge from what was checked if the guard ever
    // normalizes the key.
    final key = _requireSafeKey(storageKey, source: 'storageKey');
    final dir = await _directory;
    final file = File('${dir.path}/$key.json');
    if (await file.exists()) await file.delete();
  }

  /// Discards an un-drainable record.
  ///
  /// Deletes the [File] that was actually listed and read — never a path
  /// rebuilt from a decoded key — so an unsafe key can never steer the
  /// delete out of the reports directory. That distinction matters here
  /// in a way it does not in [remove]: a key reaching this point has
  /// already failed validation.
  ///
  /// Best-effort. A reap that fails leaves the file for the next
  /// [pending] to try again, which is exactly the pre-#161 behaviour and
  /// so no worse than it; letting the failure escape would instead abort
  /// the whole drain over a file that is already worthless.
  Future<void> _reap(File file) async {
    try {
      await file.delete();
    } on FileSystemException {
      // Swallowed deliberately — see above.
    }
  }

  /// Validates that [key] is present and safe to use as a file name — it
  /// doubles as the record's file name, so it must exist and must not
  /// smuggle path segments that could traverse out of the reports
  /// directory. Shared by [persist] (the record's storage key) and
  /// [remove] (a caller-supplied key).
  String _requireSafeKey(String? key, {required String source}) {
    if (key == null || key.isEmpty) {
      throw ArgumentError.value(
        key,
        source,
        'FileFeedbackSink requires a storage key',
      );
    }
    if (!_isSafeKey(key)) {
      throw ArgumentError.value(
        key,
        source,
        'storage key must not contain path segments',
      );
    }
    return key;
  }

  /// Whether [key] is a present, non-empty, traversal-free file-name
  /// key. The read-side counterpart to [_requireSafeKey]'s throw: a
  /// record whose decoded key is null/empty/unsafe can never be removed
  /// (remove() would throw on it), so [pending] must not emit it — it
  /// reaps it instead.
  static bool _isSafeKey(String? key) =>
      key != null &&
      key.isNotEmpty &&
      !key.contains('/') &&
      !key.contains(r'\') &&
      !key.contains('..');
}
