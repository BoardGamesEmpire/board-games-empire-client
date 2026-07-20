import 'dart:async';
import 'dart:convert';

import 'package:observability/observability.dart';
import 'package:test/test.dart';

/// API pinned here (all collaborators injected so the package stays pure
/// Dart and the service stays testable without any platform machinery):
///
/// ```dart
/// FeedbackServiceImpl({
///   required List<Breadcrumb> Function() breadcrumbSource,
///   required FeedbackEnvironment Function() environmentSource,
///   required FeedbackTargetResolver targetResolver,   // #97
///   required FeedbackSink sink,
///   String Function()? correlationKeyGenerator, // default: cuid2
///   BgeLogger? logger,
/// })
/// ```
///
/// #97 semantics pinned:
///
/// - `submit` resolves the target fresh per call. No target / no
///   transport → queue as a [QueuedFeedbackReport] tagged with the
///   target's serverId (null when no server is active). A **transient**
///   transport failure queues, tagged; a **permanent** rejection
///   surfaces un-queued; a sink fault surfaces as
///   [FeedbackPersistenceException] carrying both causes.
/// - `drainPending` gates per record: tagged-for-another-server records
///   are never touched; untagged records drain into the active server.
///   Transient failure (incl. 429) stops the drain; permanent rejection
///   drops the record and continues. Returns the number **sent**.
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
    FeedbackTargetResolver? targetResolver,
    FeedbackSink? sink,
    String Function()? correlationKeyGenerator,
  }) => FeedbackServiceImpl(
    breadcrumbSource: breadcrumbSource ?? () => const [],
    environmentSource: () => environment,
    targetResolver: targetResolver ?? _StaticTargetResolver(null),
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
        targetResolver: _StaticTargetResolver(
          FeedbackTarget(serverId: 'srv-1', transport: transport),
        ),
        sink: sink,
      );
      final r = report(service);

      final result = await service.submit(r);

      expect(result, FeedbackSubmitResult.sent);
      expect(transport.sent, [r]);
      expect(sink.persisted, isEmpty);
    });

    test('queues tagged with the active serverId when the target has no '
        'transport (active but unauthenticated)', () async {
      final sink = _RecordingSink();
      final service = buildService(
        targetResolver: _StaticTargetResolver(
          const FeedbackTarget(serverId: 'srv-1'),
        ),
        sink: sink,
      );
      final r = report(service);

      final result = await service.submit(r);

      expect(result, FeedbackSubmitResult.queued);
      expect(sink.persisted.single.report, r);
      expect(sink.persisted.single.serverId, 'srv-1');
    });

    test('queues untagged when no server is active at all', () async {
      final sink = _RecordingSink();
      final service = buildService(sink: sink);
      final r = report(service);

      final result = await service.submit(r);

      expect(result, FeedbackSubmitResult.queued);
      expect(sink.persisted.single.serverId, isNull);
    });

    test('re-resolves the target on every call — a transport appearing '
        'after a queued submit is used by the next one', () async {
      final transport = _RecordingTransport();
      final resolver = _StaticTargetResolver(
        const FeedbackTarget(serverId: 'srv-1'),
      );
      final sink = _RecordingSink();
      final service = buildService(targetResolver: resolver, sink: sink);
      final r = report(service);

      expect(await service.submit(r), FeedbackSubmitResult.queued);

      resolver.target = FeedbackTarget(serverId: 'srv-1', transport: transport);
      expect(await service.submit(r), FeedbackSubmitResult.sent);
      expect(transport.sent, [r]);
    });

    test('falls back to the sink on a transient transport failure '
        '(offline case), tagged with the serverId', () async {
      final transport = _RecordingTransport(
        error: const FeedbackTransientSubmissionException('network down'),
      );
      final sink = _RecordingSink();
      final service = buildService(
        targetResolver: _StaticTargetResolver(
          FeedbackTarget(serverId: 'srv-1', transport: transport),
        ),
        sink: sink,
      );
      final r = report(service);

      final result = await service.submit(r);

      expect(result, FeedbackSubmitResult.queued);
      expect(sink.persisted.single.report, r);
      expect(sink.persisted.single.serverId, 'srv-1');
    });

    test('queues defensively when a transport leaks an unclassified '
        'error in breach of its contract', () async {
      final transport = _RecordingTransport(error: StateError('leak'));
      final sink = _RecordingSink();
      final service = buildService(
        targetResolver: _StaticTargetResolver(
          FeedbackTarget(serverId: 'srv-1', transport: transport),
        ),
        sink: sink,
      );

      final result = await service.submit(report(service));

      expect(result, FeedbackSubmitResult.queued);
    });

    test('surfaces a permanent rejection to the caller WITHOUT queueing '
        '— retrying can never succeed', () async {
      final transport = _RecordingTransport(
        error: const FeedbackPermanentSubmissionException(
          'rejected',
          statusCode: 403,
        ),
      );
      final sink = _RecordingSink();
      final service = buildService(
        targetResolver: _StaticTargetResolver(
          FeedbackTarget(serverId: 'srv-1', transport: transport),
        ),
        sink: sink,
      );

      await expectLater(
        service.submit(report(service)),
        throwsA(
          isA<FeedbackPermanentSubmissionException>().having(
            (e) => e.statusCode,
            'statusCode',
            403,
          ),
        ),
      );
      expect(sink.persisted, isEmpty);
    });

    test('validates before any I/O — a cap-violating report throws '
        'permanent and never reaches transport or sink', () async {
      final transport = _RecordingTransport();
      final sink = _RecordingSink();
      final service = buildService(
        targetResolver: _StaticTargetResolver(
          FeedbackTarget(serverId: 'srv-1', transport: transport),
        ),
        sink: sink,
      );
      final invalid = FeedbackReport(
        category: FeedbackCategory.bug,
        severity: FeedbackSeverity.low,
        message: 'x' * (FeedbackConstants.maxMessageLength + 1),
      );

      await expectLater(
        service.submit(invalid),
        throwsA(
          // statusCode stays null: the rejection never left the client,
          // and the prompts gate their server-attribution copy on it.
          isA<FeedbackPermanentSubmissionException>().having(
            (e) => e.statusCode,
            'statusCode',
            isNull,
          ),
        ),
      );
      expect(transport.sent, isEmpty);
      expect(sink.persisted, isEmpty);
    });

    test('rejects a report without a correlationKey as permanent before '
        'any I/O — never misclassified as a persistence failure at '
        'queue time', () async {
      final transport = _RecordingTransport();
      final sink = _RecordingSink();
      // No transport resolved, so a keyless report would previously hit
      // the sink, throw ArgumentError there, and surface as a
      // persistence failure.
      final service = buildService(sink: sink);
      const keyless = FeedbackReport(
        category: FeedbackCategory.bug,
        severity: FeedbackSeverity.low,
        message: 'It misbehaved',
      );

      await expectLater(
        service.submit(keyless),
        throwsA(
          isA<FeedbackPermanentSubmissionException>().having(
            (e) => e.statusCode,
            'statusCode',
            isNull,
          ),
        ),
      );
      expect(transport.sent, isEmpty);
      expect(sink.persisted, isEmpty);
    });

    test('rejects a path-unsafe correlationKey as permanent before any '
        'I/O — a durable sink would throw on it at queue time and '
        'masquerade as a persistence failure', () async {
      final sink = _RecordingSink();
      final service = buildService(sink: sink);

      for (final key in <String>['../evil', 'a/b', r'a\b', '..']) {
        final report = FeedbackReport(
          category: FeedbackCategory.bug,
          severity: FeedbackSeverity.low,
          message: 'It misbehaved',
          correlationKey: key,
        );

        await expectLater(
          service.submit(report),
          throwsA(
            isA<FeedbackPermanentSubmissionException>().having(
              (e) => e.statusCode,
              'statusCode',
              isNull,
            ),
          ),
          reason: 'key "$key" must be rejected',
        );
      }
      expect(sink.persisted, isEmpty);
    });

    test('surfaces FeedbackPersistenceException carrying both the sink '
        'fault and the transport cause when both fail', () async {
      final transportError = StateError('network down');
      final sinkError = StateError('disk full');
      final service = buildService(
        targetResolver: _StaticTargetResolver(
          FeedbackTarget(
            serverId: 'srv-1',
            transport: _RecordingTransport(error: transportError),
          ),
        ),
        sink: _RecordingSink(persistError: sinkError),
      );

      await expectLater(
        service.submit(report(buildService())),
        throwsA(
          isA<FeedbackPersistenceException>()
              .having((e) => e.cause, 'cause', same(sinkError))
              .having(
                (e) => e.transportCause,
                'transportCause',
                same(transportError),
              ),
        ),
      );
    });

    test('surfaces FeedbackPersistenceException with a null '
        'transportCause when queueing was the first resort', () async {
      final service = buildService(
        sink: _RecordingSink(persistError: StateError('disk full')),
      );

      await expectLater(
        service.submit(report(buildService())),
        throwsA(
          isA<FeedbackPersistenceException>().having(
            (e) => e.transportCause,
            'transportCause',
            isNull,
          ),
        ),
      );
    });
  });

  group('drainPending', () {
    QueuedFeedbackReport pendingRecord(String key, {String? serverId}) =>
        QueuedFeedbackReport(
          report: FeedbackReport(
            category: FeedbackCategory.bug,
            severity: FeedbackSeverity.low,
            message: 'pending',
            correlationKey: key,
          ),
          serverId: serverId,
        );

    test('sends the active server\'s records and untagged records in '
        'order, removing each on success, and returns the count', () async {
      final transport = _RecordingTransport();
      final sink = _RecordingSink(
        pendingList: [
          pendingRecord('a', serverId: 'srv-1'),
          pendingRecord('b'), // untagged — device-global, drains here
        ],
      );
      final service = buildService(
        targetResolver: _StaticTargetResolver(
          FeedbackTarget(serverId: 'srv-1', transport: transport),
        ),
        sink: sink,
      );

      final sent = await service.drainPending();

      expect(sent, 2);
      expect(transport.sent.map((r) => r.correlationKey), ['a', 'b']);
      expect(sink.removed, ['a', 'b']);
    });

    test('never touches a record tagged for a different server', () async {
      final transport = _RecordingTransport();
      final sink = _RecordingSink(
        pendingList: [
          pendingRecord('other', serverId: 'srv-2'),
          pendingRecord('mine', serverId: 'srv-1'),
        ],
      );
      final service = buildService(
        targetResolver: _StaticTargetResolver(
          FeedbackTarget(serverId: 'srv-1', transport: transport),
        ),
        sink: sink,
      );

      final sent = await service.drainPending();

      expect(sent, 1);
      expect(transport.sent.map((r) => r.correlationKey), ['mine']);
      expect(sink.removed, ['mine']);
    });

    test('stops at the first transient failure (the 429 throttle case), '
        'leaving that record and the rest persisted', () async {
      final transport = _RecordingTransport(
        failOnCall: 2,
        error: const FeedbackTransientSubmissionException(
          'throttled',
          statusCode: 429,
        ),
      );
      final sink = _RecordingSink(
        pendingList: [
          pendingRecord('a', serverId: 'srv-1'),
          pendingRecord('b', serverId: 'srv-1'),
          pendingRecord('c', serverId: 'srv-1'),
        ],
      );
      final service = buildService(
        targetResolver: _StaticTargetResolver(
          FeedbackTarget(serverId: 'srv-1', transport: transport),
        ),
        sink: sink,
      );

      final sent = await service.drainPending();

      expect(sent, 1);
      expect(sink.removed, ['a']);
      expect(transport.sent.map((r) => r.correlationKey), ['a', 'b']);
    });

    test('drops a permanently rejected record and continues — no '
        'un-drainable backlog, and the drop is not counted as '
        'sent', () async {
      final transport = _RecordingTransport(
        failOnCall: 1,
        failOnCallOnly: true,
        error: const FeedbackPermanentSubmissionException(
          'rejected',
          statusCode: 400,
        ),
      );
      final sink = _RecordingSink(
        pendingList: [
          pendingRecord('bad', serverId: 'srv-1'),
          pendingRecord('good', serverId: 'srv-1'),
        ],
      );
      final service = buildService(
        targetResolver: _StaticTargetResolver(
          FeedbackTarget(serverId: 'srv-1', transport: transport),
        ),
        sink: sink,
      );

      final sent = await service.drainPending();

      expect(sent, 1);
      // Both removed: 'bad' as a permanent drop, 'good' as sent.
      expect(sink.removed, ['bad', 'good']);
      expect(transport.sent.map((r) => r.correlationKey), ['bad', 'good']);
    });

    test('a keyless record mid-queue is not removed and does not abort '
        'the drain — belt-and-braces for a sink that did not filter '
        'it', () async {
      final transport = _RecordingTransport();
      final sink = _RecordingSink(
        pendingList: [
          QueuedFeedbackReport(
            report: const FeedbackReport(
              category: FeedbackCategory.bug,
              severity: FeedbackSeverity.low,
              message: 'no key',
            ),
            serverId: 'srv-1',
          ),
          pendingRecord('good', serverId: 'srv-1'),
        ],
      );
      final service = buildService(
        targetResolver: _StaticTargetResolver(
          FeedbackTarget(serverId: 'srv-1', transport: transport),
        ),
        sink: sink,
      );

      final sent = await service.drainPending();

      // Both sent; only the keyed one is removed (the keyless one has
      // no address, but it must not throw the drain to a halt).
      expect(sent, 2);
      expect(sink.removed, ['good']);
      expect(transport.sent.map((r) => r.correlationKey), [null, 'good']);
    });

    test('a removal fault after a successful send is swallowed — the '
        'drain stays best-effort and finishes the queue', () async {
      final transport = _RecordingTransport();
      final sink = _RecordingSink(
        removeError: ArgumentError('unusable key'),
        pendingList: [
          pendingRecord('a', serverId: 'srv-1'),
          pendingRecord('b', serverId: 'srv-1'),
        ],
      );
      final service = buildService(
        targetResolver: _StaticTargetResolver(
          FeedbackTarget(serverId: 'srv-1', transport: transport),
        ),
        sink: sink,
      );

      final sent = await service.drainPending();

      expect(sent, 2);
      expect(transport.sent.map((r) => r.correlationKey), ['a', 'b']);
      expect(sink.removed, isEmpty);
    });

    test('is a no-op without a transport (unauthenticated)', () async {
      final sink = _RecordingSink(
        pendingList: [pendingRecord('a', serverId: 'srv-1')],
      );
      final service = buildService(
        targetResolver: _StaticTargetResolver(
          const FeedbackTarget(serverId: 'srv-1'),
        ),
        sink: sink,
      );

      final sent = await service.drainPending();

      expect(sent, 0);
      expect(sink.removed, isEmpty);
    });

    test('is a no-op without an active server', () async {
      final sink = _RecordingSink(pendingList: [pendingRecord('a')]);
      final service = buildService(sink: sink);

      expect(await service.drainPending(), 0);
    });

    test('overlapping calls coalesce into the in-flight run — no '
        're-POSTs, no double count — and a later call starts '
        'fresh', () async {
      final transport = _GatedTransport();
      final sink = _RecordingSink(
        pendingList: [pendingRecord('a', serverId: 'srv-1')],
      );
      final service = buildService(
        targetResolver: _StaticTargetResolver(
          FeedbackTarget(serverId: 'srv-1', transport: transport),
        ),
        sink: sink,
      );

      final first = service.drainPending();
      final second = service.drainPending();
      transport.release();

      expect(await first, 1);
      expect(await second, 1);
      // One snapshot, one send — not two racing over the same record.
      expect(transport.sent, hasLength(1));

      // After completion the guard resets: a fresh drain runs (and
      // finds nothing left).
      expect(await service.drainPending(), 0);
    });
  });
}

