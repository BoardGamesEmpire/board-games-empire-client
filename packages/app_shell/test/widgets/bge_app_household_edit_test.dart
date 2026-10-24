import 'dart:async';

import 'package:app_shell/app_shell.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:household/household.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import '../support/active_server_fakes.dart';

class _MockAppBootstrapCubit extends MockCubit<AppBootstrapState>
    implements AppBootstrapCubit {}

class _MockStorage extends Mock implements Storage {}

class _MockHouseholdRepository extends Mock implements HouseholdRepository {}

class _MockHouseholdRemote extends Mock implements HouseholdRemoteDataSource {}

Household _household(String name) => Household(
  id: 'hh_a',
  name: name,
  settings: const HouseholdSettings(
    memberInvitePolicy: MemberInvitePolicy.needsApproval,
  ),
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

HouseholdMember _owner() => HouseholdMember(
  id: 'm-hh_a',
  userId: 'u-me',
  householdId: 'hh_a',
  role: HouseholdRole.householdOwner,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

/// #476 through the real composition: the detail screen's Edit, the edit
/// route's builder, and the way back to the detail screen after a save.
void main() {
  late _MockAppBootstrapCubit cubit;
  late _MockHouseholdRemote remote;
  late _MockHouseholdRepository repository;
  late StreamController<List<Household>> households;
  late Household cached;

  setUpAll(() {
    registerFallbackValue(HouseholdUpdate(name: 'x'));
    registerFallbackValue(_household('x'));
  });

  setUp(() {
    cubit = _MockAppBootstrapCubit();
    remote = _MockHouseholdRemote();
    repository = _MockHouseholdRepository();
    households = StreamController<List<Household>>.broadcast();
    addTearDown(households.close);
    cached = _household('Alpha Crew');
    final storage = _MockStorage();
    when(() => storage.read(any())).thenReturn(null);
    when(() => storage.write(any(), any<dynamic>())).thenAnswer((_) async {});
    when(() => storage.delete(any())).thenAnswer((_) async {});
    HydratedBloc.storage = storage;

    // The cache as the household screens read it: the detail screen
    // watches the list, and the edit screen reads the row.
    when(repository.watchHouseholds).thenAnswer((_) async* {
      yield [cached];
      yield* households.stream;
    });
    when(() => repository.watchMembers(any()))
        .thenAnswer((_) => Stream.value([_owner()]));
    when(() => repository.getCurrentUserMember(any()))
        .thenAnswer((_) async => _owner());
    when(() => repository.getHousehold('hh_a')).thenAnswer((_) async => cached);
    when(() => repository.cacheHousehold(any())).thenAnswer((invocation) async {
      cached = invocation.positionalArguments.single as Household;
      households.add([cached]);
    });
  });

  Future<GoRouter> pumpApp(
    WidgetTester tester, {
    bool withRemote = true,
  }) async {
    final server = buildActiveServer(
      FakeAuthRepository(initialSession: sampleSession()),
      householdRepository: repository,
      householdRemoteDataSource: withRemote ? remote : null,
    );
    when(() => cubit.activeServerScope)
        .thenReturn(FakeActiveServerScope(server));
    whenListen(
      cubit,
      const Stream<AppBootstrapState>.empty(),
      initialState: const AppBootstrapReady(),
    );
    await tester.pumpWidget(BgeApp(bootstrapCubit: cubit));
    await tester.pumpAndSettle();
    return tester.widget<MaterialApp>(find.byType(MaterialApp)).routerConfig!
        as GoRouter;
  }

  testWidgets('Edit on the detail screen opens the edit screen', (
    tester,
  ) async {
    final router = await pumpApp(tester);
    router.go(AppRoutes.householdDetailOf('hh_a'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(HouseholdDetailScreen.editKey));
    await tester.pumpAndSettle();

    expect(find.byType(EditHouseholdScreen), findsOneWidget);
    expect(find.byKey(EditHouseholdForm.submitButtonKey), findsOneWidget);
  });

  testWidgets('a save pops back to the detail screen showing the new name', (
    tester,
  ) async {
    when(() => remote.updateHousehold('hh_a', any()))
        .thenAnswer((_) async => _household('Beta Crew'));
    final router = await pumpApp(tester);
    router.go(AppRoutes.householdDetailOf('hh_a'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(HouseholdDetailScreen.editKey));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(EditHouseholdForm.nameFieldKey),
      'Beta Crew',
    );
    await tester.ensureVisible(find.byKey(EditHouseholdForm.submitButtonKey));
    await tester.tap(find.byKey(EditHouseholdForm.submitButtonKey));
    await tester.pumpAndSettle();

    expect(find.byType(EditHouseholdScreen), findsNothing);
    expect(find.byType(HouseholdDetailScreen), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.text('Beta Crew'),
      ),
      findsOneWidget,
    );
    expect(find.text('Household updated.'), findsOneWidget);
    final update =
        verify(() => remote.updateHousehold('hh_a', captureAny()))
                .captured
                .single
            as HouseholdUpdate;
    expect(update.name, 'Beta Crew');
  });

  testWidgets('without a household remote there is no Edit, and the route '
      'falls back', (tester) async {
    final router = await pumpApp(tester, withRemote: false);
    router.go(AppRoutes.householdDetailOf('hh_a'));
    await tester.pumpAndSettle();

    expect(find.byKey(HouseholdDetailScreen.editKey), findsNothing);

    router.go(AppRoutes.householdEditOf('hh_a'));
    await tester.pumpAndSettle();

    expect(find.byType(NotYetAvailableScreen), findsOneWidget);
  });
}
