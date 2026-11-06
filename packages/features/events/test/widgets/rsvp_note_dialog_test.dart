import 'package:bge_test_support/widgets.dart';
import 'package:events/events.dart';
import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/widgets/rsvp_note_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// The note that goes with the viewer's answer (#508): what the dialog hands
/// back.
void main() {
  /// What the dialog popped with, once it has.
  var done = false;
  String? value;

  Future<void> open(WidgetTester tester, {String? note}) async {
    done = false;
    value = null;
    useViewSize(tester, const Size(400, 800));
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
                  showRsvpNoteDialog(context, note: note).then((result) {
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

  Finder field() => find.byKey(EventDetailScreen.rsvpNoteFieldKey);

  Future<void> enter(WidgetTester tester, String text) async {
    await tester.enterText(field(), text);
    await tester.pumpAndSettle();
  }

  Future<void> save(WidgetTester tester) async {
    await tester.tap(find.byKey(EventDetailScreen.rsvpNoteSaveKey));
    await tester.pumpAndSettle();
  }

  String? shown(WidgetTester tester) => tester
      .widget<EditableText>(
        find.descendant(of: field(), matching: find.byType(EditableText)),
      )
      .controller
      .text;

  testWidgets('prefills the note', (tester) async {
    await open(tester, note: 'Running late');

    expect(find.text('Your note'), findsOneWidget);
    expect(
      find.text("Everyone who can see who's coming can read it."),
      findsOneWidget,
    );
    expect(find.text('Note'), findsOneWidget);
    expect(shown(tester), 'Running late');
  });

  testWidgets('starts empty with no note', (tester) async {
    await open(tester);

    expect(shown(tester), '');
  });

  testWidgets('Cancel answers null', (tester) async {
    await open(tester, note: 'Running late');
    await enter(tester, 'Bringing snacks');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(done, isTrue);
    expect(value, isNull);
  });

  testWidgets('Save answers the trimmed note', (tester) async {
    await open(tester);
    await enter(tester, '  Bringing snacks  ');
    await save(tester);

    expect(done, isTrue);
    expect(value, 'Bringing snacks');
  });

  testWidgets("an emptied note answers ''", (tester) async {
    await open(tester, note: 'Running late');
    await enter(tester, '   ');
    await save(tester);

    expect(done, isTrue);
    expect(value, '');
  });

  testWidgets('takes a note of any length', (tester) async {
    await open(tester);
    // Longer than a cancel's reason may be: the server takes any note.
    await enter(tester, 'a' * 2000);
    await save(tester);

    expect(done, isTrue);
    expect(value, 'a' * 2000);
  });

  testWidgets('Save is not drawn as destructive', (tester) async {
    await open(tester);

    final style = tester
        .widget<TextButton>(find.byKey(EventDetailScreen.rsvpNoteSaveKey))
        .style;
    expect(style, isNull);
  });
}
