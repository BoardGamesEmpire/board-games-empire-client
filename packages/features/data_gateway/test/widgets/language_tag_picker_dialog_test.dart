import 'dart:async';

import 'package:data_gateway/data_gateway.dart';
import 'package:data_gateway/l10n/data_gateway_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/semantics.dart' show SemanticsData, SemanticsNode;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/fake_data_gateway_remote.dart';

void main() {
  late FakeDataGatewayRemote remote;

  /// What the picker answered, and whether it has answered at all.
  LanguageTagRef? picked;
  var answered = false;

  final t1 = languageTag('t1', name: 'Czech', tag: 'cs');
  final t2 = languageTag('t2', name: 'Slovak', tag: 'sk');
  final t3 = languageTag('t3', name: 'Polish', tag: 'pl');
  final portuguese = languageTag(
    'pt',
    name: 'Portuguese (Brazil)',
    tag: 'pt-BR',
  );

  const openKey = Key('open_picker');
  final searchField = find.byKey(LanguageTagPickerDialog.searchKey);
  final moreButton = find.byKey(LanguageTagPickerDialog.moreKey);
  final retryButton = find.byKey(LanguageTagPickerDialog.retryKey);
  final cancelButton = find.byKey(LanguageTagPickerDialog.cancelKey);
  final emptyText = find.byKey(LanguageTagPickerDialog.emptyKey);

  /// What the eye sees as the dialog. Not the `AlertDialog` itself, which
  /// fills the whole route.
  final dialogSurface = find
      .descendant(of: find.byType(AlertDialog), matching: find.byType(Material))
      .first;
  Finder row(LanguageTagRef tag) =>
      find.byKey(LanguageTagPickerDialog.rowKey(tag.id));

  const loadingText = 'Loading languages…';
  const failedText = "Couldn't load languages.";

  /// The focus node of the control around [label], the one keyboard focus
  /// lands on: `Focus.of` looks above the element it is given, so it is given
  /// something inside the control.
  FocusNode focusAround(WidgetTester tester, Finder label) =>
      Focus.of(tester.element(label));

  setUp(() {
    remote = FakeDataGatewayRemote();
    picked = null;
    answered = false;
  });

  /// A page that lists [tags] and answers every read with it.
  void listing(List<LanguageTagRef> tags) =>
      remote.onFetchLanguageTags = (_, _, _) async => tagPageOf(tags);

  /// Holds every read until the test completes the one it wants.
  Completer<PaginatedResult<LanguageTagRef>> hold() {
    final held = Completer<PaginatedResult<LanguageTagRef>>();
    remote.onFetchLanguageTags = (_, _, _) => held.future;
    return held;
  }

  Widget app({
    String value = 'Czech',
    TextScaler textScaler = TextScaler.noScaling,
  }) => MaterialApp(
    theme: BgeTheme.light(),
    localizationsDelegates: DataGatewayLocalizations.localizationsDelegates,
    supportedLocales: DataGatewayLocalizations.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: textScaler),
      child: child!,
    ),
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: FilledButton(
            key: openKey,
            onPressed: () async {
              picked = await showLanguageTagPicker(
                context,
                remote: remote,
                value: value,
              );
              answered = true;
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );

  /// Opens the picker over a page, and lets it fade in.
  ///
  /// Doesn't settle: a spinner that is still showing never lets it.
  Future<void> open(
    WidgetTester tester, {
    String value = 'Czech',
    TextScaler textScaler = TextScaler.noScaling,
  }) async {
    await tester.pumpWidget(app(value: value, textScaler: textScaler));
    await tester.tap(find.byKey(openKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// A widget test that runs with semantics on.
  ///
  /// The handle is closed inside the test, in a `finally`: the framework
  /// checks for one left open before any tear-down runs.
  void testSemantics(
    String description,
    Future<void> Function(WidgetTester tester) body,
  ) => testWidgets(description, (tester) async {
    final handle = tester.ensureSemantics();
    try {
      await body(tester);
    } finally {
      handle.dispose();
    }
  });

  /// Every node of the semantics tree that assistive tech finds, as one each.
  ///
  /// Not the nodes merged up into another: a row's `MergeSemantics` leaves
  /// its parts in the tree, flagged as merged, and they are not stops of
  /// their own.
  List<SemanticsData> semantics(WidgetTester tester) {
    final nodes = <SemanticsData>[];
    void collect(SemanticsNode node) {
      if (!node.isMergedIntoParent) nodes.add(node.getSemanticsData());
      node.visitChildren((child) {
        collect(child);
        return true;
      });
    }

    tester.binding.rootPipelineOwner.visitChildren((owner) {
      final root = owner.semanticsOwner?.rootSemanticsNode;
      if (root != null) collect(root);
    });
    return nodes;
  }

  /// The labels of the live regions that say [label].
  List<String> liveRegionsSaying(WidgetTester tester, String label) => [
    for (final node in semantics(tester))
      if (node.flagsCollection.isLiveRegion && node.label.contains(label))
        node.label,
  ];

  group('choosing', () {
    testWidgets('choosing a row returns its tag', (tester) async {
      listing([t1, t2]);
      await open(tester);
      await tester.pumpAndSettle();

      await tester.tap(row(t1));
      await tester.pumpAndSettle();

      expect(answered, isTrue);
      expect(picked, t1);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('a later row returns its own tag', (tester) async {
      listing([t1, t2]);
      await open(tester);
      await tester.pumpAndSettle();

      await tester.tap(row(t2));
      await tester.pumpAndSettle();

      expect(picked, t2);
    });

    testWidgets('the dialog takes the room the screen leaves it', (
      tester,
    ) async {
      listing([t1]);
      // A tiny text size. The test font draws every glyph one em wide, so at
      // any real size the title alone is wider than a dialog can be and hides
      // what the content asks for.
      await open(tester, textScaler: const TextScaler.linear(0.1));
      await tester.pumpAndSettle();

      // A short list does not shrink it to the width of its widest row: it is
      // as wide as the theme lets any dialog be.
      expect(
        tester.getRect(dialogSurface).width,
        BgeTokens.standard.contentMaxWidth,
      );
    });

    testWidgets('a row says the tag name, and under it the tag', (
      tester,
    ) async {
      listing([portuguese]);
      await open(tester);
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: row(portuguese),
          matching: find.text('Portuguese (Brazil)'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: row(portuguese), matching: find.text('pt-BR')),
        findsOneWidget,
      );
      expect(
        tester.getTopLeft(find.text('Portuguese (Brazil)')).dy,
        lessThan(tester.getTopLeft(find.text('pt-BR')).dy),
      );
    });

    testWidgets('dismissing returns null', (tester) async {
      listing([t1]);
      await open(tester);
      await tester.pumpAndSettle();

      await tester.tap(cancelButton);
      await tester.pumpAndSettle();

      expect(answered, isTrue);
      expect(picked, isNull);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('tapping outside the dialog dismisses it, returning null', (
      tester,
    ) async {
      listing([t1]);
      await open(tester);
      await tester.pumpAndSettle();

      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();

      expect(answered, isTrue);
      expect(picked, isNull);
    });

    testWidgets('cancel is named Cancel', (tester) async {
      listing([t1]);
      await open(tester);
      await tester.pumpAndSettle();

      expect(
        find.descendant(of: cancelButton, matching: find.text('Cancel')),
        findsOneWidget,
      );
    });

    testWidgets('the title names the value being linked', (tester) async {
      listing([t1]);
      await open(tester, value: 'Czech');
      await tester.pumpAndSettle();

      expect(find.text('Link "Czech" to a language'), findsOneWidget);
    });

    testSemantics('a screen reader is told what the dialog is for as it '
        'opens', (tester) async {
      listing([t1]);
      await open(tester, value: 'Czech');
      await tester.pumpAndSettle();

      final naming = [
        for (final node in semantics(tester))
          if (node.flagsCollection.namesRoute) node.label,
      ];
      expect(naming, ['Link "Czech" to a language']);
    });

    testWidgets('choosing a row while a search is pending sends nothing more, '
        'and leaves no timer running', (tester) async {
      listing([t1, t2]);
      await open(tester);
      await tester.pumpAndSettle();
      await tester.enterText(searchField, 'po');

      await tester.tap(row(t1));
      // Long enough for the dialog to leave, short of the debounce: its
      // cubit closes with the route, and the search waiting on the clock
      // goes with it. The framework fails a test that ends with a timer
      // still pending.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();

      expect(picked, t1);
      expect(find.byType(AlertDialog), findsNothing);
      expect(remote.calls, ['fetchLanguageTags(null, 1)']);
    });
  });

  group('the field', () {
    testSemantics('the field is focused on open, and has a label', (
      tester,
    ) async {
      listing([t1]);
      await open(tester);
      await tester.pumpAndSettle();

      final editable = tester.state<EditableTextState>(
        find.descendant(of: searchField, matching: find.byType(EditableText)),
      );
      expect(editable.widget.focusNode.hasPrimaryFocus, isTrue);
      expect(find.text('Search languages'), findsOneWidget);
      final fields = [
        for (final node in semantics(tester))
          if (node.flagsCollection.isTextField) node,
      ];
      expect(fields, hasLength(1));
      expect(fields.single.label, 'Search languages');
    });

    testWidgets('the field does not autocorrect the names of languages', (
      tester,
    ) async {
      listing([t1]);
      await open(tester);
      await tester.pumpAndSettle();

      expect(tester.widget<TextField>(searchField).autocorrect, isFalse);
    });

    testWidgets('typing searches after the debounce, and replaces the rows', (
      tester,
    ) async {
      remote.onFetchLanguageTags = (name, _, _) async =>
          tagPageOf(name == null ? [t1, t2] : [t3]);
      await open(tester);
      await tester.pumpAndSettle();

      await tester.enterText(searchField, ' po ');
      await tester.pump(const Duration(milliseconds: 299));
      expect(remote.calls, [
        'fetchLanguageTags(null, 1)',
      ], reason: 'the default debounce is 300 ms');
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pumpAndSettle();

      expect(remote.calls, [
        'fetchLanguageTags(null, 1)',
        'fetchLanguageTags(po, 1)',
      ]);
      expect(row(t3), findsOneWidget);
      expect(row(t1), findsNothing);
      expect(row(t2), findsNothing);
    });

    testWidgets('a name with no match shows the empty text', (tester) async {
      remote.onFetchLanguageTags = (name, _, _) async =>
          tagPageOf(name == null ? [t1] : []);
      await open(tester);
      await tester.pumpAndSettle();

      await tester.enterText(searchField, 'zzz');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      expect(emptyText, findsOneWidget);
      expect(row(t1), findsNothing);
    });
  });

  group('what the list says', () {
    testSemantics('an empty result says so', (tester) async {
      listing([]);
      await open(tester);
      await tester.pumpAndSettle();

      expect(emptyText, findsOneWidget);
      expect(find.text('No languages match'), findsOneWidget);
      expect(moreButton, findsNothing);
      expect(retryButton, findsNothing);
      expect(liveRegionsSaying(tester, 'No languages match'), [
        'No languages match',
      ], reason: 'a search that finds nothing is told, not left silent');
    });

    testWidgets('a page of languages with no tags is not empty, and has more', (
      tester,
    ) async {
      remote.onFetchLanguageTags = (_, page, _) async =>
          page == 1 ? tagPageOf([], hasMore: true) : tagPageOf([t1], page: 2);
      await open(tester);
      await tester.pumpAndSettle();

      expect(emptyText, findsNothing);
      expect(find.text('No languages match'), findsNothing);
      expect(find.text('Show more'), findsOneWidget);

      await tester.tap(moreButton);
      await tester.pumpAndSettle();

      expect(row(t1), findsOneWidget);
      expect(moreButton, findsNothing);
      expect(emptyText, findsNothing);
    });

    testWidgets('while the first page loads there is no empty text', (
      tester,
    ) async {
      hold();
      await open(tester);

      expect(emptyText, findsNothing);
      expect(find.text('No languages match'), findsNothing);
    });

    testWidgets('after a failed read there is no empty text', (tester) async {
      remote.onFetchLanguageTags = (_, _, _) async => throw unreachable();
      await open(tester);
      await tester.pumpAndSettle();

      expect(emptyText, findsNothing);
      expect(find.text(failedText), findsOneWidget);
    });

    testWidgets('Show more appends the next page, and goes with the last', (
      tester,
    ) async {
      remote.onFetchLanguageTags = (_, page, _) async =>
          page == 1 ? tagPageOf([t1], hasMore: true) : tagPageOf([t2], page: 2);
      await open(tester);
      await tester.pumpAndSettle();
      expect(row(t2), findsNothing);

      await tester.tap(moreButton);
      await tester.pumpAndSettle();

      expect(row(t1), findsOneWidget);
      expect(row(t2), findsOneWidget);
      expect(moreButton, findsNothing);
      expect(remote.calls, [
        'fetchLanguageTags(null, 1)',
        'fetchLanguageTags(null, 2)',
      ]);
    });
  });

  group('while it loads', () {
    testSemantics('the first page is announced through a live region', (
      tester,
    ) async {
      final held = hold();
      await open(tester);

      expect(liveRegionsSaying(tester, loadingText), [loadingText]);
      expect(find.byKey(LanguageTagPickerDialog.loadingKey), findsOneWidget);

      held.complete(tagPageOf([t1]));
      await tester.pumpAndSettle();

      expect(liveRegionsSaying(tester, loadingText), isEmpty);
      expect(find.byKey(LanguageTagPickerDialog.loadingKey), findsNothing);
    });

    testSemantics('a search that is loading is announced again', (
      tester,
    ) async {
      final later = Completer<PaginatedResult<LanguageTagRef>>();
      remote.onFetchLanguageTags = (name, _, _) =>
          name == null ? Future.value(tagPageOf([t1])) : later.future;
      await open(tester);
      await tester.pumpAndSettle();
      expect(liveRegionsSaying(tester, loadingText), isEmpty);

      await tester.enterText(searchField, 'po');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();

      expect(liveRegionsSaying(tester, loadingText), [loadingText]);
      expect(row(t1), findsNothing);

      later.complete(tagPageOf([t3]));
      await tester.pumpAndSettle();
      expect(row(t3), findsOneWidget);
    });

    testSemantics('a next page is announced through a live region, and its '
        'button keeps its place and its focus', (tester) async {
      final held = Completer<PaginatedResult<LanguageTagRef>>();
      remote.onFetchLanguageTags = (_, page, _) => page == 1
          ? Future.value(tagPageOf([t1], hasMore: true))
          : held.future;
      await open(tester);
      await tester.pumpAndSettle();
      expect(liveRegionsSaying(tester, loadingText), isEmpty);

      final focus = focusAround(
        tester,
        find.descendant(of: moreButton, matching: find.text('Show more')),
      );
      focus.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump();

      expect(liveRegionsSaying(tester, loadingText), [loadingText]);
      expect(row(t1), findsOneWidget, reason: 'the rows stay while it loads');
      expect(moreButton, findsOneWidget);
      expect(
        focus.hasPrimaryFocus,
        isTrue,
        reason: 'a control that goes mid-press takes the focus with it',
      );

      // Pressed again while out: nothing more is asked for.
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(remote.calls, [
        'fetchLanguageTags(null, 1)',
        'fetchLanguageTags(null, 2)',
      ]);

      held.complete(tagPageOf([t2], page: 2, hasMore: true));
      await tester.pumpAndSettle();

      expect(liveRegionsSaying(tester, loadingText), isEmpty);
      expect(row(t2), findsOneWidget);
      expect(
        focus.hasPrimaryFocus,
        isTrue,
        reason: 'the button is still there for another page, with its focus',
      );
    });
  });

  group('when a read fails', () {
    testSemantics(
      'the first page says so and offers a retry, which reads again',
      (tester) async {
        var reads = 0;
        remote.onFetchLanguageTags = (_, _, _) async =>
            ++reads == 1 ? throw unreachable() : tagPageOf([t1]);
        await open(tester);
        await tester.pumpAndSettle();

        expect(find.byKey(LanguageTagPickerDialog.errorKey), findsOneWidget);
        expect(find.text(failedText), findsOneWidget);
        // An icon and words, not color alone.
        expect(
          find.descendant(
            of: find.byKey(LanguageTagPickerDialog.errorKey),
            matching: find.byIcon(Icons.error_outline),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(of: retryButton, matching: find.text('Try again')),
          findsOneWidget,
        );
        expect(liveRegionsSaying(tester, failedText), isNotEmpty);
        expect(moreButton, findsNothing);

        await tester.tap(retryButton);
        await tester.pumpAndSettle();

        expect(row(t1), findsOneWidget);
        expect(find.text(failedText), findsNothing);
        expect(retryButton, findsNothing);
        expect(remote.calls, [
          'fetchLanguageTags(null, 1)',
          'fetchLanguageTags(null, 1)',
        ]);
      },
    );

    testWidgets('a first-page retry pressed from the keyboard goes, and focus '
        'goes back to the field', (tester) async {
      // Nothing here moves it: the dialog's focus scope hands focus back to
      // the node it last had before the button, and the field had it first.
      var reads = 0;
      final held = Completer<PaginatedResult<LanguageTagRef>>();
      remote.onFetchLanguageTags = (_, _, _) =>
          ++reads == 1 ? Future.error(unreachable()) : held.future;
      await open(tester);
      await tester.pumpAndSettle();

      focusAround(
        tester,
        find.descendant(of: retryButton, matching: find.text('Try again')),
      ).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      final field = tester
          .widget<EditableText>(
            find.descendant(
              of: searchField,
              matching: find.byType(EditableText),
            ),
          )
          .focusNode;
      expect(retryButton, findsNothing);
      expect(field.hasPrimaryFocus, isTrue);

      held.complete(tagPageOf([t1]));
      await tester.pumpAndSettle();

      expect(row(t1), findsOneWidget);
      expect(field.hasPrimaryFocus, isTrue);
    });

    testSemantics('a next page that fails keeps the rows, says so, and its '
        'button tries again', (tester) async {
      var mores = 0;
      remote.onFetchLanguageTags = (_, page, _) async {
        if (page == 1) return tagPageOf([t1], hasMore: true);
        if (++mores == 1) throw unreachable();
        return tagPageOf([t2], page: 2);
      };
      await open(tester);
      await tester.pumpAndSettle();

      await tester.tap(moreButton);
      await tester.pumpAndSettle();

      expect(find.text(failedText), findsOneWidget);
      expect(liveRegionsSaying(tester, failedText), isNotEmpty);
      expect(row(t1), findsOneWidget);
      expect(
        find.descendant(of: moreButton, matching: find.text('Try again')),
        findsOneWidget,
        reason: 'the button that failed is the retry',
      );

      await tester.tap(moreButton);
      await tester.pumpAndSettle();

      expect(find.text(failedText), findsNothing);
      expect(row(t1), findsOneWidget);
      expect(row(t2), findsOneWidget);
      expect(remote.calls, [
        'fetchLanguageTags(null, 1)',
        'fetchLanguageTags(null, 2)',
        'fetchLanguageTags(null, 2)',
      ]);
    });

    testWidgets('a next page that fails after a page with no tags still '
        'offers to try again', (tester) async {
      var mores = 0;
      remote.onFetchLanguageTags = (_, page, _) async {
        if (page == 1) return tagPageOf([], hasMore: true);
        if (++mores == 1) throw unreachable();
        return tagPageOf([t1], page: 2);
      };
      await open(tester);
      await tester.pumpAndSettle();

      await tester.tap(moreButton);
      await tester.pumpAndSettle();
      expect(find.text(failedText), findsOneWidget);
      expect(emptyText, findsNothing);

      await tester.tap(moreButton);
      await tester.pumpAndSettle();
      expect(row(t1), findsOneWidget);
    });
  });

  group('for assistive tech and the keyboard', () {
    testSemantics(
      'a row reads as one button, naming the language and its tag',
      (tester) async {
        listing([portuguese, t1]);
        await open(tester);
        await tester.pumpAndSettle();

        final byName = tester.getSemantics(find.text('Portuguese (Brazil)'));
        final byTag = tester.getSemantics(find.text('pt-BR'));

        expect(byTag, same(byName), reason: 'one node, not a name then a tag');
        expect(
          byName,
          isSemantics(
            label: 'Portuguese (Brazil)\npt-BR',
            isButton: true,
            isFocusable: true,
            hasTapAction: true,
          ),
        );
        final inThatRow = [
          for (final node in semantics(tester))
            if (node.label.contains('pt-BR') ||
                node.label.contains('Portuguese (Brazil)'))
              node.label,
        ];
        expect(inThatRow, ['Portuguese (Brazil)\npt-BR']);
      },
    );

    testSemantics(
      'the buttons a reader finds are the rows and Cancel, each named',
      (tester) async {
        listing([portuguese, t1]);
        await open(tester);
        await tester.pumpAndSettle();

        // No row brings a second, unlabelled button of its own.
        expect(
          [
            for (final node in semantics(tester))
              if (node.flagsCollection.isButton) node.label,
          ],
          ['Portuguese (Brazil)\npt-BR', 'Czech\ncs', 'Cancel'],
        );
      },
    );

    testWidgets('Tab goes from the field to the rows, and Enter on a focused '
        'row chooses it', (tester) async {
      listing([t1, t2]);
      await open(tester);
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(
        focusAround(
          tester,
          find.descendant(of: row(t1), matching: find.text('Czech')),
        ).hasPrimaryFocus,
        isTrue,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(picked, t1);
    });

    testWidgets('Enter on the second row chooses the second', (tester) async {
      listing([t1, t2]);
      await open(tester);
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(
        focusAround(
          tester,
          find.descendant(of: row(t2), matching: find.text('Slovak')),
        ).hasPrimaryFocus,
        isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(picked, t2);
    });
  });

  group('leaving', () {
    testWidgets('dismissing with the first page still out throws nothing when '
        'it lands', (tester) async {
      final held = hold();
      await open(tester);

      await tester.tap(cancelButton);
      await tester.pumpAndSettle();
      held.complete(tagPageOf([t1]));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(answered, isTrue);
      expect(picked, isNull);
    });

    testWidgets('dismissing with the first page still out throws nothing when '
        'it fails', (tester) async {
      final held = hold();
      await open(tester);

      await tester.tap(cancelButton);
      await tester.pumpAndSettle();
      held.completeError(unreachable());
      await tester.pump();

      expect(tester.takeException(), isNull);
    });

    testWidgets('choosing a row with a next page still out throws nothing '
        'when it lands', (tester) async {
      final held = Completer<PaginatedResult<LanguageTagRef>>();
      remote.onFetchLanguageTags = (_, page, _) => page == 1
          ? Future.value(tagPageOf([t1], hasMore: true))
          : held.future;
      await open(tester);
      await tester.pumpAndSettle();
      await tester.tap(moreButton);
      await tester.pump();

      await tester.tap(row(t1));
      await tester.pumpAndSettle();
      held.complete(tagPageOf([t2], page: 2));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(picked, t1);
    });
  });

  group('at a large text size on a small screen', () {
    final longName = languageTag(
      'long',
      name:
          'A language name that goes on and on and on and then keeps going '
          'for a good while after that',
      tag: 'x-a-very-long-private-use-tag-that-has-no-break-in-it-at-all',
    );
    const longValue =
        'Traditional Chinese as it is spoken in Hong Kong and written in the '
        'old way';

    /// The room a phone leaves: 320 by 568, with a 300-tall keyboard.
    const screen = Size(320, 568);
    const keyboard = FakeViewPadding(bottom: 300);
    const aboveKeyboard = 568.0 - 300;
    const twiceTheText = TextScaler.linear(2);

    void smallScreen(WidgetTester tester, {bool keyboardUp = true}) {
      tester.view.physicalSize = screen;
      tester.view.devicePixelRatio = 1;
      if (keyboardUp) tester.view.viewInsets = keyboard;
      addTearDown(tester.view.reset);
    }

    /// What the dialog scrolls in: the title, the field and the rows.
    final viewport = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(SingleChildScrollView),
    );

    testWidgets('a long language name does not overflow at 200% text on 320 '
        'wide', (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      listing([longName, t1, t2]);
      await open(tester, textScaler: twiceTheText);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      final dialog = tester.getRect(dialogSurface);
      expect(dialog.left, greaterThanOrEqualTo(0));
      expect(dialog.right, lessThanOrEqualTo(320));
      expect(
        dialog.width,
        320 - 80,
        reason: 'the room the screen leaves, past 40 either side',
      );
      await tester.ensureVisible(row(longName));
      await tester.pump();
      final rowBox = tester.getRect(row(longName));
      expect(rowBox.left, greaterThanOrEqualTo(dialog.left));
      expect(rowBox.right, lessThanOrEqualTo(dialog.right));
    });

    testWidgets('does not overflow at 200% text on 320 by 568 with the '
        'keyboard up and a long value in its title', (tester) async {
      smallScreen(tester);
      listing([longName, t1, t2]);

      await open(tester, value: longValue, textScaler: twiceTheText);
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      // What the dialog scrolls in ends above the keyboard, and Cancel stays
      // in view beneath it, however long the title is.
      expect(tester.getRect(viewport).bottom, lessThanOrEqualTo(aboveKeyboard));
      expect(tester.getRect(cancelButton).top, greaterThanOrEqualTo(0));
      expect(
        tester.getRect(cancelButton).bottom,
        lessThanOrEqualTo(aboveKeyboard),
      );
      // The field has focus, so the line typed into was scrolled into view
      // when the dialog opened, past a title taller than the room there is.
      final room = tester.getRect(viewport);
      final typing = tester.getRect(
        find.descendant(of: searchField, matching: find.byType(EditableText)),
      );
      expect(typing.top, greaterThanOrEqualTo(room.top - 1));
      expect(typing.bottom, lessThanOrEqualTo(room.bottom + 1));
      // What the search matches is said under the field. It wraps over lines
      // inside the dialog, rather than being cut to one, and scrolls into view
      // with the rest. The theme lets it run to six lines (#499), which real
      // fonts don't reach here; the test font's glyphs are about twice as
      // wide.
      final helper = find.text('Search by language name, such as Portuguese');
      expect(helper, findsOneWidget);
      final paragraph = tester.renderObject<RenderParagraph>(helper);
      final lines = {
        for (final box in paragraph.getBoxesForSelection(
          const TextSelection(baseOffset: 0, extentOffset: 43),
        ))
          box.top,
      };
      expect(lines.length, greaterThan(1));
      final dialog = tester.getRect(dialogSurface);
      expect(tester.getRect(helper).left, greaterThanOrEqualTo(dialog.left));
      expect(tester.getRect(helper).right, lessThanOrEqualTo(dialog.right));
      await tester.ensureVisible(helper);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(tester.getRect(helper).top, greaterThanOrEqualTo(room.top - 1));
      expect(tester.getRect(helper).top, lessThan(room.bottom));
    });

    testWidgets('the title, the field and the rows scroll together, so each '
        'can be brought into view above the keyboard', (tester) async {
      smallScreen(tester);
      remote.onFetchLanguageTags = (_, page, _) async => page == 1
          ? tagPageOf([longName, t1, t2], hasMore: true)
          : tagPageOf([t3], page: 2);
      await open(tester, value: longValue, textScaler: twiceTheText);
      await tester.pumpAndSettle();
      final room = tester.getRect(viewport);

      for (final part in [searchField, row(longName), row(t2), moreButton]) {
        await tester.ensureVisible(part);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final rect = tester.getRect(part);
        // Its start is in view, so a reader can begin on it and scroll on
        // through the rest: a row can be taller than the room there is.
        expect(rect.top, greaterThanOrEqualTo(room.top - 1), reason: '$part');
        expect(rect.top, lessThan(room.bottom), reason: '$part');
        if (rect.height <= room.height) {
          expect(
            rect.bottom,
            lessThanOrEqualTo(room.bottom + 1),
            reason: '$part',
          );
        }
      }

      await tester.tap(moreButton);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(row(t3));
      await tester.pumpAndSettle();
      await tester.tap(row(t3));
      await tester.pumpAndSettle();
      expect(picked, t3);
    });

    testWidgets('the failure and the loading line fit at 200% text on 320 '
        'wide', (tester) async {
      smallScreen(tester);
      var mores = 0;
      remote.onFetchLanguageTags = (_, page, _) async {
        if (page == 1) return tagPageOf([t1], hasMore: true);
        if (++mores == 1) throw unreachable();
        return tagPageOf([t2], page: 2);
      };
      await open(tester, textScaler: twiceTheText);
      await tester.pumpAndSettle();
      await tester.ensureVisible(moreButton);
      await tester.tap(moreButton);
      await tester.pumpAndSettle();

      expect(find.text(failedText), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
