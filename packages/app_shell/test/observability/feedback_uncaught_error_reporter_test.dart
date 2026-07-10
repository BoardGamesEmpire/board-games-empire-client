import 'package:app_shell/app_shell.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:observability/observability.dart';

/// Red-phase tests for `FeedbackUncaughtErrorReporter` (issue #69) — the
/// `UncaughtErrorReporter` backing the alpha "ask each time" flow.
///
/// Semantics pinned:
///
/// - **Draft at capture, not at approval.** `report()` builds the crash
///   `FeedbackReport` immediately via `FeedbackService.buildReport`, so
///   the breadcrumb snapshot reflects the moments *before* the crash —
///   waiting for the user's approval (minutes later) would snapshot
///   post-crash noise instead. The user's comment is woven in at
///   approval time (`withUserComment`), which never re-snapshots.
/// - **Single slot, newest wins** — mirroring
///   `ShellObservability.lastUncaughtError`.
/// - **Never auto-submits.** Privacy contract: submission happens only
///   through the prompt, on explicit approval.
/// - **Total.** The hooks guard reporter throws, but a throwing
///   reporter still burns a warn per crash — buildReport failures are
///   swallowed here.
void main() {
  UncaughtErrorRecord record(String message) => UncaughtErrorRecord.capture(
    StateError(message),
    StackTrace.fromString('#0 main (file.dart:1)'),
  );

  group('FeedbackUncaughtErrorReporter', () {
    test('is an UncaughtErrorReporter', () {
      expect(
        FeedbackUncaughtErrorReporter(service: _FakeFeedbackService()),
        isA<UncaughtErrorReporter>(),
      );
    });

    test('builds a crash draft from the record at capture time and '
        'publishes it', () {
      final service = _FakeFeedbackService();
      final reporter = FeedbackUncaughtErrorReporter(service: service);

      reporter.report(record('bad state'));

      final call = service.buildCalls.single;
      expect(call.category, FeedbackCategory.crash);
      expect(call.severity, FeedbackSeverity.critical);
      expect(call.errorMessage, contains('bad state'));
      expect(call.stackTrace, contains('#0 main (file.dart:1)'));
      expect(call.title, contains('StateError'));

      expect(
        reporter.pendingCrashReport.value,
        same(service.builtReports.single),
      );
    });

    test('is single-slot — a newer crash replaces the pending draft', () {
      final service = _FakeFeedbackService();
      final reporter = FeedbackUncaughtErrorReporter(service: service);

      reporter.report(record('first'));
      reporter.report(record('second'));

      expect(service.buildCalls, hasLength(2));
      expect(
        reporter.pendingCrashReport.value,
        same(service.builtReports.last),
      );
    });

    test('never auto-submits — privacy contract', () {
      final service = _FakeFeedbackService();
      final reporter = FeedbackUncaughtErrorReporter(service: service);

      reporter.report(record('bad state'));

      expect(service.submitted, isEmpty);
    });

    test('swallows a buildReport failure — the reporter stays total '
        'inside the error hooks', () {
      final service = _FakeFeedbackService(
        buildError: StateError('builder bug'),
      );
      final reporter = FeedbackUncaughtErrorReporter(service: service);

      expect(() => reporter.report(record('bad state')), returnsNormally);
      expect(reporter.pendingCrashReport.value, isNull);
    });

    test('clearPendingCrashReport empties the slot and notifies', () {
      final service = _FakeFeedbackService();
      final reporter = FeedbackUncaughtErrorReporter(service: service);
      reporter.report(record('bad state'));

      var notified = false;
      reporter.pendingCrashReport.addListener(() => notified = true);
      reporter.clearPendingCrashReport();

      expect(reporter.pendingCrashReport.value, isNull);
      expect(notified, isTrue);
    });
  });
}

class _BuildCall {
  _BuildCall({
    required this.category,
    this.severity,
    this.title,
    this.errorMessage,
    this.stackTrace,
  });

  final FeedbackCategory category;
  final FeedbackSeverity? severity;
  final String? title;
  final String? errorMessage;
  final String? stackTrace;
}

class _FakeFeedbackService implements FeedbackService {
  _FakeFeedbackService({this.buildError});

  final Object? buildError;
  final List<_BuildCall> buildCalls = [];
  final List<FeedbackReport> builtReports = [];
  final List<FeedbackReport> submitted = [];

  @override
  FeedbackReport buildReport({
    required FeedbackCategory category,
    FeedbackSeverity? severity,
    String? title,
    String? errorMessage,
    String? stackTrace,
    String? userComment,
    String? correlationKey,
  }) {
    if (buildError != null) throw buildError!;
    buildCalls.add(
      _BuildCall(
        category: category,
        severity: severity,
        title: title,
        errorMessage: errorMessage,
        stackTrace: stackTrace,
      ),
    );
    final report = FeedbackReport(
      category: category,
      severity: severity,
      message: errorMessage ?? userComment ?? 'built',
      stackTrace: stackTrace,
      title: title,
      correlationKey: 'built-${buildCalls.length}',
    );
    builtReports.add(report);
    return report;
  }

  @override
  Future<FeedbackSubmitResult> submit(FeedbackReport report) async {
    submitted.add(report);
    return FeedbackSubmitResult.sent;
  }

  @override
  Future<int> drainPending() async => 0;
}
