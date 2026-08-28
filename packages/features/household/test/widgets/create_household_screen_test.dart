import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household/household.dart';
import 'package:household/l10n/household_localizations.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui_tokens/ui_tokens.dart';

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
/// localized messages and report the right id, a local failure surfaces the
/// localized error and reports nothing, and the in-flight state disables
/// submit.
///
/// Where the created household is *shown* is not this seam's business (#271
/// D2) — the screen takes an `onCreated` callback and the shell turns it into
/// a route change. `bge_app_household_create_navigation_test.dart` pins that
/// half, because only a real router has a back stack to assert against.
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

  /// Hosts the screen behind a pushed route — the shape of the drawer path,
  /// where a list route sits beneath the form.
  ///
  /// What the test observes is the id handed to [onCreated] and the fact that
  /// the screen does **not** navigate itself (#271 D2): the route change is
  /// the shell's, so at this seam a success is a callback and nothing else.
  Widget harness({required void Function(String) onCreated}) => MaterialApp(
    localizationsDelegates: HouseholdLocalizations.localizationsDelegates,
    supportedLocales: HouseholdLocalizations.supportedLocales,
    home: Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () => unawaited(
            Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) => CreateHouseholdScreen(
                  repository: repo,
                  remote: remote,
                  onCreated: (_, householdId) => onCreated(householdId),
                ),
              ),
            ),
          ),
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

  /// Sets the render surface to a small window. `MediaQueryData.size` is
  /// metadata and constrains nothing, so the viewport the banner has to be
  /// revealed within has to come from the view.
  ///
  /// 400dp tall rather than the checklist's 480: at 200% text scale this form
  /// still *fits* a 480dp viewport, so there is nothing to scroll and #209's
  /// bug cannot arise there. Desktop and browser are first-class targets, so a
  /// window this short is a real one — and it is the shape where the failure
  /// was reported.
  void useNarrowWindow(WidgetTester tester) {
    tester.view.physicalSize = const Size(320, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  ScrollableState pageScroll(WidgetTester tester) =>
      tester.state<ScrollableState>(find.byType(Scrollable).first);

  /// The banner's top edge in the page scroll viewport's own space.
  ///
  /// Geometry rather than `findsOneWidget`, which passes for a banner scrolled
  /// clean out of the viewport — the bug in #209 and the reason no existing
  /// assertion here could catch it.
  double bannerTop(WidgetTester tester) => tester
      .renderObject<RenderBox>(find.byKey(CreateHouseholdScreen.errorBannerKey))
      .localToGlobal(
        Offset.zero,
        ancestor: tester.renderObject<RenderBox>(find.byType(Scrollable).first),
      )
      .dy;

  /// Outcome copy must land on an announcing surface — never as plain body
  /// text, which would render the same words and announce nothing (#40's
  /// "announce on success/failure"). The two outcomes use different surfaces
  /// on purpose (#191):
  ///
  /// Success replaces the route (#271), so its confirmation has to outlive
  /// the screen. That is a [SnackBar], which Flutter wraps in a
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
      await tester.pumpWidget(harness(onCreated: (_) {}));
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

    testWidgets('a server-confirmed create shows the synced message and hands '
        'the canonical id to onCreated', (tester) async {
      String? created;
      await tester.pumpWidget(harness(onCreated: (id) => created = id));
      await openScreen(tester);

      await fillAndSubmit(tester);
      await tester.pumpAndSettle();

      expect(inSnackBar(_syncedCopy), findsOneWidget);
      expect(created, 'hh_server');
      verify(
        () => repo.reconcileCreatedHousehold(
          any(),
          localId: 'hh_local',
          completedSyncQueueId: 'q1',
        ),
      ).called(1);
    });

    testWidgets('a remote failure shows the queued message and hands the local '
        'id to onCreated (the household still exists)', (tester) async {
      when(
        () => remote.createHousehold(
          name: any(named: 'name'),
          description: any(named: 'description'),
        ),
      ).thenThrow(const HouseholdRemoteTransientException('offline'));

      String? created;
      await tester.pumpWidget(harness(onCreated: (id) => created = id));
      await openScreen(tester);

      await fillAndSubmit(tester);
      await tester.pumpAndSettle();

      expect(inSnackBar(_queuedCopy), findsOneWidget);
      expect(inSnackBar(_syncedCopy), findsNothing);
      // The optimistic local id, which is what the shell will put on the
      // route. A reconcile that later remaps it is #306, not this seam.
      expect(created, 'hh_local');
      verifyNever(
        () => repo.reconcileCreatedHousehold(
          any(),
          localId: any(named: 'localId'),
          completedSyncQueueId: any(named: 'completedSyncQueueId'),
        ),
      );
    });

    testWidgets('a local failure surfaces the localized error and never '
        'reports a creation', (tester) async {
      when(
        () => repo.create(
          name: any(named: 'name'),
          description: any(named: 'description'),
        ),
      ).thenThrow(StateError('db is down'));

      var created = false;
      await tester.pumpWidget(harness(onCreated: (_) => created = true));
      await openScreen(tester);

      await fillAndSubmit(tester);
      await tester.pumpAndSettle();

      expect(inErrorBanner(_errorCopy), findsOneWidget);
      // Not a SnackBar: the screen stays put, so the error belongs on it.
      expect(find.byType(SnackBar), findsNothing);
      expect(created, isFalse);
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

      await tester.pumpWidget(harness(onCreated: (_) {}));
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

      await tester.pumpWidget(harness(onCreated: (_) {}));
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

    testWidgets('the failure banner is scrolled into view on a small window at '
        '200% text scale', (tester) async {
      // #209: the banner announced itself but nothing revealed it. At 200%
      // text scale on a small window the form overflows, so the user has
      // scrolled down to reach the submit button — their tap failed, the
      // banner appeared above the viewport, and the visible result was a
      // button that did nothing.
      useNarrowWindow(tester);
      when(
        () => repo.create(
          name: any(named: 'name'),
          description: any(named: 'description'),
        ),
      ).thenThrow(StateError('db is down'));

      await tester.pumpWidget(
        MediaQuery(
          // Above MaterialApp on purpose: `MediaQuery.fromView` is inserted by
          // `View`, higher still, so this one wins for the subtree below.
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: harness(onCreated: (_) {}),
        ),
      );
      await openScreen(tester);

      // The user scrolls down to reach the submit button.
      final position = pageScroll(tester).position;
      expect(
        position.maxScrollExtent,
        greaterThan(0),
        reason:
            'sanity: at 200% scale this form must overflow the viewport, '
            'or there is nothing for the reveal to fix',
      );
      position.jumpTo(position.maxScrollExtent);
      await tester.pumpAndSettle();

      await fillAndSubmit(tester);
      await tester.pumpAndSettle();

      expect(inErrorBanner(_errorCopy), findsOneWidget, reason: 'sanity');
      // The revealed position, not merely "somewhere on screen": asserting
      // `top >= 0 && top < viewportHeight` would restate the widget's own
      // visibility guard, so it would pass for any implementation that
      // satisfies the guard — including one that leaves a few dp of banner
      // showing above the bottom edge.
      expect(
        bannerTop(tester),
        moreOrLessEquals(BgeTokens.standard.spaceMd, epsilon: 0.5),
        reason:
            'the banner leads with its top edge, one spacing step below '
            'the viewport start so it is not flush against the app bar',
      );
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

      String? created;
      await tester.pumpWidget(harness(onCreated: (id) => created = id));
      await openScreen(tester);

      await fillAndSubmit(tester, name: 'Game Night HQ');
      await tester.pumpAndSettle();

      expect(inErrorBanner(_errorCopy), findsOneWidget);
      // The typed name survives the failure — the user must not have to
      // retype it to retry.
      expect(find.text('Game Night HQ'), findsOneWidget);

      await tester.tap(find.byKey(CreateHouseholdForm.submitButtonKey));
      await tester.pumpAndSettle();

      expect(created, 'hh_server');
      verify(() => repo.create(name: 'Game Night HQ', description: null))
          .called(2);
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

      await tester.pumpWidget(harness(onCreated: (_) {}));
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
      await tester.pumpWidget(harness(onCreated: (_) {}));
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

    testWidgets('direct entry (no route beneath) reports the creation like any '
        'other — the fix for #162', (tester) async {
      // Reachable on web, where /household/create is a real URL that can be
      // typed or reloaded, and via deep links (#10). This used to be the
      // defect: `maybePop` no-ops on a root route, so the user was told the
      // household was created while still sitting on the submitted form.
      //
      // #271 D2 removes the situation instead of special-casing it. There is
      // no pop and no "did we arrive here directly?" branch, so this entry is
      // not a case the screen distinguishes at all — which is exactly what
      // this test now asserts.
      String? created;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: HouseholdLocalizations.localizationsDelegates,
          supportedLocales: HouseholdLocalizations.supportedLocales,
          home: CreateHouseholdScreen(
            repository: repo,
            remote: remote,
            onCreated: (_, householdId) => created = householdId,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await fillAndSubmit(tester);
      await tester.pumpAndSettle();

      expect(inSnackBar(_syncedCopy), findsOneWidget);
      expect(
        created,
        'hh_server',
        reason: 'no route beneath is not a special case any more (#162)',
      );
    });
  });
}
