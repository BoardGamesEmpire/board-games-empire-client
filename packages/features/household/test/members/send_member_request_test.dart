import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:household/src/bloc/household_member_actions_state.dart';
import 'package:household/src/members/send_member_request.dart';
import 'package:mocktail/mocktail.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

class MockBgeLogger extends Mock implements BgeLogger {}

const _gone = HouseholdMemberRefusedException('gone', statusCode: 404);
const _bad = HouseholdMemberRefusedException('bad', statusCode: 400);
const _offline = HouseholdMemberTransientException('down');

void main() {
  late MockBgeLogger logger;
  late List<String> calls;

  setUp(() {
    logger = MockBgeLogger();
    calls = [];
  });

  Future<MemberRequestOutcome> run({
    Future<String> Function()? send,
    Future<void> Function(String answer)? cache,
    Future<void> Function()? refresh,
    void Function(String answer)? accepted,
  }) => sendMemberRequest<String>(
    action: 'remove',
    send:
        send ??
        () async {
          calls.add('send');
          return 'answer';
        },
    cache:
        cache ??
        (answer) async {
          calls.add('cache($answer)');
        },
    refresh:
        refresh ??
        () async {
          calls.add('refresh');
        },
    accepted: accepted,
    logger: logger,
  );

  test('a 200 caches the answer, then refreshes, and is done', () async {
    final outcome = await run();
    expect(calls, ['send', 'cache(answer)', 'refresh']);
    expect(outcome.result, HouseholdMemberActionResult.done);
    expect(outcome.error, isNull);
  });

  test('accepted runs before the cache write', () async {
    await run(accepted: (answer) => calls.add('accepted($answer)'));
    expect(calls, ['send', 'accepted(answer)', 'cache(answer)', 'refresh']);
  });

  test('an accepted that throws is still done, cached and refreshed', () async {
    final outcome = await run(accepted: (_) => throw StateError('ui'));
    expect(outcome.result, HouseholdMemberActionResult.done);
    expect(outcome.error, isNull);
    expect(calls, ['send', 'cache(answer)', 'refresh']);
  });

  test('an enveloped 404 is gone and refreshes', () async {
    final outcome = await run(send: () async => throw _gone);
    expect(outcome.result, HouseholdMemberActionResult.gone);
    expect(outcome.error, _gone);
    expect(calls, ['refresh']);
  });

  test('an enveloped 400 is refused and refreshes', () async {
    final outcome = await run(send: () async => throw _bad);
    expect(outcome.result, HouseholdMemberActionResult.refused);
    expect(outcome.error, _bad);
    expect(calls, ['refresh']);
  });

  test('a transient failure is failed and starts no refresh', () async {
    final outcome = await run(send: () async => throw _offline);
    expect(outcome.result, HouseholdMemberActionResult.failed);
    expect(outcome.error, _offline);
    expect(calls, isEmpty);
    verify(
      () => logger.warn(
        'Household member remove got no answer',
        error: _offline,
        stackTrace: any(named: 'stackTrace'),
      ),
    ).called(1);
  });

  test('any other throw is failed and refreshes', () async {
    final boom = StateError('boom');
    final outcome = await run(send: () async => throw boom);
    expect(outcome.result, HouseholdMemberActionResult.failed);
    expect(outcome.error, boom);
    expect(calls, ['refresh']);
  });

  test('a cache write that throws is still done', () async {
    final outcome = await run(cache: (_) async => throw StateError('disk'));
    expect(outcome.result, HouseholdMemberActionResult.done);
    expect(outcome.error, isNull);
    expect(calls, ['send', 'refresh']);
  });

  test('a refresh that throws is swallowed', () async {
    final outcome = await run(refresh: () async => throw StateError('late'));
    await Future<void>.delayed(Duration.zero);
    expect(outcome.result, HouseholdMemberActionResult.done);
  });

  test('the refresh is started, not awaited', () async {
    final refresh = Completer<void>();
    var started = false;
    final outcome = await run(
      refresh: () {
        started = true;
        return refresh.future;
      },
    ).timeout(const Duration(seconds: 1));
    expect(started, isTrue);
    expect(refresh.isCompleted, isFalse);
    expect(outcome.result, HouseholdMemberActionResult.done);
    expect(outcome.error, isNull);
  });
}
