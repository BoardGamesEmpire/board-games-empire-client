// The lease for compositions with no user-session scope (#694). The scoped
// lease, which ends, is tested with `UserScopeHost` in `core/di`.

import 'package:interfaces/orchestration.dart';
import 'package:test/test.dart';

void main() {
  test('the unscoped lease is always live', () {
    const SessionLease lease = UnscopedSessionLease();

    expect(lease.isLive, isTrue);
  });
}
