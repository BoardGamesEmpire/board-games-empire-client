import 'dart:convert';

import 'package:observability/observability.dart';
import 'package:test/test.dart';

/// API pinned here (all collaborators injected as providers so the
/// package stays pure Dart and the service stays testable without any
/// platform machinery):
///
/// ```dart
/// FeedbackServiceImpl({
///   required List<Breadcrumb> Function() breadcrumbSource,
///   required FeedbackEnvironment Function() environmentSource,
///   required FeedbackTransport? Function() transportResolver,
///   required FeedbackSink sink,
///   String Function()? correlationKeyGenerator, // default: cuid2
/// })
/// ```
///
/// - `FeedbackEnvironment` — value of `{appVersion, platform, locale,
///   deviceInfo}` assembled at the composition root (BuildInfo comes
///   from the root container there; observability has no models dep).
/// - `FeedbackTransport` — `Future<void> send(FeedbackReport)`; the
///   resolver returns the active server's transport or null (no active
///   authenticated server). Concrete Dio transport lives in
///   dio_network (stage-2 red).
/// - `FeedbackSink` — `persist` / `pending` / `remove(correlationKey)`;
///   durable local store for user-approved reports that couldn't be
///   sent. Platform concretes are stage-2 red.
/// - `submit` returns `FeedbackSubmitResult.sent` or `.queued` so the
///   prompt can tell the user the truth ("sent" vs "saved, will send
///   later") — a deliberate interface evolution alongside the
///   stackTrace drift fix.
/// - `drainPending()` returns the number sent; the trigger is #37's.
void main() {
  const environment = FeedbackEnvironment(
    appVersion: '1.2.3',
    platform: 'android',
    locale: 'en-US',
    deviceInfo: {'operatingSystem': 'android'},
  );

  Breadcrumb crumb(String message) => Breadcrumb(
    timestamp: DateTime.utc(2026, 7, 9),
    level: BgeLogLevel.info,
    loggerName: 'bge.test',
    message: message,
  );

  int serializedBytes(List<Breadcrumb> crumbs) =>
      utf8.encode(jsonEncode(crumbs.map((c) => c.toJson()).toList())).length;

  FeedbackServiceImpl buildService({
    List<Breadcrumb> Function()? breadcrumbSource,
    FeedbackTransport? Function()? transportResolver,
    FeedbackSink? sink,
    String Function()? correlationKeyGenerator,
  }) => FeedbackServiceImpl(
    breadcrumbSource: breadcrumbSource ?? () => const [],
    environmentSource: () => environment,
    transportResolver: transportResolver ?? () => null,
    sink: sink ?? _RecordingSink(),
    correlationKeyGenerator: correlationKeyGenerator,
  );

  group('buildReport', () {
    test('stamps the environment onto the report', () {
      final report = buildService().buildReport(
        category: FeedbackCategory.bug,
        severity: FeedbackSeverity.low,
        errorMessage: 'It misbehaved',
      );

      expect(report.appVersion, '1.2.3');
      expect(report.platform, 'android');
      expect(report.locale, 'en-US');
      expect(report.deviceInfo, {'operatingSystem': 'android'});
    });

    test('composes message from errorMessage and userComment', () {
      final service = buildService();

      final both = service.buildReport(
        category: FeedbackCategory.crash,
        severity: FeedbackSeverity.critical,
        errorMessage: 'StateError: bad state',
        userComment: 'I was adding a game',
      );
      expect(both.message, contains('StateError: bad state'));
      expect(both.message, contains('I was adding a game'));
      expect(
        both.message.indexOf('StateError'),
        lessThan(both.message.indexOf('I was adding')),
        reason: 'error text leads, user comment follows',
      );

      final errorOnly = service.buildReport(
        category: FeedbackCategory.crash,
        severity: FeedbackSeverity.critical,
        errorMessage: 'StateError: bad state',
      );
      expect(errorOnly.message, 'StateError: bad state');

      final commentOnly = service.buildReport(
        category: FeedbackCategory.featureRequest,
        userComment: 'Please add dark mode',
      );
      expect(commentOnly.message, 'Please add dark mode');
    });

    test('throws ArgumentError when there is nothing to say', () {
      // The model requires a non-empty message; the service surfaces
      // that as a caller contract rather than fabricating filler.
      expect(
        () => buildService().buildReport(
          category: FeedbackCategory.featureRequest,
        ),
        throwsArgumentError,
      );
    });

    test('carries the stack trace on the dedicated field, verbatim when '
        'under the cap', () {
      const trace = '#0 main (file.dart:1)\n#1 run (file.dart:9)';
      final report = buildService().buildReport(
        category: FeedbackCategory.crash,
        severity: FeedbackSeverity.critical,
        errorMessage: 'It broke',
        stackTrace: trace,
      );

      expect(report.stackTrace, trace);
      expect(report.message, isNot(contains('#0 main')));
    });

    test('truncates an over-cap stack trace tail-preserving (head '
        'clipped)', () {
      final head = 'HEAD-${'h' * 100}';
      final tail = '${'t' * 100}-TAIL';
      final trace = head + ('x' * FeedbackConstants.maxStackTraceLength) + tail;

      final report = buildService().buildReport(
        category: FeedbackCategory.crash,
        severity: FeedbackSeverity.critical,
        errorMessage: 'It broke',
        stackTrace: trace,
      );

      final kept = report.stackTrace!;
      expect(kept.length, FeedbackConstants.maxStackTraceLength);
      expect(kept, endsWith(tail));
      expect(kept, isNot(startsWith('HEAD-')));
      expect(report.validate(), isNot(contains(contains('stackTrace'))));
    });

    test('snapshots breadcrumbs at build time — later source mutation '
        'does not change the report', () {
      final backing = <Breadcrumb>[crumb('one'), crumb('two')];
      final service = buildService(breadcrumbSource: () => backing);

      final report = service.buildReport(
        category: FeedbackCategory.bug,
        severity: FeedbackSeverity.low,
        errorMessage: 'It misbehaved',
      );
      backing.add(crumb('three'));

      expect(report.breadcrumbs, hasLength(2));
      expect(report.breadcrumbs.map((c) => c.message), ['one', 'two']);
    });

    test('trims the breadcrumb snapshot oldest-first to the byte cap', () {
      // Ten ~10 KB crumbs — well past the 64 KB serialized cap.
      final backing = List.generate(10, (i) => crumb('crumb-$i${'x' * 10000}'));
      assert(serializedBytes(backing) > FeedbackConstants.maxBreadcrumbsBytes);
      final service = buildService(breadcrumbSource: () => backing);

      final report = service.buildReport(
        category: FeedbackCategory.bug,
        severity: FeedbackSeverity.low,
        errorMessage: 'It misbehaved',
      );

      final kept = report.breadcrumbs;
      expect(kept, isNotEmpty);
      expect(kept.length, lessThan(backing.length));
      expect(
        serializedBytes(kept),
        lessThanOrEqualTo(FeedbackConstants.maxBreadcrumbsBytes),
      );
      // Newest survive: the kept list is the tail of the original.
      expect(
        kept.map((c) => c.message),
        backing.skip(backing.length - kept.length).map((c) => c.message),
      );
      expect(report.validate(), isNot(contains(contains('breadcrumbs'))));
    });

    test('generates a correlationKey when the caller supplies none', () {
      final service = buildService();

      final first = service.buildReport(
        category: FeedbackCategory.bug,
        severity: FeedbackSeverity.low,
        errorMessage: 'It misbehaved',
      );
      final second = service.buildReport(
        category: FeedbackCategory.bug,
        severity: FeedbackSeverity.low,
        errorMessage: 'It misbehaved',
      );

      expect(first.correlationKey, isNotNull);
      expect(first.correlationKey, isNotEmpty);
      expect(first.correlationKey, isNot(second.correlationKey));
    });

    test('uses the injected key generator and preserves a caller key', () {
      final service = buildService(
        correlationKeyGenerator: () => 'generated-key',
      );

      final generated = service.buildReport(
        category: FeedbackCategory.bug,
        severity: FeedbackSeverity.low,
        errorMessage: 'It misbehaved',
      );
      final supplied = service.buildReport(
        category: FeedbackCategory.bug,
        severity: FeedbackSeverity.low,
        errorMessage: 'It misbehaved',
        correlationKey: 'caller-key',
      );

      expect(generated.correlationKey, 'generated-key');
      expect(supplied.correlationKey, 'caller-key');
    });
  });

  group('submit', () {
    FeedbackReport report(FeedbackServiceImpl service) => service.buildReport(
      category: FeedbackCategory.bug,
      severity: FeedbackSeverity.low,
      errorMessage: 'It misbehaved',
    );

    test('sends through the resolved transport and reports sent', () async {
      final transport = _RecordingTransport();
      final sink = _RecordingSink();
      final service = buildService(
        transportResolver: () => transport,
        sink: sink,
      );
      final r = report(service);

      final result = await service.submit(r);

      expect(result, FeedbackSubmitResult.sent);
      expect(transport.sent, [r]);
      expect(sink.persisted, isEmpty);
    });

    test('persists to the sink and reports queued when no transport is '
        'available', () async {
      final sink = _RecordingSink();
      final service = buildService(sink: sink);
      final r = report(service);

      final result = await service.submit(r);

      expect(result, FeedbackSubmitResult.queued);
      expect(sink.persisted, [r]);
    });

    test('falls back to the sink when the transport fails (offline '
        'case) and reports queued', () async {
      final transport = _RecordingTransport(
        error: const FeedbackSubmissionException('network down'),
      );
      final sink = _RecordingSink();
      final service = buildService(
        transportResolver: () => transport,
        sink: sink,
      );
      final r = report(service);

      final result = await service.submit(r);

      expect(result, FeedbackSubmitResult.queued);
      expect(sink.persisted, [r]);
    });

    test('validates before any I/O — a cap-violating report throws and '
        'never reaches transport or sink', () async {
      final transport = _RecordingTransport();
      final sink = _RecordingSink();
      final service = buildService(
        transportResolver: () => transport,
        sink: sink,
      );
      final invalid = FeedbackReport(
        category: FeedbackCategory.bug,
        severity: FeedbackSeverity.low,
        message: 'x' * (FeedbackConstants.maxMessageLength + 1),
      );

      await expectLater(
        service.submit(invalid),
        throwsA(isA<FeedbackSubmissionException>()),
      );
      expect(transport.sent, isEmpty);
      expect(sink.persisted, isEmpty);
    });

    test('surfaces FeedbackSubmissionException when both transport and '
        'sink fail', () async {
      final service = buildService(
        transportResolver: () =>
            _RecordingTransport(error: StateError('network down')),
        sink: _RecordingSink(persistError: StateError('disk full')),
      );
      final r = report(service);

      await expectLater(
        service.submit(r),
        throwsA(isA<FeedbackSubmissionException>()),
      );
    });
  });

  group('drainPending', () {
    FeedbackReport pendingReport(String key) => FeedbackReport(
      category: FeedbackCategory.bug,
      severity: FeedbackSeverity.low,
      message: 'pending',
      correlationKey: key,
    );

    test('sends all pending reports in order, removing each on success, '
        'and returns the count', () async {
      final transport = _RecordingTransport();
      final sink = _RecordingSink(
        pendingList: [pendingReport('a'), pendingReport('b')],
      );
      final service = buildService(
        transportResolver: () => transport,
        sink: sink,
      );

      final sent = await service.drainPending();

      expect(sent, 2);
      expect(transport.sent.map((r) => r.correlationKey), ['a', 'b']);
      expect(sink.removed, ['a', 'b']);
    });

    test('stops at the first failure, leaving that report and the rest '
        'persisted', () async {
      final transport = _RecordingTransport(failOnCall: 2);
      final sink = _RecordingSink(
        pendingList: [
          pendingReport('a'),
          pendingReport('b'),
          pendingReport('c'),
        ],
      );
      final service = buildService(
        transportResolver: () => transport,
        sink: sink,
      );

      final sent = await service.drainPending();

      expect(sent, 1);
      expect(sink.removed, ['a']);
      expect(transport.sent.map((r) => r.correlationKey), ['a', 'b']);
    });

    test('is a no-op without a transport', () async {
      final sink = _RecordingSink(pendingList: [pendingReport('a')]);
      final service = buildService(sink: sink);

      final sent = await service.drainPending();

      expect(sent, 0);
      expect(sink.removed, isEmpty);
    });
  });
}

