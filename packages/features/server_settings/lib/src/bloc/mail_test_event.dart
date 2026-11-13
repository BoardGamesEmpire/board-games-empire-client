/// Events of `MailTestBloc`.
sealed class MailTestEvent {
  const MailTestEvent();
}

/// Send a test email and read its outcome (#807).
final class MailTestRequested extends MailTestEvent {
  const MailTestRequested();
}

/// Retire the last test's outcome, as when the settings it answered for are
/// edited (#807). Ignored while a test is out.
final class MailTestCleared extends MailTestEvent {
  const MailTestCleared();
}