/// Fixed-target resolver; mutate [target] to simulate auth/server
/// transitions between calls.
class _StaticTargetResolver implements FeedbackTargetResolver {
  _StaticTargetResolver(this.target);

  FeedbackTarget? target;

  @override
  FeedbackTarget? resolve() => target;
}

class _RecordingTransport implements FeedbackTransport {
  _RecordingTransport({
    this.error,
    this.failOnCall,
    this.failOnCallOnly = false,
  });

  /// Thrown per [failOnCall] semantics when set.
  final Object? error;

  /// 1-indexed call number to start failing on; null with [error] set
  /// means every call fails.
  final int? failOnCall;

  /// When true, only the [failOnCall]-th call fails (later calls
  /// succeed) — models a single permanently rejected record mid-drain.
  final bool failOnCallOnly;

  final List<FeedbackReport> sent = [];
  var _calls = 0;

  @override
  Future<void> send(FeedbackReport report) async {
    _calls++;
    sent.add(report);
    if (error == null) return;
    final threshold = failOnCall;
    final fails = threshold == null
        ? true
        : failOnCallOnly
        ? _calls == threshold
        : _calls >= threshold;
    if (fails) throw error!;
  }
}

/// Holds every send until [release], so a test can overlap two drains.
class _GatedTransport implements FeedbackTransport {
  final _gate = Completer<void>();
  final List<FeedbackReport> sent = [];

  void release() => _gate.complete();

  @override
  Future<void> send(FeedbackReport report) async {
    sent.add(report);
    await _gate.future;
  }
}

class _RecordingSink implements FeedbackSink {
  _RecordingSink({
    this.persistError,
    this.removeError,
    List<QueuedFeedbackReport>? pendingList,
  }) : _pending = List.of(pendingList ?? const []);

  final Object? persistError;
  final Object? removeError;
  final List<QueuedFeedbackReport> _pending;

  final List<QueuedFeedbackReport> persisted = [];
  final List<String> removed = [];

  @override
  Future<void> persist(QueuedFeedbackReport record) async {
    if (persistError != null) throw persistError!;
    persisted.add(record);
    _pending.add(record);
  }

  @override
  Future<List<QueuedFeedbackReport>> pending() async => List.of(_pending);

  @override
  Future<void> remove(String correlationKey) async {
    if (removeError != null) throw removeError!;
    removed.add(correlationKey);
    _pending.removeWhere((r) => r.correlationKey == correlationKey);
  }
}
