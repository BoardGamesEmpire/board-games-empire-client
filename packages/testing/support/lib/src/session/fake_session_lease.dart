import 'package:interfaces/orchestration.dart';

/// A [SessionLease] whose liveness a test sets by hand (#694).
///
/// Live unless started otherwise. Setting [isLive] to false ends the session
/// as `UserScopeHost` does when its scope closes, so a suite can say what a
/// late outcome does once the session is gone.
class FakeSessionLease implements SessionLease {
  /// Live by default.
  FakeSessionLease({this.isLive = true});

  @override
  bool isLive;
}
