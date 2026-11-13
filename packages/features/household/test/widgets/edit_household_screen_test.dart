import 'dart:async';

import 'package:bge_test_support/session.dart';
import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household/household.dart';
import 'package:household/l10n/household_localizations.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui_tokens/ui_tokens.dart';

class _MockHouseholdRepository extends Mock implements HouseholdRepository {}

/// Answers updates with [onUpdate] and records what it was sent.
class _FakeHouseholdRemote implements HouseholdRemoteDataSource {
  Future<Household> Function(String householdId, HouseholdUpdate update)?
  onUpdate;

  final List<HouseholdUpdate> updates = [];

  @override
  Future<Household> updateHousehold(
    String householdId,
    HouseholdUpdate update,
  ) {
    updates.add(update);
    return onUpdate!(householdId, update);
  }

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _id = 'hh_1';

Household _household({
  String name = 'Den',
  bool isLocalOnly = false,
  MemberInvitePolicy policy = MemberInvitePolicy.needsApproval,
}) => Household(
  id: _id,
  name: name,
  description: 'Board games',
  isDirty: isLocalOnly,
  isLocalOnly: isLocalOnly,
  settings: HouseholdSettings(memberInvitePolicy: policy),
  createdAt: DateTime.utc(2026, 10),
  updatedAt: DateTime.utc(2026, 10),
);

HouseholdMember _me(HouseholdRole? role) => HouseholdMember(
  id: 'm_me',
  userId: 'u_me',
  householdId: _id,
  role: role,
  createdAt: DateTime.utc(2026, 10),
  updatedAt: DateTime.utc(2026, 10),
);

const _notAllowedCopy = "Only the household's owners and admins can edit it.";
const _notYetSyncedCopy =
    'This household is still being created. You can edit it once it has '
    'synced.';
const _notFoundCopy = "We couldn't find this household.";
const _savedCopy = 'Household updated.';

void main() {
  late _MockHouseholdRepository repository;
  late _FakeHouseholdRemote remote;
  late StreamController<List<HouseholdMember>> members;
  late Household? household;
  late HouseholdRole? role;
  late List<BuildContext> saved;
  late int refreshes;
  late FakeSessionLease lease;

  setUpAll(() => registerFallbackValue(_household()));

  setUp(() {
    repository = _MockHouseholdRepository();
    remote = _FakeHouseholdRemote();
    members = StreamController<List<HouseholdMember>>.broadcast();
    household = _household();
    role = HouseholdRole.householdOwner;
    saved = [];
    refreshes = 0;
    lease = FakeSessionLease();
    when(() => repository.getHousehold(_id)).thenAnswer((_) async => household);
    when(() => repository.getCurrentUserMember(_id))
        .thenAnswer((_) async => _me(role));
    when(() => repository.watchMembers(_id)).thenAnswer((_) => members.stream);
    when(() => repository.cacheHousehold(any())).thenAnswer((_) async {});
  });

  tearDown(() => unawaited(members.close()));

  Widget harness({ThemeData? theme}) => MaterialApp(
    theme: theme ?? BgeTheme.light(),
    localizationsDelegates: HouseholdLocalizations.localizationsDelegates,
    supportedLocales: HouseholdLocalizations.supportedLocales,
    home: EditHouseholdScreen(
      householdId: _id,
      repository: repository,
      remote: remote,
      session: lease,
      onSaved: saved.add,
      onRefresh: () async => refreshes++,
    ),
  );

  /// The household or role has changed in the cache: what a hydrate's
  /// write looks like from here.
  Future<void> reread(WidgetTester tester) async {
    members.add([_me(role)]);
    await tester.pumpAndSettle();
  }

  /// Pumped by hand rather than settled: once saved, the button keeps its
  /// spinner while the screen closes, and onSaved here closes nothing.
  Future<void> save(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(EditHouseholdForm.submitButtonKey));
    await tester.tap(find.byKey(EditHouseholdForm.submitButtonKey));
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  String nameText(WidgetTester tester) => tester
      .widget<EditableText>(
        find.descendant(
          of: find.byKey(EditHouseholdForm.nameFieldKey),
          matching: find.byType(EditableText),
        ),
      )
      .controller
      .text;

  testWidgets('shows a spinner under the title before the first read', (
    tester,
  ) async {
    final read = Completer<Household?>();
    when(() => repository.getHousehold(_id)).thenAnswer((_) => read.future);

    await tester.pumpWidget(harness());
    await tester.pump();

    expect(find.text('Edit household'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byType(EditHouseholdForm), findsNothing);

    read.complete(_household());
    await tester.pumpAndSettle();
    expect(find.byType(EditHouseholdForm), findsOneWidget);
  });

  testWidgets('the edit-household loading state is labelled', (tester) async {
    final handle = tester.ensureSemantics();
    final read = Completer<Household?>();
    when(() => repository.getHousehold(_id)).thenAnswer((_) => read.future);

    await tester.pumpWidget(harness());
    await tester.pump();

    expect(
      tester.getSemantics(
        find.bySemanticsLabel('Loading this household\u{2026}'),
      ),
      isSemantics(isLiveRegion: true, label: 'Loading this household\u{2026}'),
    );
    handle.dispose();
    read.complete(_household());
    await tester.pumpAndSettle();
  });

  testWidgets('an owner gets the form', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(find.byType(EditHouseholdForm), findsOneWidget);
    expect(nameText(tester), 'Den');
  });

  testWidgets('an admin gets the form', (tester) async {
    role = HouseholdRole.householdAdmin;
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(find.byType(EditHouseholdForm), findsOneWidget);
  });

  testWidgets('a member is told only owners and admins can edit', (
    tester,
  ) async {
    role = HouseholdRole.householdMember;
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(find.text(_notAllowedCopy), findsOneWidget);
    expect(find.byType(EditHouseholdForm), findsNothing);
  });

  testWidgets('a household not yet synced cannot be edited', (tester) async {
    household = _household(isLocalOnly: true);
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(find.text(_notYetSyncedCopy), findsOneWidget);
    expect(find.byType(EditHouseholdForm), findsNothing);
  });

  testWidgets('an unknown id says it was not found', (tester) async {
    household = null;
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    expect(find.text(_notFoundCopy), findsOneWidget);
    expect(find.byType(EditHouseholdForm), findsNothing);
  });

  testWidgets('a household re-read under the open form keeps what was '
      'typed', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(EditHouseholdForm.nameFieldKey), 'Annex');
    household = _household(name: 'Elsewhere');
    await reread(tester);

    expect(nameText(tester), 'Annex');
  });

  testWidgets('a save after a re-read sends only what this user changed', (
    tester,
  ) async {
    // Another admin renamed the household while this form was open, and
    // this user changed only the policy. Their name must stand.
    remote.onUpdate = (_, _) async =>
        _household(name: 'Elsewhere', policy: MemberInvitePolicy.off);
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    household = _household(name: 'Elsewhere');
    await reread(tester);
    final off = find.byKey(
      EditHouseholdForm.policyOptionKey(MemberInvitePolicy.off),
    );
    await tester.ensureVisible(off);
    await tester.tap(off);
    await save(tester);

    final update = remote.updates.single;
    expect(update.name, isNull);
    expect(update.memberInvitePolicy, MemberInvitePolicy.off);
  });

  testWidgets('a role lost under the open form closes it', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    expect(find.byType(EditHouseholdForm), findsOneWidget);

    role = HouseholdRole.householdMember;
    await reread(tester);

    expect(find.byType(EditHouseholdForm), findsNothing);
    expect(find.text(_notAllowedCopy), findsOneWidget);
  });

  testWidgets('a save with nothing changed closes without saying it saved', (
    tester,
  ) async {
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await save(tester);

    expect(remote.updates, isEmpty);
    expect(saved, hasLength(1));
    expect(find.text(_savedCopy), findsNothing);
  });

  testWidgets('saving shows the snackbar and calls onSaved', (tester) async {
    final answer = _household(name: 'Annex');
    remote.onUpdate = (_, _) async => answer;
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(EditHouseholdForm.nameFieldKey), 'Annex');
    await save(tester);

    expect(find.text(_savedCopy), findsOneWidget);
    expect(saved, hasLength(1));
    verify(() => repository.cacheHousehold(answer)).called(1);
  });

  testWidgets('an offline save keeps the form and says so', (tester) async {
    remote.onUpdate = (_, _) async =>
        throw const HouseholdRemoteTransientException('down');
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(EditHouseholdForm.nameFieldKey), 'Annex');
    await save(tester);

    expect(find.text("Couldn't save"), findsOneWidget);
    expect(
      find.text(
        "Couldn't get your changes to the server. They're still here, so "
        'try again in a moment.',
      ),
      findsOneWidget,
    );
    expect(nameText(tester), 'Annex');
    expect(saved, isEmpty);
    expect(refreshes, 0);
  });

  testWidgets('a household gone on the server says so and refreshes', (
    tester,
  ) async {
    remote.onUpdate = (_, _) async =>
        throw const HouseholdNotFoundException('gone', statusCode: 404);
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(EditHouseholdForm.nameFieldKey), 'Annex');
    await save(tester);

    expect(find.text('This household no longer exists.'), findsOneWidget);
    expect(refreshes, 1);
  });

  // #464: the save outlives the form. Left while it is under way, it still
  // says how it went, on the page the user went back to, and goes nowhere:
  // the user already has.
  group('left mid-save', () {
    late EditHouseholdBloc bloc;

    /// A page whose one button pushes the screen, as the household screen's
    /// Edit does.
    Widget pushedHarness() => MaterialApp(
      theme: BgeTheme.light(),
      localizationsDelegates: HouseholdLocalizations.localizationsDelegates,
      supportedLocales: HouseholdLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) => EditHouseholdScreen(
                  householdId: _id,
                  repository: repository,
                  remote: remote,
                  session: lease,
                  onSaved: saved.add,
                  onRefresh: () async => refreshes++,
                ),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );

    Future<void> open(WidgetTester tester) async {
      await tester.pumpWidget(pushedHarness());
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      bloc = BlocProvider.of<EditHouseholdBloc>(
        tester.element(find.byType(EditHouseholdForm)),
      );
    }

    /// Renames the household to Annex against an answer that waits on the
    /// returned completer.
    Future<Completer<Household>> saveHeld(WidgetTester tester) async {
      final answer = Completer<Household>();
      remote.onUpdate = (_, _) => answer.future;
      await open(tester);
      await tester.enterText(
        find.byKey(EditHouseholdForm.nameFieldKey),
        'Annex',
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(EditHouseholdForm.submitButtonKey));
      await tester.tap(find.byKey(EditHouseholdForm.submitButtonKey));
      await tester.pump();
      expect(bloc.state, isA<EditHouseholdSaving>());
      return answer;
    }

    /// Renames the household to Annex against an answer that waits on the
    /// returned completer, then goes back while it is under way.
    Future<Completer<Household>> saveThenLeave(WidgetTester tester) async {
      final answer = await saveHeld(tester);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(EditHouseholdScreen), findsNothing);
      return answer;
    }

    Future<bool> closed(WidgetTester tester) async {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      return bloc.isClosed;
    }

    Finder inSnackBar(String copy) =>
        find.descendant(of: find.byType(SnackBar), matching: find.text(copy));

    /// The page beneath is the only route: nothing was pushed or popped
    /// after the user went back.
    void expectStackUnchanged(WidgetTester tester) {
      expect(find.text('open'), findsOneWidget);
      expect(Navigator.of(tester.element(find.text('open'))).canPop(), false);
      expect(saved, isEmpty);
    }

    testWidgets('left mid-save, the outcome is still said', (tester) async {
      final answer = await saveThenLeave(tester);
      // Kept for the save still under way.
      expect(await closed(tester), isFalse);

      answer.complete(_household(name: 'Annex'));
      await tester.pumpAndSettle();

      expect(inSnackBar(_savedCopy), findsOneWidget);
      expectStackUnchanged(tester);
      expect(await closed(tester), isTrue);
    });

    testWidgets('left mid-save, a failure is still said, naming the '
        'household', (tester) async {
      final answer = await saveThenLeave(tester);

      answer.completeError(const HouseholdRemoteTransientException('down'));
      await tester.pumpAndSettle();

      // Named as the form opened with it: the rename is what wasn't saved.
      expect(inSnackBar("Your changes to Den weren't saved."), findsOneWidget);
      expectStackUnchanged(tester);
      expect(await closed(tester), isTrue);
    });

    testWidgets('left mid-save, nothing is said once the session has ended', (
      tester,
    ) async {
      final answer = await saveThenLeave(tester);
      lease.isLive = false;

      answer.complete(_household(name: 'Annex'));
      await tester.pumpAndSettle();

      expect(find.byType(SnackBar), findsNothing);
      expectStackUnchanged(tester);
      // Still closed: ending the session skips the message, not the close.
      expect(await closed(tester), isTrue);
    });

    // The shell ends a session in the same turn it routes away, and the
    // popped route stays mounted through its exit. A save that settles there
    // asks the lease (#694), is said as it would be once the form had gone,
    // and goes nowhere (#464).
    group("on the route's way out", () {
      /// Saves against an answer that waits on the returned completer, pops
      /// the form and, in the same turn when [endSession], ends the session,
      /// then pumps 50 ms into the exit.
      Future<Completer<Household>> saveThenPop(
        WidgetTester tester, {
        bool endSession = false,
      }) async {
        final answer = await saveHeld(tester);
        Navigator.of(tester.element(find.byType(EditHouseholdForm))).pop();
        if (endSession) lease.isLive = false;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(find.byType(EditHouseholdScreen), findsOneWidget);
        return answer;
      }

      /// Gives [answer], and lets it reach the form, still inside the exit.
      Future<void> settle(
        WidgetTester tester,
        Completer<Household> answer, {
        required bool fails,
      }) async {
        if (fails) {
          answer.completeError(const HouseholdRemoteTransientException('down'));
        } else {
          answer.complete(_household(name: 'Annex'));
        }
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(find.byType(EditHouseholdScreen), findsOneWidget);
      }

      /// The keys of the bars showing: a bar said again is a new key.
      Set<Key?> barKeys(WidgetTester tester) => {
        for (final bar in tester.widgetList<SnackBar>(find.byType(SnackBar)))
          bar.key,
      };

      for (final (name, fails) in [('lands', false), ('fails', true)]) {
        testWidgets('a save that $name after the session ended says nothing, '
            'and the bloc still closes', (tester) async {
          final answer = await saveThenPop(tester, endSession: true);

          await settle(tester, answer, fails: fails);
          expect(find.byType(SnackBar), findsNothing);
          await tester.pumpAndSettle();

          expect(find.byType(SnackBar), findsNothing);
          expectStackUnchanged(tester);
          expect(await closed(tester), isTrue);
        });
      }

      for (final (name, fails, copy) in [
        ('lands', false, _savedCopy),
        // Named as the form opened with it: the rename is what wasn't saved.
        ('fails', true, "Your changes to Den weren't saved."),
      ]) {
        testWidgets('a save that $name is said once, and goes nowhere', (
          tester,
        ) async {
          final answer = await saveThenPop(tester);

          await settle(tester, answer, fails: fails);
          // One bar, drawn in both pages' scaffolds while the exit runs.
          expect(inSnackBar(copy), findsWidgets);
          final said = barKeys(tester);
          expect(said, hasLength(1));
          await tester.pumpAndSettle();

          expect(inSnackBar(copy), findsOneWidget);
          expect(barKeys(tester), said);
          expectStackUnchanged(tester);
          expect(await closed(tester), isTrue);
        });
      }
    });

    testWidgets('a form a lost role takes away mid-save still says how the '
        'save went, over the note', (tester) async {
      final answer = Completer<Household>();
      remote.onUpdate = (_, _) => answer.future;
      await tester.pumpWidget(harness());
      await tester.pumpAndSettle();
      bloc = BlocProvider.of<EditHouseholdBloc>(
        tester.element(find.byType(EditHouseholdForm)),
      );
      await tester.enterText(
        find.byKey(EditHouseholdForm.nameFieldKey),
        'Annex',
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(EditHouseholdForm.submitButtonKey));
      await tester.tap(find.byKey(EditHouseholdForm.submitButtonKey));
      await tester.pump();
      expect(bloc.state, isA<EditHouseholdSaving>());

      role = HouseholdRole.householdMember;
      await reread(tester);
      expect(find.byType(EditHouseholdForm), findsNothing);
      expect(find.text(_notAllowedCopy), findsOneWidget);

      answer.completeError(
        const HouseholdRemotePermanentException('no', statusCode: 403),
      );
      await tester.pumpAndSettle();

      expect(inSnackBar("Your changes to Den weren't saved."), findsOneWidget);
      expect(find.text(_notAllowedCopy), findsOneWidget);
      expect(saved, isEmpty);
      expect(await closed(tester), isTrue);
    });

    testWidgets('left mid-save with nothing changed says nothing', (
      tester,
    ) async {
      await open(tester);

      // Save with nothing changed, and go back in the same turn. A save that
      // changes nothing sends nothing and is never under way, so there is
      // nothing to wait for: the form closes as it goes.
      await tester.ensureVisible(find.byKey(EditHouseholdForm.submitButtonKey));
      await tester.tap(find.byKey(EditHouseholdForm.submitButtonKey));
      Navigator.of(tester.element(find.byType(EditHouseholdForm))).pop();
      await tester.pumpAndSettle();

      expect(find.byType(EditHouseholdScreen), findsNothing);
      expect(remote.updates, isEmpty);
      expect(find.byType(SnackBar), findsNothing);
      expect(find.text('open'), findsOneWidget);
      expect(Navigator.of(tester.element(find.text('open'))).canPop(), false);
      expect(await closed(tester), isTrue);
    });
  });

  group('accessibility audit', () {
    /// The screen over the fakes as [seed] leaves them. `build` runs in the
    /// test body before the first read, so the state is chosen here, not in
    /// `arrange`.
    Widget Function(ThemeData) screenWith([void Function()? seed]) => (theme) {
      seed?.call();
      return harness(theme: theme);
    };

    final build = screenWith();

    Finder submit() => find.byKey(EditHouseholdForm.submitButtonKey);

    Future<void> rejectBlankName(WidgetTester tester) async {
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(EditHouseholdForm.nameFieldKey), '');
      await tester.ensureVisible(submit());
      await tester.tap(submit());
      await tester.pumpAndSettle();
      expect(find.text('Enter a name for your household.'), findsOneWidget);
    }

    Future<void> failSave(WidgetTester tester) async {
      remote.onUpdate = (_, _) async =>
          throw const HouseholdRemoteTransientException('down');
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(EditHouseholdForm.nameFieldKey),
        'Annex',
      );
      await save(tester);
      await tester.pumpAndSettle();
      expect(find.byKey(EditHouseholdScreen.errorKey), findsOneWidget);
    }

    // The read never answers, so the spinner never stops.
    auditScreen(
      'loading',
      build: screenWith(() {
        final read = Completer<Household?>();
        addTearDown(() => read.complete(_household()));
        when(() => repository.getHousehold(_id)).thenAnswer((_) => read.future);
      }),
      arrange: (tester) async {
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
      },
      settle: false,
    );

    auditScreen(
      'ready',
      build: build,
      arrange: (tester) async {
        await tester.pumpAndSettle();
        expect(find.byType(EditHouseholdForm), findsOneWidget);
      },
    );

    auditScreen(
      'ready, scrolled to the end',
      build: build,
      arrange: scrollPageToEnd,
    );

    // At 390dp the end of the page leaves the description field a sliver high
    // under the top edge, which Flutter's tap-target check fails at its
    // clipped size (#50); the scrolled calls skip that width. These audit
    // both states in a view with nothing below the fold.
    auditScreen(
      'ready, whole page',
      build: build,
      arrange: (tester) async {
        await useWholePage(tester);
        expectWholePage(tester);
      },
    );

    auditScreen(
      'rejected submit, whole page',
      build: build,
      arrange: (tester) async {
        await rejectBlankName(tester);
        await useWholePage(tester);
        expectWholePage(tester);
      },
    );

    auditScreen(
      'not allowed',
      build: screenWith(() => role = HouseholdRole.householdMember),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        expect(find.text(_notAllowedCopy), findsOneWidget);
      },
    );

    auditScreen(
      'not yet synced',
      build: screenWith(() => household = _household(isLocalOnly: true)),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        expect(find.text(_notYetSyncedCopy), findsOneWidget);
      },
    );

    auditScreen(
      'not found',
      build: screenWith(() => household = null),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        expect(find.text(_notFoundCopy), findsOneWidget);
      },
    );

    auditScreen('rejected submit', build: build, arrange: rejectBlankName);

    auditScreen(
      'rejected submit, scrolled to the end',
      build: build,
      arrange: (tester) async {
        await rejectBlankName(tester);
        await scrollPageToEnd(tester);
      },
    );

    auditScreen('failure', build: build, arrange: failSave);

    auditScreen(
      'failure, scrolled to the end',
      build: build,
      arrange: (tester) async {
        await failSave(tester);
        await scrollPageToEnd(tester);
      },
    );
  });
}
