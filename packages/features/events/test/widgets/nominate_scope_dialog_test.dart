import 'package:bge_test_support/widgets.dart';
import 'package:events/events.dart';
import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/widgets/nominate_scope_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// Nominate's question on an event of more than one date (#517): the whole
/// event or one date, what the dialog lists, and what it hands back.
void main() {
  /// What the dialog popped with, once it has.
  var done = false;
  NominationScope? value;

  const whole = WholeEventScope();
  const friday = DateScope('d-1');
  const saturday = DateScope('d-2');

  /// The choices an event of two dates offers, none taken unless a test
  /// says otherwise.
  List<NominateScopeChoice> choicesOf({
    Map<NominationScope, NominateTaken> taken = const {},
  }) => [
    (
      scope: whole,
      label: 'For the whole event',
      taken: taken[whole] ?? NominateTaken.no,
    ),
    (
      scope: friday,
      label: 'For Fri, Nov 6 · 7:00 PM',
      taken: taken[friday] ?? NominateTaken.no,
    ),
    (
      scope: saturday,
      label: 'For Sat, Nov 7 · 7:00 PM',
      taken: taken[saturday] ?? NominateTaken.no,
    ),
  ];

  Future<void> open(
    WidgetTester tester, {
    String title = 'Catan',
    Map<NominationScope, NominateTaken> taken = const {},
  }) async {
    done = false;
    value = null;
    await tester.pumpWidget(
      MaterialApp(
        theme: BgeTheme.light(),
        locale: const Locale('en', 'US'),
        localizationsDelegates: EventsLocalizations.localizationsDelegates,
        supportedLocales: EventsLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showNominateScopeDialog(
                    context,
                    title: title,
                    choices: choicesOf(taken: taken),
                  ).then((result) {
                    done = true;
                    value = result;
                  }),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  Finder scope(String? occurrenceId) =>
      find.byKey(EventDetailScreen.nominateScopeKey(occurrenceId));

  /// The choice the dialog holds now.
  NominationScope? chosen(WidgetTester tester) => tester
      .widget<RadioGroup<NominationScope>>(
        find.byType(RadioGroup<NominationScope>),
      )
      .groupValue;

  Future<void> nominate(WidgetTester tester) async {
    await tester.tap(find.byKey(EventDetailScreen.nominateConfirmKey));
    await tester.pumpAndSettle();
  }

  testWidgets('lists each choice in order, the first chosen', (tester) async {
    useViewSize(tester, const Size(400, 800));
    await open(tester);

    expect(find.text('Nominate Catan'), findsOneWidget);
    final labels = [
      'For the whole event',
      'For Fri, Nov 6 · 7:00 PM',
      'For Sat, Nov 7 · 7:00 PM',
    ];
    final tops = [
      for (final label in labels) tester.getTopLeft(find.text(label)).dy,
    ];
    expect(tops, orderedEquals([...tops]..sort()));
    expect(chosen(tester), whole);
    expect(find.text('Already nominated'), findsNothing);
  });

  testWidgets('Nominate answers the choice made', (tester) async {
    useViewSize(tester, const Size(400, 800));
    await open(tester);

    await tester.tap(scope('d-2'));
    await tester.pump();
    expect(chosen(tester), saturday);
    await nominate(tester);

    expect(done, isTrue);
    expect(value, saturday);
  });

  testWidgets('a taken choice is disabled and says so, and the first left is '
      'chosen', (tester) async {
    useViewSize(tester, const Size(400, 800));
    final handle = tester.ensureSemantics();
    await open(
      tester,
      taken: {
        whole: NominateTaken.nominated,
        saturday: NominateTaken.nominated,
      },
    );

    expect(chosen(tester), friday);
    for (final (id, taken) in [(null, true), ('d-1', false), ('d-2', true)]) {
      expect(
        tester.widget<RadioListTile<NominationScope>>(scope(id)).enabled,
        !taken,
        reason: '$id',
      );
    }
    expect(find.text('Already nominated'), findsNWidgets(2));
    expect(
      tester.getSemantics(scope(null)),
      isSemantics(
        label: 'For the whole event\nAlready nominated',
        hasEnabledState: true,
        isEnabled: false,
      ),
    );

    // Pressing one taken chooses nothing.
    await tester.tap(scope('d-2'));
    await tester.pump();
    expect(chosen(tester), friday);
    await nominate(tester);

    expect(value, friday);
    handle.dispose();
  });

  testWidgets('a choice whose game is in the lineup is disabled and says '
      'so', (tester) async {
    useViewSize(tester, const Size(400, 800));
    await open(
      tester,
      taken: {
        whole: NominateTaken.inLineup,
        friday: NominateTaken.inLineup,
      },
    );

    expect(chosen(tester), saturday);
    expect(
      tester.widget<RadioListTile<NominationScope>>(scope(null)).enabled,
      isFalse,
    );
    expect(find.text('Already in the lineup'), findsNWidgets(2));
    expect(find.text('Already nominated'), findsNothing);
  });

  testWidgets('the dialog is named by its title, as iOS and macOS need '
      '(#762)', (tester) async {
    useViewSize(tester, const Size(400, 800));
    await open(tester);

    expect(
      tester.widget<AlertDialog>(find.byType(AlertDialog)).semanticLabel,
      'Nominate Catan',
    );
  });

  testWidgets('the guidelines pass, with a choice taken', (tester) async {
    useViewSize(tester, const Size(400, 800));
    final handle = tester.ensureSemantics();
    await open(tester, taken: {whole: NominateTaken.inLineup});

    await expectMeetsAccessibilityGuidelines(tester);
    handle.dispose();
  });

  testWidgets('Cancel answers null', (tester) async {
    useViewSize(tester, const Size(400, 800));
    await open(tester);

    await tester.tap(scope('d-1'));
    await tester.pump();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(done, isTrue);
    expect(value, isNull);
  });

  testWidgets('Nominate is not drawn as destructive', (tester) async {
    useViewSize(tester, const Size(400, 800));
    await open(tester);

    expect(
      tester
          .widget<TextButton>(
            find.byKey(EventDetailScreen.nominateConfirmKey),
          )
          .style,
      isNull,
    );
  });

  testWidgets('at 320dp and 200% text, with a long title, nothing overflows '
      'and every choice can be reached', (tester) async {
    useViewSize(tester, const Size(320, 640));
    tester.platformDispatcher.textScaleFactorTestValue =
        BgeTextScale.maxScaleFactor;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    await open(
      tester,
      title:
          'Twilight Imperium: Fourth Edition, Prophecy of Kings and the Codex '
          'Volumes',
      taken: {whole: NominateTaken.nominated},
    );

    expect(tester.takeException(), isNull);
    await tester.ensureVisible(scope('d-2'));
    await tester.pumpAndSettle();
    await tester.tap(scope('d-2'));
    await tester.pump();
    await tester.ensureVisible(
      find.byKey(EventDetailScreen.nominateConfirmKey),
    );
    await tester.pumpAndSettle();
    await nominate(tester);

    expect(tester.takeException(), isNull);
    expect(value, saturday);
  });
}
