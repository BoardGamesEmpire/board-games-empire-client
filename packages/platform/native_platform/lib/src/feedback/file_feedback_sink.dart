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

  /// `queuedAt` per record **file name**, so the cap does not re-read the
  /// whole directory on every persist.
  ///
  /// Keyed on the name rather than the full path deliberately: [_persist]
  /// builds its path with a `/`, while `Directory.list()` yields a platform
  /// separator — `\` on the Windows desktop target — so a path key written
  /// on one side would never match a lookup from the other, and the cache
  /// would silently never hit while accumulating both spellings.
  ///
  /// Safe as instance state because every reader and writer runs under
  /// [_serialized], and a record's `queuedAt` is fixed for the life of its
  /// path — [_persist] is the only thing that rewrites one, and it updates
  /// this in the same step. Bounded by the cap plus whatever churn one
  /// listing sees, and pruned to the live file set on each enforcement.
  final Map<String, DateTime> _queuedAtCache = {};

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
    // Read before the rename: afterwards the file always exists, and this is
    // what tells a new record from a rewritten one.
    final existed = await File(target).exists();
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

    _queuedAtCache['$key.json'] = record.ageKey;

    // A re-persist replaces a file that was already there — the drain's
    // retry bump is exactly this — so the directory cannot have grown and
    // there is nothing for the cap to do. Skipping spares a full listing on
    // every counted attempt, which in the never-drains deployment this cap
    // exists for is one listing per record per drain.
    if (!existed) {
      // Deliberately after the rename, and deliberately unable to fail: the
      // record is already committed, so surfacing anything from here would
      // have `_queue` report FeedbackPersistenceException — "could not be
      // saved" — about a report that is safely on disk.
      try {
        await _enforceCap(dir, justPersisted: '$key.json');
      } on Object {
        // Best-effort, exactly like _reap. The next persist tries again,
        // and being one record over the cap harms nothing.
      }
    }
  }

  /// Holds the directory at [QueuedFeedbackReport.maxQueuedReports],
  /// deleting oldest-first (#359 **D1**, **D6**).
  ///
  /// Without it, a deployment where nothing can ever drain — a proxy
  /// answering every POST with its own 200 — grows durable files forever on
  /// exactly the machine this sink exists to serve.
  ///
  /// **Ordered by [QueuedFeedbackReport.queuedAt], deliberately not by
  /// mtime**, which [pending] uses for drain order. The two disagree the
  /// moment a record is re-persisted to count a failed attempt (#359
  /// **D4**): the rename restamps the file, so mtime says "just written"
  /// about the record that has been queued longest. A record with no
  /// `queuedAt` sorts at [QueuedFeedbackReport.epoch] — the sentinel both
  /// sinks share — because it predates the field and so really is oldest.
  ///
  /// **A file whose age cannot be DETERMINED is neither evicted nor
  /// counted.** That is the same line [pending] draws and for the same
  /// reason: a filesystem fault is not corruption, and this method
  /// *deletes*. Such a file is excluded from the overflow arithmetic as
  /// well as from the candidates, so a backup or virus scanner holding
  /// handles cannot make this method delete readable reports to compensate
  /// for files it could not open — which would trade a transient lock for
  /// permanent data loss, and at worst empty the directory of everything
  /// still readable. Undecodable *bytes* are a different matter and do
  /// count, sorting oldest; [pending] reaps them anyway.
  ///
  /// Note which property earns the exemption: **unknown age, not
  /// unreadability.** A record this sink wrote itself has a known
  /// `queuedAt` in [_queuedAtCache] and keeps it even if the file later
  /// becomes unreadable, so it still occupies its slot and can still be
  /// evicted once it is genuinely the oldest of a directory that is
  /// genuinely over the cap. That is the policy working rather than an
  /// escape from it — what the exemption protects is the *arithmetic*, and
  /// on a cached record the arithmetic is exact: no readable report is
  /// deleted to pay for a locked one. Re-validating readability before
  /// trusting a cached age would cost a read per file per pass and buy
  /// nothing but a later eviction of the same record.
  ///
  /// The consequence is that enough files of unknown age at once leave the
  /// directory over the cap for that pass. Staying over the cap is the
  /// cheaper error, and the next new record re-tries.
  ///
  /// [justPersisted] is never evicted, so a clock that stepped backwards
  /// cannot have this method delete the record the caller was just told was
  /// saved.
  ///
  /// Runs under the caller's lock — never re-enters [_serialized].
  Future<void> _enforceCap(Directory dir, {String? justPersisted}) async {
    final files = await dir
        .list()
        .where((e) => e is File && e.path.endsWith('.json'))
        .cast<File>()
        .toList();
    if (files.length <= QueuedFeedbackReport.maxQueuedReports) {
      _pruneCache(files);
      return;
    }

    final candidates = <(File, DateTime)>[];
    var readable = 0;
    for (final file in files) {
      final at = await _queuedAt(file);
      // null = unreadable: no opinion, so it neither occupies a slot nor
      // supplies one.
      if (at == null) continue;
      readable++;
      // Counts against the cap, but is not up for deletion.
      if (_nameOf(file) == justPersisted) continue;
      candidates.add((file, at));
    }

    // Measured over the records this sink can actually account for, NOT
    // over every file on disk. Deriving it from the total would charge the
    // unreadable files to the records that CAN be deleted and evict extra
    // readable reports to pay for them — trading a transient lock for
    // permanent data loss, and at worst emptying the directory of
    // everything still readable.
    final excess = readable - QueuedFeedbackReport.maxQueuedReports;
    if (excess <= 0) {
      _pruneCache(files);
      return;
    }

    // Path tie-break keeps eviction deterministic among equal stamps.
    candidates.sort((a, b) {
      final byTime = a.$2.compareTo(b.$2);
      return byTime != 0 ? byTime : a.$1.path.compareTo(b.$1.path);
    });

    for (final (file, _) in candidates.take(excess)) {
      await _reap(file);
    }
    _pruneCache(files);
  }

  /// [QueuedFeedbackReport.queuedAt] for the record in [file],
  /// [QueuedFeedbackReport.epoch] when it has none or cannot be decoded, and
  /// **null when it cannot be read**.
  ///
  /// The null is the important case: it means "no opinion", and
  /// [_enforceCap] keeps such a file out of the arithmetic entirely rather
  /// than assuming the worst about a record that may be perfectly valid.
  ///
  /// Served from [_queuedAtCache] when possible, so the steady state — a
  /// directory sitting at the cap, which is precisely the never-drains
  /// deployment this bound exists for — costs one `list()` and no re-reads.
  Future<DateTime?> _queuedAt(File file) async {
    final name = _nameOf(file);
    final cached = _queuedAtCache[name];
    if (cached != null) return cached;

    final List<int> bytes;
    try {
      bytes = await file.readAsBytes();
    } on FileSystemException {
      // Transient, not corrupt — the same distinction the class doc draws
      // for [pending]. Protect the file rather than evict it.
      return null;
    }

    try {
      final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      final raw = json['queuedAt'];
      final at = raw is String
          ? DateTime.parse(raw)
          : QueuedFeedbackReport.epoch;
      _queuedAtCache[name] = at;
      return at;
    } on Object {
      // Undecodable bytes: sorts oldest, and [pending] reaps it regardless.
      return QueuedFeedbackReport.epoch;
    }
  }

  /// Drops cache entries for records no longer on disk.
  ///
  /// Unconditional: "the cache is no bigger than the directory" would not
  /// imply "nothing in it is stale" — another process sharing the directory
  /// can delete a file this instance still has cached — and because the
  /// cache is normally much smaller than the listing, such a guard would
  /// fire on nearly every call and the prune would never actually run.
  void _pruneCache(List<File> live) {
    final names = {for (final file in live) _nameOf(file)};
    _queuedAtCache.removeWhere((name, _) => !names.contains(name));
  }

  /// The record's file name, which is how [_queuedAtCache] is keyed.
  static String _nameOf(File file) => file.uri.pathSegments.last;

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

    final kept = <(File, QueuedFeedbackReport)>[];
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
      kept.add((file, record));
    }

    // The cap is enforced here as well as on persist, for the install that
    // upgrades into a pre-cap backlog: without this it would stay over the
    // cap indefinitely unless the user happened to submit again, which is
    // exactly what a stalled queue makes unlikely. Records are already
    // decoded at this point, so it costs a sort.
    final excess = kept.length - QueuedFeedbackReport.maxQueuedReports;
    if (excess > 0) {
      final byAge = [...kept]
        ..sort((a, b) {
          // The shared age rule, with a path tie-break this cannot see.
          final byTime = QueuedFeedbackReport.compareByAge(a.$2, b.$2);
          return byTime != 0 ? byTime : a.$1.path.compareTo(b.$1.path);
        });
      final evicted = <String>{};
      for (final (file, _) in byAge.take(excess)) {
        await _reap(file);
        evicted.add(file.path);
      }
      kept.removeWhere((entry) => evicted.contains(entry.$1.path));
    }

    return [for (final (_, record) in kept) record];
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
    _queuedAtCache.remove('$key.json');
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
    _queuedAtCache.remove(_nameOf(file));
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