class _RecordingTransport implements FeedbackTransport {
  _RecordingTransport({this.error, this.failOnCall});

  /// Thrown on every call when set.
  final Object? error;

  /// 1-indexed call number to fail on (subsequent calls also fail).
  final int? failOnCall;

  final List<FeedbackReport> sent = [];
  int _calls = 0;

  @override
  Future<void> send(FeedbackReport report) async {
    _calls++;
    sent.add(report);
    if (error != null) throw error!;
    final failFrom = failOnCall;
    if (failFrom != null && _calls >= failFrom) {
      throw const FeedbackSubmissionException('scripted failure');
    }
  }
}

class _RecordingSink implements FeedbackSink {
  _RecordingSink({List<FeedbackReport>? pendingList, this.persistError})
    : _pending = List.of(pendingList ?? const []);

  final Object? persistError;
  final List<FeedbackReport> _pending;
  final List<FeedbackReport> persisted = [];
  final List<String> removed = [];

  @override
  Future<void> persist(FeedbackReport report) async {
    if (persistError != null) throw persistError!;
    persisted.add(report);
    _pending.add(report);
  }

  @override
  Future<List<FeedbackReport>> pending() async => List.of(_pending);

  @override
  Future<void> remove(String correlationKey) async {
    removed.add(correlationKey);
    _pending.removeWhere((r) => r.correlationKey == correlationKey);
  }
}
