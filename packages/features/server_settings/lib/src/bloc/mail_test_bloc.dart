import 'dart:async';

import 'package:bloc_concurrency/bloc_concurrency.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import 'package:server_settings/src/bloc/mail_test_event.dart';
import 'package:server_settings/src/bloc/mail_test_state.dart';

/// Sends a test email and reads the outcome the server delivers as a
/// notification (#807).
///
/// The server queues the mail and answers at once, so the outcome arrives
/// later as an unread `MailTestResult` notification. The bloc notes the
/// results already unread, sends the test, then polls every [pollInterval]
/// until [deadline] for a result that was not among them.
///
/// - **An earlier test may answer.** A result names no test, and a test
///   that ran out of time may still be answered. While one is owed its
///   result, the next outcome comes with
///   [MailTestOutcome.mayAnswerEarlierTest]. A result met in a later
///   baseline pays off a debt like one met in a poll. The count lives as
///   long as the bloc: a test from an earlier visit to the screen is not
///   known.
/// - **No baseline, no send.** If the unread read fails, nothing is sent:
///   an old result could be taken for this test's.
/// - **A poll that fails keeps polling.**
/// - **The outcome is marked read** once emitted. If that fails the outcome
///   stands, and the next test's baseline holds the result.
/// - **A request while one runs is dropped.**
/// - **[MailTestCleared] retires an outcome**, back to [MailTestIdle] at the
///   same attempt. Sent while a test is out, it retires the outcome that test
///   comes to: the bloc still waits for it, and marks it read, but lands at
///   [MailTestIdle]. The test spoke of the settings the edit replaces.
/// - **Closing** stops the polling: no request is sent and nothing emitted
///   after it.
class MailTestBloc extends Bloc<MailTestEvent, MailTestState> {
  MailTestBloc({
    required this._settings,
    required this._notifications,
    Future<void> Function(Duration)? wait,
    this.pollInterval = const Duration(seconds: 5),
    this.deadline = const Duration(minutes: 2),
  }) : _wait = wait ?? Future<void>.delayed,
       super(const MailTestIdle()) {
    on<MailTestRequested>(_onRequested, transformer: droppable());
    // Its own handler, so a running request's droppable() can't drop it.
    on<MailTestCleared>(_onCleared);
  }

  /// How long each poll waits before it is sent.
  final Duration pollInterval;

  /// How long the polls run before the test is said to have no result.
  ///
  /// It counts each wait as its [pollInterval] and each read as long as it
  /// took, so reads that wait out their timeouts use it up too.
  final Duration deadline;

  final SystemSettingsRemoteDataSource _settings;
  final NotificationRemoteDataSource _notifications;
  final Future<void> Function(Duration) _wait;

  int _attempt = 0;

  /// Whether a [MailTestCleared] came while the current test was out.
  bool _retired = false;

  /// The ids of the results this bloc has met, in a baseline or a poll.
  final Set<String> _met = {};

  /// Tests sent whose result this bloc has not met: those that ran out of
  /// time, and the one out now.
  int _owed = 0;

  Future<void> _onRequested(
    MailTestRequested event,
    Emitter<MailTestState> emit,
  ) async {
    final attempt = ++_attempt;
    _retired = false;
    emit(MailTestSending(attempt: attempt));

    final Set<String> baseline;
    try {
      baseline = _resultIds(await _notifications.fetchUnread());
      _meet(baseline);
    } on Object {
      return _emitNotSent(emit, attempt, MailTestNotSentReason.failed);
    }
    if (isClosed) {
      return;
    }

    try {
      await _settings.sendMailTest();
    } on MailNotConfiguredException {
      return _emitNotSent(emit, attempt, MailTestNotSentReason.notConfigured);
    } on MailQueueUnavailableException {
      return _emitNotSent(
        emit,
        attempt,
        MailTestNotSentReason.queueUnavailable,
      );
    } on SystemSettingsForbiddenException {
      return _emitNotSent(emit, attempt, MailTestNotSentReason.refused);
    } on Object {
      return _emitNotSent(emit, attempt, MailTestNotSentReason.failed);
    }
    _owed++;
    if (isClosed) {
      return;
    }

    emit(MailTestWaiting(attempt: attempt));
    var elapsed = Duration.zero;
    while (elapsed < deadline) {
      await _wait(pollInterval);
      elapsed += pollInterval;
      if (isClosed) {
        return;
      }

      final List<UnreadNotification> unread;
      final read = Stopwatch()..start();
      try {
        unread = await _notifications.fetchUnread();
      } on Object {
        continue;
      } finally {
        elapsed += read.elapsed;
      }
      if (isClosed) {
        return;
      }

      for (final notification in unread) {
        final result = MailTestResult.fromNotification(notification);
        if (result == null || baseline.contains(notification.id)) {
          continue;
        }
        final earlierOwed = _owed > 1;
        _meet({notification.id});
        _land(
          emit,
          MailTestOutcome(
            attempt: attempt,
            result: result,
            mayAnswerEarlierTest: earlierOwed,
          ),
        );
        // Not awaited: the outcome has landed and the panel offers another
        // test, which droppable() would drop while this handler still ran.
        unawaited(
          _notifications.markRead([notification.id]).catchError((Object _) {
            // The outcome stands; the next test's baseline holds this result.
          }),
        );
        return;
      }
    }
    if (isClosed) {
      return;
    }
    _land(emit, MailTestNoResult(attempt: attempt));
  }

  void _onCleared(MailTestCleared event, Emitter<MailTestState> emit) {
    final current = state;
    switch (current) {
      case MailTestOutcome() || MailTestNoResult() || MailTestNotSent():
        emit(MailTestIdle(attempt: current.attempt));
      case MailTestSending() || MailTestWaiting():
        _retired = true;
      case MailTestIdle():
        break;
    }
  }

  /// Notes the results among [ids] not met before: each answers a test
  /// still owed one.
  void _meet(Set<String> ids) {
    for (final id in ids) {
      if (_met.add(id) && _owed > 0) _owed--;
    }
  }

  /// Emits what the test came to, or [MailTestIdle] when an edit retired it
  /// while it was out.
  void _land(Emitter<MailTestState> emit, MailTestState end) {
    if (isClosed) return;
    emit(_retired ? MailTestIdle(attempt: end.attempt) : end);
  }

  void _emitNotSent(
    Emitter<MailTestState> emit,
    int attempt,
    MailTestNotSentReason reason,
  ) => _land(emit, MailTestNotSent(attempt: attempt, reason: reason));

  static Set<String> _resultIds(List<UnreadNotification> unread) => {
    for (final n in unread)
      if (MailTestResult.fromNotification(n) != null) n.id,
  };
}
