import 'package:equatable/equatable.dart';
import 'package:models/domain.dart';

/// Why a test email was not sent.
enum MailTestNotSentReason {
  /// The server has no usable mail settings (409).
  notConfigured,

  /// The server's mail queue is down (503).
  queueUnavailable,

  /// The server refused the caller (403).
  refused,

  /// No usable answer, or any other failure.
  failed,
}

/// States of `MailTestBloc`.
///
/// [attempt] counts the requests the bloc has accepted, so a screen can tell
/// one run's outcome from the last one's.
sealed class MailTestState extends Equatable {
  const MailTestState({required this.attempt});

  final int attempt;

  @override
  List<Object?> get props => [attempt];
}

/// No test is out and no outcome shows: none was requested, or the last
/// one's outcome was retired, which keeps its [attempt].
final class MailTestIdle extends MailTestState {
  const MailTestIdle({super.attempt = 0});
}

/// The test email is being sent.
final class MailTestSending extends MailTestState {
  const MailTestSending({required super.attempt});
}

/// The server queued the email; its result is awaited.
final class MailTestWaiting extends MailTestState {
  const MailTestWaiting({required super.attempt});
}

/// The server reported what became of the email.
final class MailTestOutcome extends MailTestState {
  const MailTestOutcome({
    required super.attempt,
    required this.result,
    this.mayAnswerEarlierTest = false,
  });

  final MailTestResult result;

  /// Whether an earlier test that ran out of time was still owed its result
  /// when this one came. The server's results don't say which test they
  /// answer, so [result] may be that test's.
  final bool mayAnswerEarlierTest;

  @override
  List<Object?> get props => [attempt, result, mayAnswerEarlierTest];
}

/// No result arrived before the deadline. The server may still send one.
final class MailTestNoResult extends MailTestState {
  const MailTestNoResult({required super.attempt});
}

/// The email was not sent.
final class MailTestNotSent extends MailTestState {
  const MailTestNotSent({required super.attempt, required this.reason});

  final MailTestNotSentReason reason;

  @override
  List<Object?> get props => [attempt, reason];
}
