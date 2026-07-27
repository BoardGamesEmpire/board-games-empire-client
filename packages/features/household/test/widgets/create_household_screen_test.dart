import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household/household.dart';
import 'package:household/l10n/household_localizations.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

class _MockHouseholdRepository extends Mock implements HouseholdRepository {}

class _MockHouseholdRemoteDataSource extends Mock
    implements HouseholdRemoteDataSource {}

Household _household({String id = 'hh_local', bool localOnly = true}) =>
    Household(
      id: id,
      name: 'HQ',
      isDirty: localOnly,
      isLocalOnly: localOnly,
      createdAt: DateTime.utc(2024, 1, 15),
      updatedAt: DateTime.utc(2024, 1, 15),
    );

/// Pins the #40 create-household screen end to end over a mocked repository
/// and remote: the confirmed / still-queued outcomes surface their distinct
/// localized messages and pop with the right id, a local failure surfaces the
/// localized error and stays put, and the in-flight state disables submit.
void main() {
  late _MockHouseholdRepository repo;
  late _MockHouseholdRemoteDataSource remote;

  setUpAll(() => registerFallbackValue(_household()));

  setUp(() {
    repo = _MockHouseholdRepository();
    remote = _MockHouseholdRemoteDataSource();

    when(
      () => repo.create(
        name: any(named: 'name'),
        description: any(named: 'description'),
      ),
    ).thenAnswer((_) async => (household: _household(), syncQueueId: 'q1'));

    when(
      () => repo.reconcileCreatedHousehold(
        any(),
        localId: any(named: 'localId'),
        completedSyncQueueId: any(named: 'completedSyncQueueId'),
      ),
    ).thenAnswer((_) async {});

    when(
      () => remote.createHousehold(
        name: any(named: 'name'),
        description: any(named: 'description'),
      ),
    ).thenAnswer((_) async => _household(id: 'hh_server', localOnly: false));
  });

  /// Hosts the screen behind a pushed route so the pop result is observable.
  Widget harness({required void Function(Object?) onPopped}) => MaterialApp(
    localizationsDelegates: HouseholdLocalizations.localizationsDelegates,
    supportedLocales: HouseholdLocalizations.supportedLocales,
    home: Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () async {
            final result = await Navigator.of(context).push<Object?>(
              MaterialPageRoute(
                builder: (_) =>
                    CreateHouseholdScreen(repository: repo, remote: remote),
              ),
            );
            onPopped(result);
          },
          child: const Text('open'),
        ),
      ),
    ),
  );

  Future<void> openScreen(WidgetTester tester) async {
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Future<void> fillAndSubmit(WidgetTester tester, {String name = 'HQ'}) async {
    await tester.enterText(find.byKey(CreateHouseholdForm.nameFieldKey), name);
    await tester.tap(find.byKey(CreateHouseholdForm.submitButtonKey));
  }

  group('CreateHouseholdScreen', () {
    testWidgets('renders the localized title', (tester) async {
      await tester.pumpWidget(harness(onPopped: (_) {}));
      await openScreen(tester);

      expect(find.text('Create household'), findsWidgets);
    });

    testWidgets('a server-confirmed create shows the synced message and pops '
        'with the canonical id', (tester) async {
      Object? popped;
      await tester.pumpWidget(harness(onPopped: (r) => popped = r));
      await openScreen(tester);

      await fillAndSubmit(tester);
      await tester.pumpAndSettle();

      expect(find.text('Household created.'), findsOneWidget);
      expect(popped, 'hh_server');
      verify(
        () => repo.reconcileCreatedHousehold(
          any(),
          localId: 'hh_local',
          completedSyncQueueId: 'q1',
        ),
      ).called(1);
    });

    testWidgets('a remote failure shows the queued message and pops with the '
        'local id (the household still exists)', (tester) async {
      when(
        () => remote.createHousehold(
          name: any(named: 'name'),
          description: any(named: 'description'),
        ),
      ).thenThrow(const HouseholdRemoteTransientException('offline'));

      Object? popped;
      await tester.pumpWidget(harness(onPopped: (r) => popped = r));
      await openScreen(tester);

      await fillAndSubmit(tester);
      await tester.pumpAndSettle();

      expect(
        find.text(
          "Household created. It'll finish syncing when you're back online.",
        ),
        findsOneWidget,
      );
      expect(popped, 'hh_local');
      verifyNever(
        () => repo.reconcileCreatedHousehold(
          any(),
          localId: any(named: 'localId'),
          completedSyncQueueId: any(named: 'completedSyncQueueId'),
        ),
      );
    });

    testWidgets('a local failure surfaces the localized error and does not '
        'pop', (tester) async {
      when(
        () => repo.create(
          name: any(named: 'name'),
          description: any(named: 'description'),
        ),
      ).thenThrow(StateError('db is down'));

      var popped = false;
      await tester.pumpWidget(harness(onPopped: (_) => popped = true));
      await openScreen(tester);

      await fillAndSubmit(tester);
      await tester.pumpAndSettle();

      expect(
        find.text(
          'Something went wrong creating your household. Please try again.',
        ),
        findsOneWidget,
      );
      expect(popped, isFalse);
      expect(find.byKey(CreateHouseholdForm.submitButtonKey), findsOneWidget);
    });

    testWidgets('while the create is in flight the submit button is disabled '
        'and shows a spinner', (tester) async {
      final gate = Completer<({Household household, String syncQueueId})>();
      when(
        () => repo.create(
          name: any(named: 'name'),
          description: any(named: 'description'),
        ),
      ).thenAnswer((_) => gate.future);

      await tester.pumpWidget(harness(onPopped: (_) {}));
      await openScreen(tester);

      await fillAndSubmit(tester);
      await tester.pump();

      final button = tester.widget<ElevatedButton>(
        find.byKey(CreateHouseholdForm.submitButtonKey),
      );
      expect(button.onPressed, isNull);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      gate.complete((household: _household(), syncQueueId: 'q1'));
      await tester.pumpAndSettle();
    });

    testWidgets('a blank name never reaches the repository', (tester) async {
      await tester.pumpWidget(harness(onPopped: (_) {}));
      await openScreen(tester);

      await tester.tap(find.byKey(CreateHouseholdForm.submitButtonKey));
      await tester.pumpAndSettle();

      expect(find.text('Enter a name for your household.'), findsOneWidget);
      verifyNever(
        () => repo.create(
          name: any(named: 'name'),
          description: any(named: 'description'),
        ),
      );
    });
  });
}
