import 'dart:async';

import 'package:app_shell/app_shell.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household/household.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:interfaces/orchestration.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';

import '../support/active_server_fakes.dart';

class _MockAppBootstrapCubit extends MockCubit<AppBootstrapState>
    implements AppBootstrapCubit {}

class _MockStorage extends Mock implements Storage {}

class _MockHouseholdRepository extends Mock implements HouseholdRepository {}

/// Counts passes without running any. Registration is a no-op: what these
/// tests check is who *calls* the seam, not what it holds.
class _RecordingRehydrator implements SessionRehydrator {
  int passes = 0;

  @override
  void register(
    String key, {
    required bool Function() isStale,
    required Future<void> Function() run,
  }) {}

  @override
  Future<void> rehydrateStale() async => passes++;
}

const _id = 'hh_1';

Household _household(String id) => Household(
  id: id,
  name: 'Sunday Crew',
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

HouseholdMember _member(String userId) => HouseholdMember(
  id: 'm-$userId',
  userId: userId,
  householdId: _id,
  role: HouseholdRole.householdOwner,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

/// Exercises #300's two screen-facing seams through the real composition:
/// the **retry** (D5, D10) — route builders resolving [HouseholdRefresher]
/// off the active server's container, and the banner button reaching it —
/// and the **entry trigger** (D1, D13, D14), which resolves
/// [SessionRehydrator] from the same container instead.
///
/// Two seams and not one, deliberately. D5 rejected the rehydrator for the
/// button because it skips an entry a pass is already running for (#302
/// D4), which is right for a trigger nobody pressed and wrong for a control
/// someone is waiting on. These tests are where that split is visible.
///
/// The screens' own behaviour is pinned in the household package; what can
/// only be checked here is that the callbacks the screens are handed are the
/// ones the session actually registered — and that a container without them
/// still renders a working screen (#137).
void main() {
  late _MockAppBootstrapCubit cubit;
  late Storage storage;

  setUp(() {
    cubit = _MockAppBootstrapCubit();
    storage = _MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any<dynamic>())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    HydratedBloc.storage = storage;
  });

  /// Pumps the app with a cache holding one household and a hydrate whose
  /// last pass **failed** — the state the banner and its retry live in.
  Future<HouseholdHydrationStatus> pumpHome(
    WidgetTester tester, {
    HouseholdRefresher? refresher,
    SessionRehydrator? rehydrator,
  }) async {
    final repository = _MockHouseholdRepository();
    when(repository.watchHouseholds)
        .thenAnswer((_) => Stream<List<Household>>.value([_household(_id)]));
    when(
      () => repository.watchMembers(any()),
    ).thenAnswer((_) => Stream<List<HouseholdMember>>.value([_member('u-me')]));
    when(() => repository.getCurrentUserMember(any()))
        .thenAnswer((_) async => _member('u-me'));

    final status = HouseholdHydrationStatus()
      ..started()
      ..finished(HydrateOutcome.failed);
    addTearDown(status.close);

    when(() => cubit.activeServerScope).thenReturn(
      FakeActiveServerScope(
        buildActiveServer(
          FakeAuthRepository(initialSession: sampleSession()),
          householdRepository: repository,
          householdHydrationStatus: status,
          householdRefresher: refresher,
          sessionRehydrator: rehydrator,
        ),
      ),
    );
    whenListen(
      cubit,
      const Stream<AppBootstrapState>.empty(),
      initialState: const AppBootstrapReady(),
    );
    await tester.pumpWidget(BgeApp(bootstrapCubit: cubit));
    await tester.pumpAndSettle();
    return status;
  }

  Future<void> openTheList(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.menu));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(HomeScreen.entryKey('households')));
    await tester.pumpAndSettle();
  }

  group('BgeApp household retry wiring (#300)', () {
    testWidgets('the list banner reaches the session refresher', (
      tester,
    ) async {
      var calls = 0;
      await pumpHome(
        tester,
        refresher: HouseholdRefresher(() async => calls++),
      );
      await openTheList(tester);

      expect(find.byKey(HouseholdListScreen.refreshBannerKey), findsOneWidget);
      await tester.tap(find.byKey(HouseholdListScreen.refreshRetryKey));
      await tester.pumpAndSettle();

      expect(calls, 1);
    });

    testWidgets('the detail banner reaches the same refresher (#300 D10)', (
      tester,
    ) async {
      var calls = 0;
      await pumpHome(
        tester,
        refresher: HouseholdRefresher(() async => calls++),
      );
      await openTheList(tester);
      await tester.tap(find.byKey(HouseholdListScreen.rowKey(_id)));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(HouseholdDetailScreen.refreshRetryKey));
      await tester.pumpAndSettle();

      expect(calls, 1);
    });

    testWidgets('a container with no refresher still renders the banner', (
      tester,
    ) async {
      // Web until #137, and any composition that runs no drain: the banner
      // still reports the stale list, and simply offers nothing to press.
      await pumpHome(tester);
      await openTheList(tester);

      expect(find.byKey(HouseholdListScreen.refreshBannerKey), findsOneWidget);
      expect(find.byKey(HouseholdListScreen.refreshRetryKey), findsNothing);
    });
  });

  group('BgeApp household entry trigger (#300 D1, D13, D14)', () {
    testWidgets('opening the list asks the session for a stale pass', (
      tester,
    ) async {
      final rehydrator = _RecordingRehydrator();
      await pumpHome(tester, rehydrator: rehydrator);

      // Nothing yet: the home screen is not the household list, and the
      // trigger belongs to entering it.
      expect(rehydrator.passes, 0);

      await openTheList(tester);

      expect(rehydrator.passes, 1);
    });

    testWidgets('pushing the detail route does not fire a second pass', (
      tester,
    ) async {
      // The #300 D14 hazard, at the composition it actually happens in.
      // go_router builds every page in the match stack, so the list route's
      // builder runs again when the detail route goes on top of it — which
      // is why the trigger lives in the screen's provider rather than there.
      final rehydrator = _RecordingRehydrator();
      await pumpHome(tester, rehydrator: rehydrator);
      await openTheList(tester);
      expect(rehydrator.passes, 1);

      await tester.tap(find.byKey(HouseholdListScreen.rowKey(_id)));
      await tester.pumpAndSettle();

      expect(rehydrator.passes, 1);
    });

    testWidgets('leaving the household section and coming back fires again', (
      tester,
    ) async {
      // What #300 D1 is for: "navigate away and back" has to mean
      // something. Whether the pass does any *work* is the registry's
      // answer via the staleness window, not the screen's.
      final rehydrator = _RecordingRehydrator();
      await pumpHome(tester, rehydrator: rehydrator);
      await openTheList(tester);
      expect(rehydrator.passes, 1);

      // Back to home, then in again — a fresh list route either way.
      await tester.pageBack();
      await tester.pumpAndSettle();
      await openTheList(tester);

      expect(rehydrator.passes, 2);
    });

    testWidgets('popping back from the detail screen does not re-fire', (
      tester,
    ) async {
      // Not a gap in "navigate away and back" (#300 D1) — the detail screen
      // is not away. It reads the same cache through the same repository
      // and watches the same `HouseholdHydrationStatus`, carrying its own
      // banner and its own retry over them (#270, #300 D10), so the
      // household data was never out of view. The list route is still in
      // the stack throughout, which is why its provider is not rebuilt.
      //
      // Leaving the section entirely is the gesture that re-fires, and it
      // does — see above.
      final rehydrator = _RecordingRehydrator();
      await pumpHome(tester, rehydrator: rehydrator);
      await openTheList(tester);
      await tester.tap(find.byKey(HouseholdListScreen.rowKey(_id)));
      await tester.pumpAndSettle();

      // The ordinary pushed path pops, so this is the app bar's own back —
      // `HouseholdDetailScreen.backKey` is the stranded-entry affordance and
      // is deliberately absent here.
      await tester.pageBack();
      await tester.pumpAndSettle();

      expect(rehydrator.passes, 1);
    });

    testWidgets('a container with no rehydrator still renders the list', (
      tester,
    ) async {
      // The #137 path again: absent seam, working screen.
      await pumpHome(tester);
      await openTheList(tester);

      expect(find.byKey(HouseholdListScreen.refreshBannerKey), findsOneWidget);
    });
  });
}
