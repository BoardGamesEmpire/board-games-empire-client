import 'dart:async';

import 'package:bge_test_support/widgets.dart';
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
  createdAt: DateTime.utc(2026, 10, 1),
  updatedAt: DateTime.utc(2026, 10, 1),
);

HouseholdMember _me(HouseholdRole? role) => HouseholdMember(
  id: 'm_me',
  userId: 'u_me',
  householdId: _id,
  role: role,
  createdAt: DateTime.utc(2026, 10, 1),
  updatedAt: DateTime.utc(2026, 10, 1),
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

  setUpAll(() => registerFallbackValue(_household()));

  setUp(() {
    repository = _MockHouseholdRepository();
    remote = _FakeHouseholdRemote();
    members = StreamController<List<HouseholdMember>>.broadcast();
    household = _household();
    role = HouseholdRole.householdOwner;
    saved = [];
    refreshes = 0;
    when(() => repository.getHousehold(_id)).thenAnswer((_) async => household);
    when(() => repository.getCurrentUserMember(_id))
        .thenAnswer((_) async => _me(role));
    when(() => repository.watchMembers(_id)).thenAnswer((_) => members.stream);
    when(() => repository.cacheHousehold(any())).thenAnswer((_) async {});
  });

  tearDown(() => unawaited(members.close()));

  Widget harness({ThemeData? theme, TextScaler? textScaler}) => MaterialApp(
    theme: theme ?? BgeTheme.light(),
    builder: textScaler == null
        ? null
        : (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: textScaler),
            child: child!,
          ),
    localizationsDelegates: HouseholdLocalizations.localizationsDelegates,
    supportedLocales: HouseholdLocalizations.supportedLocales,
    home: EditHouseholdScreen(
      householdId: _id,
      repository: repository,
      remote: remote,
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

  group('accessibility audit', () {
    /// The screen over the fakes as [seed] leaves them. `build` runs in the
    /// test body before the first read, so the state is chosen here, not in
    /// `arrange`.
    Widget Function(ThemeData, TextScaler) screenWith([
      void Function()? seed,
    ]) => (theme, textScaler) {
      seed?.call();
      return harness(theme: theme, textScaler: textScaler);
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

    // The audit's 320dp × 2.0 cells are only worth running if the harness
    // passes the scale and theme on to the screen.
    testWidgets('the harness applies the theme and the text scale', (
      tester,
    ) async {
      await tester.pumpWidget(
        build(BgeTheme.dark(), const TextScaler.linear(2)),
      );
      await tester.pumpAndSettle();

      final form = find.byType(EditHouseholdForm);
      expect(MediaQuery.textScalerOf(tester.element(form)).scale(10), 20);
      expect(Theme.of(tester.element(form)).brightness, Brightness.dark);
    });

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
