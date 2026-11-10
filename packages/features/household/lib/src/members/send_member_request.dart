import 'dart:async';

import 'package:household/src/bloc/household_member_actions_state.dart';
import 'package:network_interface/network_interface.dart';
import 'package:observability/observability.dart';

/// How a member request ended: the result, and what it failed with. The
/// error is null when it was done.
typedef MemberRequestOutcome = ({
  HouseholdMemberActionResult result,
  Object? error,
});

/// Sends [send], caches a 200's answer, and starts the refresh the answer
/// calls for (#480, #479). Answers how it ended. Never throws.
///
/// Nothing goes through the sync queue and no row is marked dirty (#122).
/// The rules, by answer:
///
/// - A 200 calls [accepted] if given, synchronously (a throw is logged), then
///   writes the answer with [cache], then starts [refresh]. The outcome is
///   done, even when the cache write throws: the server made the change, and
///   the refresh brings it.
/// - An enveloped 404 is gone, and any other refusal is refused. Both start
///   [refresh]; neither touches the cache.
/// - A transient failure is failed, and starts no refresh.
/// - Anything else is failed, and starts a refresh, since the server may have
///   made a change this device could not read.
///
/// [refresh] is started, never awaited. If it throws, that is logged and
/// swallowed. [action] only words the log messages.
Future<MemberRequestOutcome> sendMemberRequest<T>({
  required String action,
  required Future<T> Function() send,
  required Future<void> Function(T answer) cache,
  required Future<void> Function() refresh,
  required BgeLogger logger,
  void Function(T answer)? accepted,
}) async {
  void startRefresh() => unawaited(_runRefresh(refresh, logger));

  final T answer;
  try {
    answer = await send();
  } on HouseholdMemberRefusedException catch (error) {
    startRefresh();
    return (
      result: error.statusCode == 404
          ? HouseholdMemberActionResult.gone
          : HouseholdMemberActionResult.refused,
      error: error,
    );
  } on HouseholdMemberTransientException catch (error, stackTrace) {
    // Nothing is written here and no refresh starts (#122). The server
    // may have made the change before the answer was lost, and the next
    // hydrate brings it if so.
    logger.warn(
      'Household member $action got no answer',
      error: error,
      stackTrace: stackTrace,
    );
    return (result: HouseholdMemberActionResult.failed, error: error);
  } on Object catch (error, stackTrace) {
    logger.warn(
      'Household member $action failed',
      error: error,
      stackTrace: stackTrace,
    );
    startRefresh();
    return (result: HouseholdMemberActionResult.failed, error: error);
  }

  try {
    accepted?.call(answer);
  } on Object catch (error, stackTrace) {
    // The server made the change, so the cache write and the refresh still
    // run.
    logger.warn(
      'Household member $action done, but its acceptance callback failed',
      error: error,
      stackTrace: stackTrace,
    );
  }
  try {
    await cache(answer);
  } on Object catch (error, stackTrace) {
    // The server made the change, and the refresh brings it.
    logger.warn(
      'Household member $action done, but its answer was not cached',
      error: error,
      stackTrace: stackTrace,
    );
  }
  startRefresh();
  return (result: HouseholdMemberActionResult.done, error: null);
}

Future<void> _runRefresh(
  Future<void> Function() refresh,
  BgeLogger logger,
) async {
  try {
    await refresh();
  } on Object catch (error, stackTrace) {
    logger.warn(
      'Household refresh after a member change failed',
      error: error,
      stackTrace: stackTrace,
    );
  }
}
