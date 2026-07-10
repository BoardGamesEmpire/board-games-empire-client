import 'dart:convert';
import 'dart:io';

import 'package:observability/observability.dart';
import 'package:path_provider/path_provider.dart';

/// Durable native [FeedbackSink] (#69): one JSON file per user-approved
/// report, named `<correlationKey>.json`.
///
/// Only user-approved reports reach any sink (the #34 privacy contract is
/// upheld by the approval gate upstream); this class just makes them
/// survive restarts until #37's drain trigger can send them.
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
  Future<void> persist(FeedbackReport report) async {
    final key = _requireSafeKey(
      report.correlationKey,
      source: 'report.correlationKey',
    );
    final dir = await _directory;
    if (!await dir.exists()) await dir.create(recursive: true);
    await File(
      '${dir.path}/$key.json',
    ).writeAsString(jsonEncode(report.toJson()));
  }

  @override
  Future<List<FeedbackReport>> pending() async {
    final dir = await _directory;
    if (!await dir.exists()) return const [];

    // Async list + async reads so draining pending reports never blocks
    // the UI isolate on disk I/O.
    final files = await dir
        .list()
        .where((e) => e is File && e.path.endsWith('.json'))
        .cast<File>()
        .toList();
    files.sort((a, b) => a.path.compareTo(b.path));

    final reports = <FeedbackReport>[];
    for (final file in files) {
      try {
        final decoded =
            jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        reports.add(FeedbackReport.fromJson(decoded));
      } on Object {
        // Skip corrupted files — defensive read, see class doc.
        continue;
      }
    }
    return reports;
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
    if (key.contains('/') || key.contains(r'\') || key.contains('..')) {
      throw ArgumentError.value(
        key,
        source,
        'correlationKey must not contain path segments',
      );
    }
    return key;
  }
}
