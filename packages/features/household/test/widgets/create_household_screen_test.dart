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

const _syncedCopy = 'Household created.';
const _queuedCopy =
    "Household created. It'll finish syncing when you're back online.";
const _errorCopy =
    'Something went wrong creating your household. Please try again.';

/// Pins the #40 create-household screen end to end over a mocked repository
/// and remote: the confirmed / still-queued outcomes surface their distinct
/// localized messages and pop with the right id, a local failure surfaces the
/// localized error and stays put, and the in-flight state disables submit.
///
/// Finders are deliberately scoped by widget (#132): `createHouseholdTitle`
/// and `createHouseholdSubmit` are the same English string, so a bare
/// `find.text('Create household')` would pass even if the AppBar title or
/// the button disappeared entirely.
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

  /// Outcome copy must land on an announcing surface — never as plain body
  /// text, which would render the same words and announce nothing (#40's
  /// "announce on success/failure"). The two outcomes use different surfaces
  /// on purpose (#191):
  ///
  /// Success pops the screen, so its confirmation has to outlive the route.
  /// That is a [SnackBar], which Flutter wraps in a
  /// `Semantics(container: true, liveRegion: true)` — verified in
  /// `snack_bar.dart`, and the reason nothing here adds a live-region wrapper
  /// of its own. Nesting two would make screen readers stutter.
  Finder inSnackBar(String copy) =>
      find.descendant(of: find.byType(SnackBar), matching: find.text(copy));

  /// Failure keeps the user on the screen, so it belongs on the screen: a
  /// [BgeInlineBanner], which announces itself on appearance.
  Finder inErrorBanner(String copy) => find.descendant(
    of: find.byKey(CreateHouseholdScreen.errorBannerKey),
    matching: find.text(copy),
  );

  group('CreateHouseholdScreen', () {
    testWidgets('renders the localized title in the app bar', (tester) async {
      await tester.pumpWidget(harness(onPopped: (_) {}));
      await openScreen(tester);

      expect(
        find.descendant(
          of: find.byType(AppBar),
          matching: find.text('Create household'),
        ),
        findsOneWidget,
      );
      expect(
        find.widgetWithText(FilledButton, 'Create household'),
        findsOneWidget,
      );
    });

    testWidgets('a server-confirmed create shows the synced message and pops '
        'with the canonical id', (tester) async {
      Object? popped;
      await tester.pumpWidget(harness(onPopped: (r) => popped = r));
      await openScreen(tester);

      await fillAndSubmit(tester);
      await tester.pumpAndSettle();

      expect(inSnackBar(_syncedCopy), findsOneWidget);
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

      expect(inSnackBar(_queuedCopy), findsOneWidget);
      expect(inSnackBar(_syncedCopy), findsNothing);
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

      expect(inErrorBanner(_errorCopy), findsOneWidget);
      // Not a SnackBar: the screen stays put, so the error belongs on it.
      expect(find.byType(SnackBar), findsNothing);
      expect(popped, isFalse);
      expect(find.byKey(CreateHouseholdForm.submitButtonKey), findsOneWidget);
    });

    testWidgets('the failure message reaches the semantics tree', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();

      when(
        () => repo.create(
          name: any(named: 'name'),
          description: any(named: 'description'),
        ),
      ).thenThrow(StateError('db is down'));

      await tester.pumpWidget(harness(onPopped: (_) {}));
      await openScreen(tester);

      await fillAndSubmit(tester);
      await tester.pumpAndSettle();

      expect(
        find.bySemanticsLabel(RegExp('Something went wrong')),
        findsAtLeastNWidgets(1),
      );

      // Dispose inline, not via addTearDown: flutter_test verifies that no
      // SemanticsHandle is outstanding at the end of the test body, which runs
      // before tearDown callbacks.
      handle.dispose();
    });

    testWidgets('the error banner retires as soon as the user edits', (
      tester,
    ) async {
      when(
        () => repo.create(
          name: any(named: 'name'),
          description: any(named: 'description'),
        ),
      ).thenThrow(StateError('db is down'));

      await tester.pumpWidget(harness(onPopped: (_) {}));
      await openScreen(tester);
      await fillAndSubmit(tester);
      await tester.pumpAndSettle();
      expect(inErrorBanner(_errorCopy), findsOneWidget);

      await tester.enterText(
        find.byKey(CreateHouseholdForm.nameFieldKey),
        'HQ2',
      );
      await tester.pumpAndSettle();

      // The banner is bound to bloc state, so unlike the SnackBar it
      // replaced it does not fade. Left alone it would keep complaining
      // about the value the user has just replaced.
      expect(find.byKey(CreateHouseholdScreen.errorBannerKey), findsNothing);
    });

    testWidgets('after a failure the form keeps its input and a retry reaches '
        'the repository again', (tester) async {
      var attempt = 0;
      when(
        () => repo.create(
          name: any(named: 'name'),
          description: any(named: 'description'),
        ),
      ).thenAnswer((_) async {
        attempt++;
        if (attempt == 1) throw StateError('db is down');
        return (household: _household(), syncQueueId: 'q1');
      });

      Object? popped;
      await tester.pumpWidget(harness(onPopped: (r) => popped = r));
      await openScreen(tester);

      await fillAndSubmit(tester, name: 'Game Night HQ');
      await tester.pumpAndSettle();

      expect(inErrorBanner(_errorCopy), findsOneWidget);
      // The typed name survives the failure — the user must not have to
      // retype it to retry.
      expect(find.text('Game Night HQ'), findsOneWidget);

      await tester.tap(find.byKey(CreateHouseholdForm.submitButtonKey));
      await tester.pumpAndSettle();

      expect(popped, 'hh_server');
      verify(
        () => repo.create(name: 'Game Night HQ', description: null),
      ).called(2);
    });

    testWidgets('while the create is in flight the submit button is disabled '
        'and shows the localized progress label', (tester) async {
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

      final button = tester.widget<FilledButton>(
        find.descendant(
          of: find.byKey(CreateHouseholdForm.submitButtonKey),
          matching: find.byType(FilledButton),
        ),
      );
      expect(button.onPressed, isNull);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(
        find.widgetWithText(FilledButton, 'Creating household…'),
        findsOneWidget,
        reason: 'the in-flight button keeps an accessible name (#132)',
      );
      // The AppBar title is the same string as the submit label, so this
      // has to be scoped to the button to mean anything.
      expect(
        find.widgetWithText(FilledButton, 'Create household'),
        findsNothing,
      );

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

    testWidgets('direct entry (no route beneath) confirms but cannot pop — '
        'current behavior, pinned for #162', (tester) async {
      // Reachable on web, where /household/create is a real URL that can be
      // typed or reloaded, and via deep links (#10). `maybePop` no-ops on a
      // root route, so the user is told the household was created while
      // still sitting on the submitted form with an enabled submit button.
      //
      // This expectation documents the defect rather than endorsing it:
      // #162 inverts it. Do not "fix" the test — fix the screen.
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: HouseholdLocalizations.localizationsDelegates,
          supportedLocales: HouseholdLocalizations.supportedLocales,
          home: CreateHouseholdScreen(repository: repo, remote: remote),
        ),
      );
      await tester.pumpAndSettle();

      await fillAndSubmit(tester);
      await tester.pumpAndSettle();

      expect(inSnackBar(_syncedCopy), findsOneWidget);
      expect(
        find.byType(CreateHouseholdScreen),
        findsOneWidget,
        reason: 'no route beneath: the screen stays (#162)',
      );
      expect(find.byKey(CreateHouseholdForm.submitButtonKey), findsOneWidget);
    });
  });
}
