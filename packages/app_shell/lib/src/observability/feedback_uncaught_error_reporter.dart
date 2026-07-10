import 'package:flutter/foundation.dart';
import 'package:observability/observability.dart';

import 'global_error_hooks.dart';
import 'uncaught_error_record.dart';

/// [UncaughtErrorReporter] backing the alpha "ask each time" flow (#69).
///
/// On each captured crash, builds a draft [FeedbackReport] **at capture
/// time** — so the breadcrumb snapshot reflects the moments *before* the
/// crash; building at approval time (minutes later) would snapshot
/// post-crash noise instead — and publishes it on [pendingCrashReport]
/// for the shell's prompt overlay. The user's comment is woven in at
/// approval via `withUserComment`, which never re-snapshots.
///
/// Privacy contract (#34): this reporter **never submits**. The draft
/// lives in RAM only; submission happens exclusively through the prompt,
/// on explicit approval, via [service].
///
/// Total by construction: the hooks guard reporter throws, but a
/// throwing reporter still burns a warn-level log per crash — a
/// `buildReport` failure is swallowed here (the draft slot stays as it
/// was; capture itself — logging, breadcrumbs, the last-error slot —
/// already happened upstream in the hooks).
///
/// Single slot, newest crash wins — mirroring
/// `ShellObservability.lastUncaughtError`.
final class FeedbackUncaughtErrorReporter implements UncaughtErrorReporter {
  FeedbackUncaughtErrorReporter({required FeedbackService service})
    : _service = service;

  final FeedbackService _service;
  final ValueNotifier<FeedbackReport?> _pending =
      ValueNotifier<FeedbackReport?>(null);

  /// The device-global service, exposed so the prompt wiring can submit
  /// the (comment-woven) draft on approval.
  FeedbackService get service => _service;

  /// The crash draft awaiting the user's decision, or null.
  ValueListenable<FeedbackReport?> get pendingCrashReport => _pending;

  @override
  void report(UncaughtErrorRecord record) {
    try {
      _pending.value = _service.buildReport(
        category: FeedbackCategory.crash,
        severity: FeedbackSeverity.critical,
        title: record.errorType,
        errorMessage: record.message,
        stackTrace: record.stackTrace.toString(),
      );
    } on Object {
      // Total — see class doc.
    }
  }

  /// Empties the draft slot (submitted, or declined), notifying the
  /// prompt overlay.
  void clearPendingCrashReport() => _pending.value = null;
}
