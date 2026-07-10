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

  static Future<Directory> _defaultDirectory() async => Directory(
    '${(await getApplicationSupportDirectory()).path}/feedback_reports',
  );

  @override
  Future<void> persist(FeedbackReport report) async {
    final key = _requireSafeKey(report);
    final dir = await _directoryProvider();
    if (!await dir.exists()) await dir.create(recursive: true);
    await File(
      '${dir.path}/$key.json',
    ).writeAsString(jsonEncode(report.toJson()));
  }

  @override
  Future<List<FeedbackReport>> pending() async {
    final dir = await _directoryProvider();
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
    final dir = await _directoryProvider();
    final file = File('${dir.path}/$correlationKey.json');
    if (await file.exists()) await file.delete();
  }

  /// The correlationKey doubles as the file name, so it must exist and
  /// must not smuggle path segments.
  String _requireSafeKey(FeedbackReport report) {
    final key = report.correlationKey;
    if (key == null || key.isEmpty) {
      throw ArgumentError.value(
        key,
        'report.correlationKey',
        'FileFeedbackSink requires a correlationKey',
      );
    }
    if (key.contains('/') || key.contains(r'\') || key.contains('..')) {
      throw ArgumentError.value(
        key,
        'report.correlationKey',
        'correlationKey must not contain path segments',
      );
    }
    return key;
  }
}
