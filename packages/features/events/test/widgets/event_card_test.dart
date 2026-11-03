import 'package:bge_test_support/widgets.dart';
import 'package:events/events.dart';
import 'package:events/l10n/events_localizations.dart';
import 'package:events/src/widgets/event_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/event_list_items.dart';

/// Scales as Android 14 and later do at 200%: text sizes double, and a size
/// past 100, which no text uses, barely grows. Read as a font size, 240 would
/// stay 240.
class _AndroidNonlinear extends TextScaler {
  const _AndroidNonlinear();

  @override
  double scale(double fontSize) => fontSize < 100 ? fontSize * 2 : fontSize;

  @override
  double get textScaleFactor => 2;
}

/// One upcoming event on home, as a card in a row that moves side to side
/// (#669): what the overview's row says, inside an edge, at a width that grows
/// with the text up to the row's.
void main() {
  // Local, as the device's clock reads it.
  final now = DateTime(2026, 10, 23, 18);
  const longTitle =
      'An evening of very long cooperative campaign games, '
      'with snacks, in the back room';

  EventRow full({String title = 'Game night'}) => EventRow(
    event: item('e-1', title: title).event,
    group: EventGroup.upcoming,
    date: confirmed('o-1', DateTime(2026, 11, 6, 19, 30)),
    venue: 'Back room',
    householdName: 'The Smiths',
    rsvp: EventParticipationStatus.attending,
  );

  EventRow bare({bool beingChosen = false}) => EventRow(
    event: item('e-1').event,
    group: EventGroup.planning,
    dateBeingChosen: beingChosen,
  );

  final boundary = GlobalKey();

  Future<void> pumpCard(
    WidgetTester tester,
    EventRow row, {
    double maxWidth = 1000,
    double textScale = 1,
    TextScaler? textScaler,
    void Function(BuildContext context, String eventId)? onOpen,
  }) {
    const size = Size(1200, 800);
    useViewSize(tester, size);
    return tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(
          size: size,
          textScaler: textScaler ?? TextScaler.linear(textScale),
        ),
        child: MaterialApp(
          theme: BgeTheme.light(),
          locale: const Locale('en', 'US'),
          localizationsDelegates: EventsLocalizations.localizationsDelegates,
          supportedLocales: EventsLocalizations.supportedLocales,
          // In a page that scrolls, as home is: at 2.0 text a long title runs
          // taller than the window.
          home: Scaffold(
            body: SingleChildScrollView(
              child: RepaintBoundary(
                key: boundary,
                child: Align(
                  alignment: Alignment.topLeft,
                  child: EventCard(
                    row: row,
                    now: () => now,
                    maxWidth: maxWidth,
                    onOpen: onOpen,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Finder inCard(Finder matching) =>
      find.descendant(of: find.byType(EventCard), matching: matching);

  double widthOf(WidgetTester tester) =>
      tester.getSize(find.byType(EventCard)).width;

  /// Whether the primary focus is the card or anything inside it.
  bool focusInCard(WidgetTester tester) {
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused == null) return false;
    final card = tester.element(find.byType(EventCard));
    if (focused == card) return true;
    var inside = false;
    focused.visitAncestorElements((element) {
      inside = element == card;
      return !inside;
    });
    return inside;
  }

  /// The colour drawn now just inside the card's left edge, halfway down: on
  /// its outline, and on the ring when there is one.
  Future<Color> onTheEdge(WidgetTester tester) async {
    final card = tester.getRect(find.byType(EventCard));
    final render =
        boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final origin = render.localToGlobal(Offset.zero);
    final (width, bytes) = (await tester.runAsync(() async {
      final image = await render.toImage();
      return (image.width, (await image.toByteData())!);
    }))!;
    final x = (card.left - origin.dx).floor();
    final y = (card.center.dy - origin.dy).floor();
    final at = (y * width + x) * 4;
    return Color.fromARGB(
      bytes.getUint8(at + 3),
      bytes.getUint8(at),
      bytes.getUint8(at + 1),
      bytes.getUint8(at + 2),
    );
  }

  testWidgets(
    'shows the title, when it is, and the venue, household and RSVP',
    (tester) async {
      await pumpCard(tester, full());

      expect(find.text('Game night'), findsOneWidget);
      expect(find.text('Fri, Nov 6 · 7:30 PM'), findsOneWidget);
      expect(find.text('Back room · The Smiths · Going'), findsOneWidget);
    },
  );

  testWidgets('no venue, household or RSVP draws no details line', (
    tester,
  ) async {
    await pumpCard(tester, bare());

    // The title and the date line, and nothing under them.
    expect(inCard(find.byType(Text)), findsNWidgets(2));
  });

  testWidgets(
    'an event with no date says the date is being chosen, or that it has none',
    (tester) async {
      await pumpCard(tester, bare(beingChosen: true));
      expect(find.text('Date being chosen'), findsOneWidget);

      await pumpCard(tester, bare());
      expect(find.text('No date yet'), findsOneWidget);
    },
  );

  testWidgets('is one semantics node, with the spoken separator', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pumpCard(tester, full(), onOpen: (_, _) {});

    final card = tester.getSemantics(find.byType(EventCard));
    final label = card.getSemanticsData().label;
    expect(card.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    expect(label, contains('Game night'));
    expect(label, contains('Fri, Nov 6 · 7:30 PM'));
    // A screen reader would read the visual separator's symbol out.
    expect(label, contains('Back room, The Smiths, Going'));
    // Each line is merged into the card's node rather than a node of its own.
    for (final line in ['Game night', 'Back room · The Smiths · Going']) {
      expect(tester.getSemantics(find.text(line)).id, card.id, reason: line);
    }
    handle.dispose();
  });

  group('width', () {
    testWidgets('is 240 wide at 1.0', (tester) async {
      await pumpCard(tester, full());

      expect(widthOf(tester), EventCard.baseWidth);
      expect(EventCard.baseWidth, 240);
    });

    testWidgets('is 360 wide at 1.5 with room', (tester) async {
      await pumpCard(tester, full(), textScale: 1.5);

      expect(widthOf(tester), 360);
    });

    testWidgets('grows as its title does where text scales nonlinearly, as on '
        'Android 14', (tester) async {
      await pumpCard(tester, full(), textScaler: const _AndroidNonlinear());

      expect(widthOf(tester), 2 * EventCard.baseWidth);
    });

    testWidgets('stops at maxWidth: 272 at 2.0 with maxWidth 272', (
      tester,
    ) async {
      await pumpCard(tester, full(), textScale: 2, maxWidth: 272);

      expect(widthOf(tester), 272);
    });

    testWidgets('a long title wraps and is shown whole at 2.0 and 272 wide', (
      tester,
    ) async {
      await pumpCard(
        tester,
        full(title: longTitle),
        textScale: 2,
        maxWidth: 272,
      );

      expect(tester.takeException(), isNull);
      final title = tester.widget<Text>(find.text(longTitle));
      expect(title.maxLines, isNull);
      expect(title.overflow, isNull);
      // Wrapped, not cut: many lines tall, and inside the card.
      final titleRect = tester.getRect(find.text(longTitle));
      expect(titleRect.height, greaterThan(3 * 2 * 16));
      expect(
        tester.getRect(find.byType(EventCard)).bottom,
        greaterThan(titleRect.bottom),
      );
    });
  });

  group('opening', () {
    testWidgets('without onOpen it has no tap and is no focus stop', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpCard(tester, full());

      expect(
        tester
            .getSemantics(find.byType(EventCard))
            .getSemanticsData()
            .hasAction(SemanticsAction.tap),
        isFalse,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(focusInCard(tester), isFalse);
      handle.dispose();
    });

    testWidgets("with onOpen a tap calls it with the event's id", (
      tester,
    ) async {
      final opened = <String>[];
      await pumpCard(tester, full(), onOpen: (_, id) => opened.add(id));

      await tester.tap(find.byType(EventCard));

      expect(opened, ['e-1']);
    });

    testWidgets("keyboard focus draws the ring, a tap's focus doesn't", (
      tester,
    ) async {
      final colors = BgeTheme.light().colorScheme;
      await pumpCard(tester, full(), onOpen: (_, _) {});
      expect(await onTheEdge(tester), colors.outlineVariant);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      // One frame: the ring is there at once, not faded in.
      await tester.pump();
      expect(focusInCard(tester), isTrue);
      expect(await onTheEdge(tester), colors.primary);

      // A touch puts focus in touch mode, where an ink draws no focus either.
      await tester.tap(find.byType(EventCard));
      await tester.pump();
      expect(focusInCard(tester), isTrue);
      expect(await onTheEdge(tester), colors.outlineVariant);
    });
  });
}
