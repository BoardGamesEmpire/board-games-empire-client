import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:household/household.dart';

void main() {
  late int passes;
  late List<Completer<void>> running;
  late HouseholdRefresher refresher;

  setUp(() {
    passes = 0;
    running = [];
    refresher = HouseholdRefresher(() {
      passes++;
      final pass = Completer<void>();
      running.add(pass);
      return pass.future;
    });
  });

  test('one pass when none was running', () async {
    final status = HouseholdHydrationStatus();
    addTearDown(status.close);

    final done = refreshAfterMembershipChange(refresher, status);
    await Future<void>.delayed(Duration.zero);
    running.single.complete();
    await done;

    expect(passes, 1);
  });

  test('one pass with no status to read', () async {
    final done = refreshAfterMembershipChange(refresher, null);
    await Future<void>.delayed(Duration.zero);
    running.single.complete();
    await done;

    expect(passes, 1);
  });

  test('a second pass, after the first, when one was running: it may have '
      'read the list before the membership change', () async {
    final status = HouseholdHydrationStatus()..started();
    addTearDown(status.close);

    final done = refreshAfterMembershipChange(refresher, status);
    await Future<void>.delayed(Duration.zero);
    expect(passes, 1);

    running.first.complete();
    await Future<void>.delayed(Duration.zero);
    expect(passes, 2);
    running.last.complete();
    await done;

    expect(passes, 2);
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
