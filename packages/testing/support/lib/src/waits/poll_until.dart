import 'dart:async';

/// Checks [condition] every 10 ms until it holds, and throws a
/// [TimeoutException] with what [describe] says after [timeout].
///
/// For a state a root reaches after the call that started it returns, with
/// no stream or status that reports it, such as the caller access answer.
/// [describe] runs only on the timeout, so it can name what the state was
/// instead.
///
/// The deadline also bounds a check still pending, such as a read on a
/// database that never answers, so that too fails with [describe] rather than
/// at the runner's limit.
Future<void> pollUntil(
  FutureOr<bool> Function() condition, {
  required String Function() describe,
  Duration timeout = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(timeout);
  Never timedOut() => throw TimeoutException(describe(), timeout);
  while (true) {
    final remaining = deadline.difference(DateTime.now());
    final holds = await Future.sync(condition).timeout(
      remaining.isNegative ? Duration.zero : remaining,
      onTimeout: timedOut,
    );
    if (holds) return;
    if (DateTime.now().isAfter(deadline)) timedOut();
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
