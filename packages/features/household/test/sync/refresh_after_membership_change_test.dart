import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:household/household.dart';

void main() {
  late int refreshes;
  late int afterChanges;
  late HouseholdRefresher refresher;

  setUp(() {
    refreshes = 0;
    afterChanges = 0;
    refresher = HouseholdRefresher(
      () async => refreshes++,
      afterChange: () async => afterChanges++,
    );
  });

  test('runs the pass that starts after any in flight, not one that joins '
      'it: a running pass may have read the list before the change', () async {
    final status = HouseholdHydrationStatus()..started();
    addTearDown(status.close);

    await refreshAfterMembershipChange(refresher, status);

    expect(afterChanges, 1);
    expect(refreshes, 0);
  });

  test('one pass with no status to read', () async {
    await refreshAfterMembershipChange(refresher, null);

    expect(afterChanges, 1);
    expect(refreshes, 0);
  });

  test('marks the cached set stale, so a pass already running cannot stamp '
      'it fresh', () async {
    final status = HouseholdHydrationStatus()
      ..started()
      ..finished(HydrateOutcome.complete);
    addTearDown(status.close);
    expect(status.sinceRefresh, isNotNull);

    unawaited(refreshAfterMembershipChange(refresher, status));
    await Future<void>.delayed(Duration.zero);

    expect(status.sinceRefresh, isNull);
  });
}
