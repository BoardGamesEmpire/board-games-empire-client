import 'dart:convert';
import 'dart:io';

import 'package:observability/observability.dart';
import 'package:path_provider/path_provider.dart';

/// Durable native [FeedbackSink] (#69, #97): one JSON file per
/// user-approved record, named `<correlationKey>.json`.
///
/// Only user-approved reports reach any sink (the #34 privacy contract is
/// upheld by the approval gate upstream); this class just makes them
/// survive restarts until the auth-success drain trigger can send them.
///
/// On-disk shape is the [QueuedFeedbackReport] envelope (#97): the report
/// plus the `bgeServerId` it was approved for. Files written by #69 hold
/// a bare [FeedbackReport]; [pending] decodes those as **untagged**
/// records (`serverId: null`) rather than skipping them, so pre-#97
/// queued reports still drain instead of sitting on disk forever.
///
/// [directoryProvider] resolves **lazily at first use**, never at
/// construction — the sink is registered in the root module on the boot
/// hot path, and the production default is a `path_provider` call (a
/// plugin) that must not run there. A read of a directory that was never
/// created reports no pending reports rather than failing; a corrupted
/// file is skipped, not fatal — one bad report must not hide the rest.
class FileFeedbackSink implements FeedbackSink {
  FileFeedbackSink({Future<Directory> Function()? directoryProvider})
    : _directoryProvider = directoryProvider ?? _defaultDirectory;

  final Future<Directory> Function() _directoryProvider;

  /// The resolved reports directory, memoized. `late final` keeps this
  /// lazy — the provider (a `path_provider` plugin call by default) still
  /// does not run at construction (the boot-hot-path guarantee), but once
  /// a method resolves it, the result is reused rather than re-invoking
  /// the plugin on every persist/pending/remove.
  late final Future<Directory> _directory = _directoryProvider();

  static Future<Directory> _defaultDirectory() async => Directory(
    '${(await getApplicationSupportDirectory()).path}/feedback_reports',
  );

  @override
  Future<void> persist(QueuedFeedbackReport record) async {
    final key = _requireSafeKey(
      record.correlationKey,
      source: 'record.report.correlationKey',
    );
    final dir = await _directory;
    if (!await dir.exists()) await dir.create(recursive: true);
    await File(
      '${dir.path}/$key.json',
    ).writeAsString(jsonEncode(record.toJson()));
  }

  @override
  Future<List<QueuedFeedbackReport>> pending() async {
    final dir = await _directory;
    if (!await dir.exists()) return const [];

    // Async list + async reads so draining pending reports never blocks
    // the UI isolate on disk I/O.
    final files = await dir
        .list()
        .where((e) => e is File && e.path.endsWith('.json'))
        .cast<File>()
        .toList();
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
      try {
        final decoded =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        final record = _decodeRecord(decoded);
        // A record we can't key can't be removed after a successful
        // send — drainPending would re-send it every cycle and then
        // throw at removal, aborting the whole drain (a poison record).
        // A decoded key that disagrees with the file name is equally
        // un-removable (remove() deletes `<key>.json`, not this file).
        // Skip both here, the same defensive contract as a corrupt
        // file, so the rest of the queue still drains.
        final key = record.correlationKey;
        final expectedName = key != null && _isSafeKey(key)
            ? '$key.json'
            : null;
        if (expectedName == null ||
            file.uri.pathSegments.last != expectedName) {
          continue;
        }
        records.add(record);
      } on Object {
        // Skip corrupted files — defensive read, see class doc.
        continue;
      }
    }
    return records;
  }

  /// Decodes [json] as a [QueuedFeedbackReport] envelope, falling back to
  /// the legacy bare-[FeedbackReport] shape written by #69, which is
  /// re-wrapped as an **untagged** record (#97 decision: it drains into
  /// the active server rather than being stranded). A map that is
  /// neither throws, and the caller skips the file as corrupt.
  QueuedFeedbackReport _decodeRecord(Map<String, dynamic> json) {
    // Envelope-first: the legacy shape has no 'report' key, and the
    // envelope decode of a legacy map throws on the missing required
    // field — so the key check just avoids exception-driven control flow
    // on every legacy file.
    if (json.containsKey('report')) return QueuedFeedbackReport.fromJson(json);
    return QueuedFeedbackReport(report: FeedbackReport.fromJson(json));
  }

  @override
  Future<void> remove(String correlationKey) async {
    // Validate before constructing the path: the key is interpolated
    // into a file name, so a crafted `..`/separator key must not be able
    // to traverse out of the reports directory and delete an arbitrary
    // file. Same guard persist() applies. Use the validated return so
    // the path can't diverge from what was checked if the guard ever
    // normalizes the key.
    final key = _requireSafeKey(correlationKey, source: 'correlationKey');
    final dir = await _directory;
    final file = File('${dir.path}/$key.json');
    if (await file.exists()) await file.delete();
  }

  /// Validates that [key] is present and safe to use as a file name — it
  /// doubles as the report's file name, so it must exist and must not
  /// smuggle path segments that could traverse out of the reports
  /// directory. Shared by [persist] (the report's correlationKey) and
  /// [remove] (a caller-supplied key).
  String _requireSafeKey(String? key, {required String source}) {
    if (key == null || key.isEmpty) {
      throw ArgumentError.value(
        key,
        source,
        'FileFeedbackSink requires a correlationKey',
      );
    }
    if (!_isSafeKey(key)) {
      throw ArgumentError.value(
        key,
        source,
        'correlationKey must not contain path segments',
      );
    }
    return key;
  }

  /// Whether [key] is a present, non-empty, traversal-free file-name
  /// key. The read-side counterpart to [_requireSafeKey]'s throw: a
  /// record whose decoded key is null/empty/unsafe can never be removed
  /// (remove() would throw on it), so [pending] must not emit it — see
  /// the filter there.
  static bool _isSafeKey(String? key) =>
      key != null &&
      key.isNotEmpty &&
      !key.contains('/') &&
      !key.contains(r'\') &&
      !key.contains('..');
}
