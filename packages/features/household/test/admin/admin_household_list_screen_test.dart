import 'dart:async';

import 'package:bge_test_support/access.dart';
import 'package:bge_test_support/widgets.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:household/household.dart';
import 'package:household/l10n/household_localizations.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/fake_admin_household_remote.dart';

const _onlineOnlyCopy = "Available when you're online";

typedef _Page = PaginatedResult<AdminHouseholdRow>;

const _forbidden = AdminHouseholdForbiddenException('no', statusCode: 403);
const _transient = AdminHouseholdTransientException('unreachable');
const _notFound = AdminHouseholdNotFoundException(
  'nothing to restore',
  statusCode: 404,
);

AdminHouseholdOwner _owner(String name) => AdminHouseholdOwner(
  userId: 'u_$name',
  username: name.toLowerCase(),
  displayName: name,
);

/// Rows h[from] to h[to], live.
List<AdminHouseholdRow> _rows(int from, int to) => [
  for (var i = from; i <= to; i++) adminRow('h$i'),
];

void main() {
  late FakeAdminHouseholdRemote remote;
  late FakeCallerAccessRepository access;
  late List<String> opened;

  final ada = adminRow('h_ada', name: "Ada's table", owners: [_owner('Ada')]);
  final bea = adminRow('h_bea', name: 'Bea games', memberCount: 1);
  final gone = adminRow(
    'h_gone',
    name: 'Old crew',
    deleted: true,
    memberCount: 4,
    owners: [_owner('Cy'), _owner('Di')],
  );
  final lost = adminRow('h_lost', name: 'Lost club', deleted: true);

  setUp(() {
    remote = FakeAdminHouseholdRemote();
    access = FakeCallerAccessRepository(
      FakeCallerAccessRepository.of({ResourceType.household: AccessExtent.all}),
    );
    opened = [];
  });

  /// The screen as the app reaches it. [offline] puts it under a
  /// connectivity scope following it, above the navigator, as the shell
  /// hosts it, so the dialog reads it too.
  Widget harness({ThemeData? theme, ValueListenable<bool>? offline}) =>
      MaterialApp(
        theme: theme ?? BgeTheme.light(),
        localizationsDelegates: HouseholdLocalizations.localizationsDelegates,
        supportedLocales: HouseholdLocalizations.supportedLocales,
        builder: offline == null
            ? null
            : (context, child) => ValueListenableBuilder<bool>(
                valueListenable: offline,
                child: child,
                builder: (context, isOffline, app) => BgeConnectivityScope(
                  offline: isOffline,
                  noticeShowing: isOffline,
                  onlineOnlyReason: _onlineOnlyCopy,
                  child: app!,
                ),
              ),
        home: AdminHouseholdListScreen(
          remote: remote,
          access: access,
          onOpen: (_, id) => opened.add(id),
        ),
      );

  Future<void> pumpScreen(
    WidgetTester tester, {
    ValueListenable<bool>? offline,
  }) async {
    await tester.pumpWidget(harness(offline: offline));
    await tester.pumpAndSettle();
  }

  /// Pumps through a menu's or a dialog's way in or out. Not a settle: a
  /// restore's spinner never stops.
  Future<void> pumpThrough(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
  }

  /// Waits out the bloc's pause after typing, and the read it starts.
  Future<void> settleSearch(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
  }

  /// The page's own scrollable, not the search field's.
  Finder pageScrollable() => find
      .descendant(
        of: find.byType(CustomScrollView),
        matching: find.byType(Scrollable),
      )
      .first;

  AdminHouseholdListBloc blocOf(WidgetTester tester) => tester
      .element(find.byKey(AdminHouseholdListScreen.searchKey))
      .read<AdminHouseholdListBloc>();

  /// Opens [menu] and picks the entry [label].
  Future<void> choose(WidgetTester tester, Key menu, String label) async {
    await tester.tap(find.byKey(menu));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(MenuItemButton, label));
    // The item runs its press after a frame.
    await tester.pump();
    await tester.pumpAndSettle();
  }

  /// The entries the open menu offers, in order.
  List<String> menuEntries(WidgetTester tester) => [
    for (final item in tester.widgetList<MenuItemButton>(
      find.byType(MenuItemButton),
    ))
      tester
          .widget<Text>(
            find.descendant(
              of: find.byWidget(item),
              matching: find.byType(Text),
            ),
          )
          .data!,
  ];

  /// When [row] was deleted, as the screen says it: on the device's clock,
  /// with the year.
  String deletedOn(WidgetTester tester, AdminHouseholdRow row) =>
      DateFormat.yMMMd('en').format(row.deletedAt!.toLocal());

  /// The words on [id]'s Restore button, which take its focus.
  Finder restoreWords(String id) => find.descendant(
    of: find.byKey(AdminHouseholdListScreen.restoreKey(id)),
    matching: find.text('Restore'),
  );

  /// Puts keyboard focus on the control around [label], as Tab would.
  Future<void> focusOn(WidgetTester tester, Finder label) async {
    Focus.of(tester.element(label)).requestFocus();
    await tester.pump();
  }

  /// Whether keyboard focus is on [control], or inside it.
  bool focusIsIn(WidgetTester tester, Finder control) {
    final focused = FocusManager.instance.primaryFocus?.context;
    if (focused == null) return false;
    final target = tester.element(control);
    if (identical(focused, target)) return true;
    var inside = false;
    focused.visitAncestorElements((ancestor) {
      inside = identical(ancestor, target);
      return !inside;
    });
    return inside;
  }

  /// Expects keyboard focus on the node nearest above the text [label], and
  /// not on the page's scope, where focus falls when its control goes.
  void expectFocusOn(WidgetTester tester, Finder label) {
    final focused = FocusManager.instance.primaryFocus;
    expect(focused, isNot(isA<FocusScopeNode>()));
    expect(
      focused,
      same(Focus.of(tester.element(label), createDependency: false)),
    );
  }

  Finder dismiss() => find.descendant(
    of: find.byKey(AdminHouseholdListScreen.outcomeKey),
    matching: find.text('Dismiss'),
  );

  Finder heading() => find.descendant(
    of: find.byType(AppBar),
    matching: find.text('Households'),
  );

  /// Presses [id]'s Restore from the keyboard, so focus is on it, and
  /// confirms in the dialog that opens.
  Future<void> restoreFromKeyboard(WidgetTester tester, String id) async {
    await focusOn(tester, restoreWords(id));
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await pumpThrough(tester);
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.byKey(AdminHouseholdListScreen.restoreConfirmKey));
    await pumpThrough(tester);
  }

  group('states', () {
    testWidgets('a spinner shows while the first page is read', (tester) async {
      remote.onFetchPage = (_) => Completer<_Page>().future;
      await tester.pumpWidget(harness());
      await tester.pump();

      expect(find.byKey(AdminHouseholdListScreen.loadingKey), findsOneWidget);
    });

    testWidgets('a failed read offers a retry that reads again', (
      tester,
    ) async {
      remote.onFetchPage = (_) async => throw _transient;
      await pumpScreen(tester);

      expect(find.byKey(AdminHouseholdListScreen.errorKey), findsOneWidget);
      expect(find.text("Couldn't load households"), findsOneWidget);

      remote.listing([ada]);
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();

      expect(find.text("Ada's table"), findsOneWidget);
    });

    testWidgets('a refused read says so and asks access again', (tester) async {
      remote.onFetchPage = (_) async => throw _forbidden;
      await pumpScreen(tester);

      expect(find.byKey(AdminHouseholdListScreen.refusedKey), findsOneWidget);
      expect(
        find.text("You don't have access to households on this server"),
        findsOneWidget,
      );
      expect(access.refreshCount, 1);
    });

    testWidgets('empty with no search, the server has none', (tester) async {
      remote.listing(const []);
      await pumpScreen(tester);

      expect(find.byKey(AdminHouseholdListScreen.emptyKey), findsOneWidget);
      expect(find.text('No households yet'), findsOneWidget);
    });

    testWidgets('empty under All with no search, the server has none too', (
      tester,
    ) async {
      remote.listing(const []);
      await pumpScreen(tester);
      await choose(tester, AdminHouseholdListScreen.statusKey, 'All');

      expect(find.text('No households yet'), findsOneWidget);
    });

    testWidgets('empty under Deleted with no search, there are no deleted '
        'households', (tester) async {
      remote.listing(const []);
      await pumpScreen(tester);
      await choose(tester, AdminHouseholdListScreen.statusKey, 'Deleted');

      expect(find.byKey(AdminHouseholdListScreen.emptyKey), findsOneWidget);
      expect(find.text('No deleted households'), findsOneWidget);
    });

    testWidgets('empty with a search sent, nothing matches it', (tester) async {
      remote.listing(const []);
      await pumpScreen(tester);
      await choose(tester, AdminHouseholdListScreen.statusKey, 'Deleted');
      await tester.enterText(
        find.byKey(AdminHouseholdListScreen.searchKey),
        'zz',
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      expect(
        remote.calls.last,
        describeFetchPage(status: AdminHouseholdStatus.deleted, query: 'zz'),
      );
      expect(find.text('No households match your search'), findsOneWidget);
    });

    testWidgets('a search too short to send leaves the unsearched copy', (
      tester,
    ) async {
      remote.listing(const []);
      await pumpScreen(tester);
      await choose(tester, AdminHouseholdListScreen.statusKey, 'Deleted');
      await tester.enterText(
        find.byKey(AdminHouseholdListScreen.searchKey),
        'z',
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      expect(find.text('No deleted households'), findsOneWidget);
    });
  });

  group('rows', () {
    testWidgets('a row shows its name, members and owners', (tester) async {
      remote.listing([ada, bea, gone]);
      await pumpScreen(tester);

      Finder inRow(String id, String text) => find.descendant(
        of: find.byKey(AdminHouseholdListScreen.rowKey(id)),
        matching: find.text(text),
      );
      expect(inRow('h_ada', "Ada's table"), findsOneWidget);
      expect(inRow('h_ada', '2 members'), findsOneWidget);
      expect(inRow('h_ada', 'Owners: Ada'), findsOneWidget);
      expect(inRow('h_bea', '1 member'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(AdminHouseholdListScreen.rowKey('h_bea')),
          matching: find.textContaining('Owners'),
        ),
        findsNothing,
      );
      expect(inRow('h_gone', 'Owners: Cy, Di'), findsOneWidget);
    });

    testWidgets('an owner with no name to show is stood in for', (
      tester,
    ) async {
      remote.listing([
        adminRow(
          'h_blank',
          owners: [
            _owner('Ada'),
            const AdminHouseholdOwner(userId: 'u_blank', username: ' '),
          ],
        ),
      ]);
      await pumpScreen(tester);

      expect(
        find.descendant(
          of: find.byKey(AdminHouseholdListScreen.rowKey('h_blank')),
          matching: find.text('Owners: Ada, Unnamed owner'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('a deleted row says when, with an icon, and offers Restore; '
        'a live row offers none', (tester) async {
      remote.listing([ada, gone]);
      await pumpScreen(tester);

      final row = find.byKey(AdminHouseholdListScreen.rowKey('h_gone'));
      expect(
        find.descendant(
          of: row,
          matching: find.text('Deleted ${deletedOn(tester, gone)}'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: row, matching: find.byIcon(Icons.delete_outline)),
        findsOneWidget,
      );
      expect(
        find.byKey(AdminHouseholdListScreen.restoreKey('h_gone')),
        findsOneWidget,
      );
      expect(
        find.byKey(AdminHouseholdListScreen.restoreKey('h_ada')),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byKey(AdminHouseholdListScreen.rowKey('h_ada')),
          matching: find.byIcon(Icons.delete_outline),
        ),
        findsNothing,
      );
    });

    testWidgets('the deleted date carries its year, shown and spoken', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      // Midday, so no time zone moves it to another day.
      final old = AdminHouseholdRow(
        id: 'h_old',
        name: 'Old crew',
        reach: Reach.private,
        createdAt: DateTime.utc(2020),
        deletedAt: DateTime.utc(2024, 6, 15, 12),
        memberCount: 4,
        owners: [_owner('Cy')],
      );
      remote.listing([old]);
      await pumpScreen(tester);

      expect(find.text('Deleted Jun 15, 2024'), findsOneWidget);
      expect(
        find.bySemanticsLabel(
          'Old crew, 4 members, owners Cy, deleted Jun 15, 2024',
        ),
        findsOneWidget,
      );
      handle.dispose();
    });

    testWidgets('a live row reads as one node with its facts, and a tap '
        'opens it', (tester) async {
      final handle = tester.ensureSemantics();
      remote.listing([ada, bea]);
      await pumpScreen(tester);

      expect(
        tester.getSemantics(
          find.bySemanticsLabel("Ada's table, 2 members, owners Ada"),
        ),
        isSemantics(
          label: "Ada's table, 2 members, owners Ada",
          hasTapAction: true,
          isFocusable: true,
        ),
      );
      // No owner, so none is named.
      expect(find.bySemanticsLabel('Bea games, 1 member'), findsOneWidget);

      await tester.tap(find.text("Ada's table"));
      await tester.pumpAndSettle();

      expect(opened, ['h_ada']);
      handle.dispose();
    });

    testWidgets("a deleted row's label says it is deleted and when, and it "
        'opens nothing', (tester) async {
      final handle = tester.ensureSemantics();
      remote.listing([gone]);
      await pumpScreen(tester);

      final label =
          'Old crew, 4 members, owners Cy, Di, deleted '
          '${deletedOn(tester, gone)}';
      expect(
        tester.getSemantics(find.bySemanticsLabel(label)),
        isSemantics(label: label, hasTapAction: false),
      );

      await tester.tap(find.text('Old crew'));
      await tester.pumpAndSettle();

      expect(opened, isEmpty);
      handle.dispose();
    });

    testWidgets("Restore's label names the household", (tester) async {
      final handle = tester.ensureSemantics();
      remote.listing([gone]);
      await pumpScreen(tester);

      expect(
        tester.getSemantics(
          find.byKey(AdminHouseholdListScreen.restoreKey('h_gone')),
        ),
        isSemantics(
          label: 'Restore Old crew',
          isButton: true,
          isEnabled: true,
          hasTapAction: true,
        ),
      );
      handle.dispose();
    });

    testWidgets('the list counts the rows loaded, and the count grows with '
        'load more', (tester) async {
      final handle = tester.ensureSemantics();
      remote.onFetchPage = (request) async => request.page == 1
          ? adminPageOf(_rows(1, 25), hasMore: true)
          : adminPageOf(_rows(26, 27), page: request.page);
      await pumpScreen(tester);

      expect(scrollChildCountOnScrollingNode(tester), 25);

      await tester.scrollUntilVisible(
        find.byKey(AdminHouseholdListScreen.moreKey),
        500,
        scrollable: pageScrollable(),
      );
      await tester.ensureVisible(find.byKey(AdminHouseholdListScreen.moreKey));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(AdminHouseholdListScreen.moreKey));
      await tester.pumpAndSettle();

      expect(remote.calls.last, describeFetchPage(page: 2));
      expect(scrollChildCountOnScrollingNode(tester), 27);
      handle.dispose();
    });

    testWidgets('at 320dp and 2.0 text, row facts wrap without overflow', (
      tester,
    ) async {
      useViewSize(tester, const Size(320, 800));
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final crowded = adminRow(
        'h_crowded',
        name: 'The Thursday night strategy games society',
        deleted: true,
        memberCount: 1234,
        owners: [
          for (final n in ['Alexandra', 'Bartholomew', 'Cordelia']) _owner(n),
        ],
      );
      remote.listing([crowded]);
      await pumpScreen(tester);

      expect(tester.takeException(), isNull);

      /// How many lines [text] is drawn on.
      int linesOf(String text) => tester
          .renderObject<RenderParagraph>(find.text(text))
          .getBoxesForSelection(
            TextSelection(baseOffset: 0, extentOffset: text.length),
          )
          .map((box) => box.top)
          .toSet()
          .length;

      // Wrapped, not cut: each is drawn whole, on more than one line.
      for (final text in [
        'The Thursday night strategy games society',
        'Owners: Alexandra, Bartholomew, Cordelia',
        'Deleted ${deletedOn(tester, crowded)}',
      ]) {
        expect(
          tester.renderObject<RenderParagraph>(find.text(text)),
          isA<RenderParagraph>().having(
            (p) => p.didExceedMaxLines,
            'didExceedMaxLines',
            isFalse,
          ),
          reason: text,
        );
        expect(linesOf(text), greaterThan(1), reason: text);
      }
    });
  });

  group('load more', () {
    testWidgets('a failed page says so, and the button tries again', (
      tester,
    ) async {
      var fail = true;
      remote.onFetchPage = (request) async {
        if (request.page == 1) return adminPageOf([ada], hasMore: true);
        if (fail) throw _transient;
        return adminPageOf([bea], page: 2);
      };
      await pumpScreen(tester);

      await tester.tap(find.byKey(AdminHouseholdListScreen.moreKey));
      await tester.pumpAndSettle();

      expect(find.text("Couldn't load more households."), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(AdminHouseholdListScreen.moreKey),
          matching: find.text('Try again'),
        ),
        findsOneWidget,
      );

      fail = false;
      await tester.tap(find.byKey(AdminHouseholdListScreen.moreKey));
      await tester.pumpAndSettle();

      expect(find.text('Bea games'), findsOneWidget);
      expect(find.text("Couldn't load more households."), findsNothing);
    });

    testWidgets('load more is inert while its page is read, and keeps focus', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final page = Completer<_Page>();
      remote.onFetchPage = (request) => request.page == 1
          ? Future.value(adminPageOf([ada], hasMore: true))
          : page.future;
      await pumpScreen(tester);

      final more = find.byKey(AdminHouseholdListScreen.moreKey);
      await focusOn(
        tester,
        find.descendant(of: more, matching: find.text('Load more')),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();

      expect(
        find.descendant(
          of: more,
          matching: find.text('Loading more households\u{2026}'),
        ),
        findsOneWidget,
      );
      expect(focusIsIn(tester, more), isTrue);
      expect(
        tester.getSemantics(more),
        isSemantics(
          label: 'Loading more households\u{2026}',
          isEnabled: false,
          hasTapAction: false,
          isFocused: true,
        ),
      );

      // A second press asks for nothing more.
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(remote.calls.where((c) => c.contains('page: 2')), hasLength(1));

      page.complete(adminPageOf([bea], page: 2, hasMore: true));
      await tester.pumpAndSettle();
      expect(focusIsIn(tester, more), isTrue);
      handle.dispose();
    });

    testWidgets('when the last page lands, focus on Load more goes to the '
        'first row it loaded', (tester) async {
      remote.onFetchPage = (request) async => request.page == 1
          ? adminPageOf([ada], hasMore: true)
          : adminPageOf([bea, gone], page: 2);
      await pumpScreen(tester);

      await focusOn(tester, find.text('Load more'));
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();

      expect(find.byKey(AdminHouseholdListScreen.moreKey), findsNothing);
      expect(
        focusIsIn(tester, find.byKey(AdminHouseholdListScreen.rowKey('h_bea'))),
        isTrue,
      );
    });
  });

  group('search', () {
    Finder field() => find.byKey(AdminHouseholdListScreen.searchKey);
    const tooShort = 'Enter at least 2 characters';
    const tooLong = 'Enter at most 100 characters';

    /// 60 characters to the field, and 120 to the server: each letter's
    /// accent is a mark of its own.
    final accented = 'e\u{0301}' * 60;

    /// One character to the field, and 5 to the server.
    const family = '\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}';

    testWidgets('neither corrects nor suggests: usernames are not prose', (
      tester,
    ) async {
      remote.listing([ada]);
      await pumpScreen(tester);

      final search = tester.widget<TextField>(field());
      expect(search.autocorrect, isFalse);
      expect(search.enableSuggestions, isFalse);
    });

    testWidgets('is labelled and hinted', (tester) async {
      remote.listing([ada]);
      await pumpScreen(tester);

      expect(find.text('Search households'), findsOneWidget);
      expect(find.text('Name or member'), findsOneWidget);
      expect(find.text(tooShort), findsNothing);
    });

    testWidgets('one character says what a search needs, and sends no q', (
      tester,
    ) async {
      remote.listing([ada]);
      await pumpScreen(tester);

      await tester.enterText(field(), ' a ');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      expect(find.text(tooShort), findsOneWidget);
      expect(remote.calls, [describeFetchPage()]);
    });

    testWidgets('the hint is a live region while it shows, kept as typing '
        'goes on, and gone with it', (tester) async {
      remote.listing([ada]);
      await pumpScreen(tester);
      expect(find.bySemanticsLabel(tooShort), findsNothing);

      await tester.enterText(field(), 'a');
      await tester.pump();
      final hint = tester.getSemantics(find.text(tooShort));
      expect(hint, isSemantics(label: tooShort, isLiveRegion: true));

      // Still too short: the same node, so it isn't said again.
      await tester.enterText(field(), 'b');
      await tester.pump();
      expect(tester.getSemantics(find.text(tooShort)).id, hint.id);

      await tester.enterText(field(), 'bc');
      await tester.pump();
      expect(find.text(tooShort), findsNothing);
      expect(find.bySemanticsLabel(tooShort), findsNothing);
      await settleSearch(tester);
    });

    for (final (typed, words) in [('a', tooShort), (accented, tooLong)]) {
      testWidgets('at 320dp and 2.0 text, "$words" wraps whole', (
        tester,
      ) async {
        useViewSize(tester, const Size(320, 800));
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        remote.listing([ada]);
        await pumpScreen(tester);

        await tester.enterText(field(), typed);
        await tester.pump();

        expect(tester.takeException(), isNull);
        final hint = tester.renderObject<RenderParagraph>(find.text(words));
        expect(hint.didExceedMaxLines, isFalse);
        // On more than one line: the test font draws each letter an em wide.
        expect(
          hint.size.height,
          greaterThan(hint.getMinIntrinsicHeight(double.infinity)),
        );
        await settleSearch(tester);
      });
    }

    // The field counts what a reader sees as one character; the server
    // counts more of some. Each fits the field and is too long to send.
    for (final (name, text) in [
      ('accents typed as marks of their own', accented),
      ('family emoji', family * 21),
    ]) {
      testWidgets('$name past the server\'s 100 say so, as a live region, '
          'and send no q', (tester) async {
        remote.listing([ada]);
        await pumpScreen(tester);
        expect(find.bySemanticsLabel(tooLong), findsNothing);

        await tester.enterText(field(), text);
        await tester.pump();

        expect(tester.widget<TextField>(field()).controller!.text, text);
        expect(
          AdminHouseholdRemoteDataSource.queryLength(text),
          greaterThan(AdminHouseholdRemoteDataSource.maxQueryLength),
        );
        expect(
          tester.getSemantics(find.text(tooLong)),
          isSemantics(label: tooLong, isLiveRegion: true),
        );
        await settleSearch(tester);
        expect(remote.calls, [describeFetchPage()]);
      });
    }

    testWidgets('one emoji is one character, as the server counts it', (
      tester,
    ) async {
      remote.listing([ada]);
      await pumpScreen(tester);

      await tester.enterText(field(), '\u{1F3B2}');
      await tester.pump();

      expect(find.text(tooShort), findsOneWidget);
      await settleSearch(tester);
    });

    testWidgets('spaces alone say nothing', (tester) async {
      remote.listing([ada]);
      await pumpScreen(tester);

      await tester.enterText(field(), '   ');
      await tester.pump();

      expect(find.text(tooShort), findsNothing);
      await settleSearch(tester);
    });

    testWidgets('two characters search once typing pauses', (tester) async {
      remote.listing([ada]);
      await pumpScreen(tester);

      await tester.enterText(field(), 'ad');
      await tester.pump();
      expect(find.text(tooShort), findsNothing);
      expect(remote.calls, hasLength(1));

      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      expect(remote.calls.last, describeFetchPage(query: 'ad'));
    });

    testWidgets('Clear search empties the field and reads unsearched', (
      tester,
    ) async {
      remote.listing([ada]);
      await pumpScreen(tester);
      await tester.enterText(field(), 'ad');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Clear search'));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      expect(tester.widget<TextField>(field()).controller!.text, isEmpty);
      expect(remote.calls.last, describeFetchPage());
      expect(find.byTooltip('Clear search'), findsNothing);
    });

    testWidgets('takes 100 characters at most, with no counter', (
      tester,
    ) async {
      remote.listing([ada]);
      await pumpScreen(tester);

      await tester.enterText(field(), 'a' * 120);
      await tester.pump();

      expect(tester.widget<TextField>(field()).controller!.text, 'a' * 100);
      expect(find.textContaining('100'), findsNothing);
      await settleSearch(tester);
    });
  });

  group('status and sort', () {
    testWidgets('at 320dp and 2.0 text, the longest choices wrap inside '
        'their buttons', (tester) async {
      useViewSize(tester, const Size(320, 800));
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      remote.listing([gone]);
      await pumpScreen(tester);
      await choose(tester, AdminHouseholdListScreen.statusKey, 'Deleted');
      await choose(
        tester,
        AdminHouseholdListScreen.sortKey,
        'Recently deleted',
      );

      expect(tester.takeException(), isNull);
      for (final (key, label) in [
        (AdminHouseholdListScreen.statusKey, 'Show: Deleted'),
        (AdminHouseholdListScreen.sortKey, 'Sort: Recently deleted'),
      ]) {
        final button = tester.getRect(find.byKey(key));
        final words = find.descendant(
          of: find.byKey(key),
          matching: find.text(label),
        );
        final paragraph = tester.renderObject<RenderParagraph>(words);
        // Whole: not cut, and inside its button, which is inside the window.
        expect(paragraph.didExceedMaxLines, isFalse, reason: label);
        expect(
          button.contains(tester.getTopLeft(words)) &&
              button.contains(
                tester.getBottomRight(words) - const Offset(1, 1),
              ),
          isTrue,
          reason: label,
        );
        expect(button.left, greaterThanOrEqualTo(0), reason: label);
        expect(button.right, lessThanOrEqualTo(320), reason: label);
      }
      // The longer one does wrap here: the test font draws each letter an em
      // wide, wider than any real face.
      final sort = tester.renderObject<RenderParagraph>(
        find.text('Sort: Recently deleted'),
      );
      expect(
        sort.size.height,
        greaterThan(sort.getMinIntrinsicHeight(double.infinity)),
      );
    });

    testWidgets('the status menu reads the status chosen, and names it', (
      tester,
    ) async {
      remote.listing([gone]);
      await pumpScreen(tester);
      expect(
        find.descendant(
          of: find.byKey(AdminHouseholdListScreen.statusKey),
          matching: find.text('Show: Live'),
        ),
        findsOneWidget,
      );

      await choose(tester, AdminHouseholdListScreen.statusKey, 'Deleted');

      expect(
        remote.calls.last,
        describeFetchPage(status: AdminHouseholdStatus.deleted),
      );
      expect(find.text('Show: Deleted'), findsOneWidget);
    });

    testWidgets('the sort menu offers Recently deleted only under Deleted '
        'and All', (tester) async {
      remote.listing([ada]);
      await pumpScreen(tester);

      await tester.tap(find.byKey(AdminHouseholdListScreen.sortKey));
      await tester.pumpAndSettle();
      expect(menuEntries(tester), ['Name', 'Newest', 'Most members']);
      await tester.tapAt(Offset.zero);
      await tester.pumpAndSettle();

      for (final status in ['Deleted', 'All']) {
        await choose(tester, AdminHouseholdListScreen.statusKey, status);
        await tester.tap(find.byKey(AdminHouseholdListScreen.sortKey));
        await tester.pumpAndSettle();
        expect(menuEntries(tester), [
          'Name',
          'Newest',
          'Most members',
          'Recently deleted',
        ], reason: status);
        await tester.tapAt(Offset.zero);
        await tester.pumpAndSettle();
      }
    });

    testWidgets('a sort chosen reads in that order, and is named', (
      tester,
    ) async {
      remote.listing([ada]);
      await pumpScreen(tester);

      await choose(tester, AdminHouseholdListScreen.sortKey, 'Most members');

      expect(
        remote.calls.last,
        describeFetchPage(sort: AdminHouseholdSort.members),
      );
      expect(find.text('Sort: Most members'), findsOneWidget);
    });

    testWidgets('back to Live from Recently deleted, the sort is Name', (
      tester,
    ) async {
      remote.listing([ada]);
      await pumpScreen(tester);
      await choose(tester, AdminHouseholdListScreen.statusKey, 'All');
      await choose(
        tester,
        AdminHouseholdListScreen.sortKey,
        'Recently deleted',
      );
      expect(find.text('Sort: Recently deleted'), findsOneWidget);

      await choose(tester, AdminHouseholdListScreen.statusKey, 'Live');

      expect(find.text('Sort: Name'), findsOneWidget);
      expect(remote.calls.last, describeFetchPage());
    });
  });

  group('restore', () {
    Future<void> openConfirm(WidgetTester tester, String id) async {
      await tester.tap(find.byKey(AdminHouseholdListScreen.restoreKey(id)));
      await tester.pumpAndSettle();
    }

    testWidgets('the confirmation names the household and its owners, and '
        'Cancel sends nothing', (tester) async {
      remote.listing([gone]);
      await pumpScreen(tester);

      await openConfirm(tester, 'h_gone');

      expect(find.text('Restore Old crew?'), findsOneWidget);
      expect(
        find.text('It comes back with its members. Owners: Cy, Di.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.byType(AlertDialog), findsNothing);
      expect(remote.calls.where((c) => c.startsWith('restore')), isEmpty);
    });

    testWidgets('a household with no owner is confirmed without them', (
      tester,
    ) async {
      remote.listing([lost]);
      await pumpScreen(tester);

      await openConfirm(tester, 'h_lost');

      expect(find.text('Restore Lost club?'), findsOneWidget);
      expect(find.text('It comes back with its members.'), findsOneWidget);
    });

    testWidgets('a confirmed restore says so, and Dismiss takes the banner '
        'down', (tester) async {
      remote
        ..listing([gone, lost])
        ..onRestore = (_) async {};
      await pumpScreen(tester);
      await choose(tester, AdminHouseholdListScreen.statusKey, 'Deleted');
      remote.listing([lost]);

      await openConfirm(tester, 'h_gone');
      await tester.tap(find.byKey(AdminHouseholdListScreen.restoreConfirmKey));
      await tester.pumpAndSettle();

      expect(remote.calls, contains('restore(h_gone)'));
      expect(find.text('Old crew'), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(AdminHouseholdListScreen.outcomeKey),
          matching: find.text('Old crew is restored.'),
        ),
        findsOneWidget,
      );

      await tester.tap(dismiss());
      await tester.pumpAndSettle();

      expect(find.byKey(AdminHouseholdListScreen.outcomeKey), findsNothing);
    });

    for (final (error, message) in [
      (
        _notFound,
        "Old crew couldn't be restored. Your role may not allow restoring "
            'households.',
      ),
      (
        _transient,
        "Old crew couldn't be restored. Check your connection and try again.",
      ),
    ]) {
      testWidgets('a restore answered ${error.statusCode ?? 'with nothing'} '
          'says so', (tester) async {
        remote
          ..listing([gone])
          ..onRestore = (_) async => throw error;
        await pumpScreen(tester);

        await openConfirm(tester, 'h_gone');
        await tester.tap(
          find.byKey(AdminHouseholdListScreen.restoreConfirmKey),
        );
        await tester.pumpAndSettle();

        expect(
          find.descendant(
            of: find.byKey(AdminHouseholdListScreen.outcomeKey),
            matching: find.text(message),
          ),
          findsOneWidget,
        );
      });
    }

    testWidgets('Restore is inert while it runs, keeps focus, and a second '
        'press sends nothing', (tester) async {
      final handle = tester.ensureSemantics();
      final restore = Completer<void>();
      remote
        ..listing([gone])
        ..onRestore = (_) => restore.future;
      await pumpScreen(tester);

      await restoreFromKeyboard(tester, 'h_gone');

      final button = find.byKey(AdminHouseholdListScreen.restoreKey('h_gone'));
      expect(find.byType(AlertDialog), findsNothing);
      expect(focusIsIn(tester, button), isTrue);
      expect(
        tester.getSemantics(button),
        isSemantics(
          label: 'Restore Old crew',
          isButton: true,
          isEnabled: false,
          hasTapAction: false,
          isFocused: true,
        ),
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await pumpThrough(tester);

      expect(find.byType(AlertDialog), findsNothing);
      expect(remote.calls.where((c) => c.startsWith('restore')), hasLength(1));
      expect(focusIsIn(tester, button), isTrue);

      restore.complete();
      await tester.pumpAndSettle();
      handle.dispose();
    });

    testWidgets('offline, Restore is disabled and says why', (tester) async {
      final handle = tester.ensureSemantics();
      final offline = ValueNotifier(true);
      addTearDown(offline.dispose);
      remote.listing([gone]);
      await pumpScreen(tester, offline: offline);

      final button = find.byKey(AdminHouseholdListScreen.restoreKey('h_gone'));
      expect(tester.widget<TextButton>(button).onPressed, isNull);
      expect(
        tester.getSemantics(button),
        isSemantics(
          label: 'Restore Old crew',
          hint: _onlineOnlyCopy,
          isEnabled: false,
          hasTapAction: false,
        ),
      );
      expect(find.text(_onlineOnlyCopy), findsOneWidget);

      await tester.tap(button, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);

      offline.value = false;
      await tester.pumpAndSettle();
      expect(tester.widget<TextButton>(button).onPressed, isNotNull);
      expect(find.text(_onlineOnlyCopy), findsNothing);
      handle.dispose();
    });
  });

  group('keeping keyboard focus when a row goes', () {
    /// The live row named [name], whose tile takes focus.
    Finder tile(String name) =>
        find.ancestor(of: find.text(name), matching: find.byType(ListTile));

    testWidgets('a live row that leaves with focus, as on the read when the '
        'list comes back into view, hands it to the next row', (tester) async {
      final cy = adminRow('h_cy', name: 'Cy club');
      remote.listing([ada, bea, cy]);
      await pumpScreen(tester);
      await focusOn(tester, find.text('Bea games'));
      expect(focusIsIn(tester, tile('Bea games')), isTrue);

      remote.listing([ada, cy]);
      blocOf(tester).add(const AdminHouseholdListLoadRequested());
      await tester.pumpAndSettle();

      expect(find.text('Bea games'), findsNothing);
      expect(focusIsIn(tester, tile('Cy club')), isTrue);
    });

    testWidgets('the last row leaving with focus hands it to the row before '
        'it', (tester) async {
      remote.listing([ada, bea]);
      await pumpScreen(tester);
      await focusOn(tester, find.text('Bea games'));

      remote.listing([ada]);
      blocOf(tester).add(const AdminHouseholdListLoadRequested());
      await tester.pumpAndSettle();

      expect(focusIsIn(tester, tile("Ada's table")), isTrue);
    });

    testWidgets('under All, a live row with focus that turns deleted hands it '
        'to its own Restore', (tester) async {
      final beaGone = adminRow('h_bea', name: 'Bea games', deleted: true);
      remote.listing([ada, bea]);
      await pumpScreen(tester);
      await choose(tester, AdminHouseholdListScreen.statusKey, 'All');
      await focusOn(tester, find.text('Bea games'));

      remote.listing([ada, beaGone]);
      blocOf(tester).add(const AdminHouseholdListLoadRequested());
      await tester.pumpAndSettle();

      expect(
        focusIsIn(
          tester,
          find.byKey(AdminHouseholdListScreen.restoreKey('h_bea')),
        ),
        isTrue,
      );
    });

    testWidgets('the only row leaving with focus hands it to the heading', (
      tester,
    ) async {
      remote.listing([ada]);
      await pumpScreen(tester);
      await focusOn(tester, find.text("Ada's table"));

      remote.listing([]);
      blocOf(tester).add(const AdminHouseholdListLoadRequested());
      await tester.pumpAndSettle();

      expectFocusOn(tester, heading());
    });
  });

  group('keeping keyboard focus when Restore goes', () {
    testWidgets("under Deleted, focus on Restore goes to the banner's "
        'Dismiss when its row leaves', (tester) async {
      final restore = Completer<void>();
      remote
        ..listing([gone, lost])
        ..onRestore = (_) => restore.future;
      await pumpScreen(tester);
      await choose(tester, AdminHouseholdListScreen.statusKey, 'Deleted');
      await restoreFromKeyboard(tester, 'h_gone');
      expect(
        focusIsIn(
          tester,
          find.byKey(AdminHouseholdListScreen.restoreKey('h_gone')),
        ),
        isTrue,
      );

      remote.listing([lost]);
      restore.complete();
      await tester.pumpAndSettle();

      expect(find.text('Old crew'), findsNothing);
      expectFocusOn(tester, dismiss());
    });

    testWidgets('Dismiss pressed from the keyboard goes with the banner, and '
        'hands its focus to the heading', (tester) async {
      remote
        ..listing([gone, lost])
        ..onRestore = (_) async {};
      await pumpScreen(tester);
      await choose(tester, AdminHouseholdListScreen.statusKey, 'Deleted');
      remote.listing([lost]);
      await restoreFromKeyboard(tester, 'h_gone');
      await tester.pumpAndSettle();
      expectFocusOn(tester, dismiss());

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();

      expect(find.byKey(AdminHouseholdListScreen.outcomeKey), findsNothing);
      expectFocusOn(tester, heading());
    });

    testWidgets('under All, focus on Restore goes to Dismiss when its row '
        'turns live', (tester) async {
      final restore = Completer<void>();
      remote
        ..listing([gone, ada])
        ..onRestore = (_) => restore.future;
      await pumpScreen(tester);
      await choose(tester, AdminHouseholdListScreen.statusKey, 'All');
      await restoreFromKeyboard(tester, 'h_gone');

      restore.complete();
      await tester.pumpAndSettle();

      expect(find.text('Old crew'), findsOneWidget);
      expect(
        find.byKey(AdminHouseholdListScreen.restoreKey('h_gone')),
        findsNothing,
      );
      expectFocusOn(tester, dismiss());
    });

    testWidgets('a restore that answers at once, as its confirmation closes, '
        'still hands focus to Dismiss', (tester) async {
      remote
        ..listing([gone, lost])
        ..onRestore = (_) async {};
      await pumpScreen(tester);
      await choose(tester, AdminHouseholdListScreen.statusKey, 'Deleted');
      remote.listing([lost]);

      await restoreFromKeyboard(tester, 'h_gone');
      await tester.pumpAndSettle();

      expect(find.text('Old crew'), findsNothing);
      expectFocusOn(tester, dismiss());
    });

    testWidgets('a Restore that goes while its confirmation is open hands '
        'focus on when the dialog closes', (tester) async {
      remote.listing([gone, lost]);
      await pumpScreen(tester);
      await choose(tester, AdminHouseholdListScreen.statusKey, 'Deleted');
      await focusOn(tester, restoreWords('h_gone'));
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await pumpThrough(tester);
      expect(find.byType(AlertDialog), findsOneWidget);

      // A read lands without the row while the dialog is open, so focus
      // has no Restore to come back to.
      remote.listing([lost]);
      blocOf(tester).add(const AdminHouseholdListLoadRequested());
      await pumpThrough(tester);
      expect(
        find.byKey(AdminHouseholdListScreen.restoreKey('h_gone')),
        findsNothing,
      );

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(remote.calls.where((c) => c.startsWith('restore')), isEmpty);
      expectFocusOn(tester, heading());
    });

    testWidgets('a restore the server refuses takes the list away, and focus '
        'goes to the heading', (tester) async {
      final restore = Completer<void>();
      remote
        ..listing([gone])
        ..onRestore = (_) => restore.future;
      await pumpScreen(tester);
      await restoreFromKeyboard(tester, 'h_gone');

      restore.completeError(_forbidden);
      await tester.pumpAndSettle();

      expect(find.byKey(AdminHouseholdListScreen.refusedKey), findsOneWidget);
      expectFocusOn(tester, heading());
    });

    testWidgets('a restore that fails leaves focus on Restore', (tester) async {
      final restore = Completer<void>();
      remote
        ..listing([gone])
        ..onRestore = (_) => restore.future;
      await pumpScreen(tester);
      await restoreFromKeyboard(tester, 'h_gone');

      restore.completeError(_transient);
      await tester.pumpAndSettle();

      expect(find.byKey(AdminHouseholdListScreen.outcomeKey), findsOneWidget);
      expect(
        focusIsIn(
          tester,
          find.byKey(AdminHouseholdListScreen.restoreKey('h_gone')),
        ),
        isTrue,
      );
    });

    testWidgets('focus elsewhere stays where it is when a row leaves', (
      tester,
    ) async {
      remote
        ..listing([gone, lost])
        ..onRestore = (_) async {};
      await pumpScreen(tester);
      await choose(tester, AdminHouseholdListScreen.statusKey, 'Deleted');
      await tester.showKeyboard(find.byKey(AdminHouseholdListScreen.searchKey));
      remote.listing([lost]);

      blocOf(tester).add(const AdminHouseholdListRestoreRequested('h_gone'));
      await tester.pumpAndSettle();

      expect(find.text('Old crew'), findsNothing);
      expect(
        focusIsIn(tester, find.byKey(AdminHouseholdListScreen.searchKey)),
        isTrue,
      );
    });

    testWidgets('the heading is not a Tab stop', (tester) async {
      remote.listing([ada]);
      await pumpScreen(tester);

      final node = Focus.of(tester.element(heading()), createDependency: false);
      expect(node.skipTraversal, isTrue);
    });
  });

  testWidgets('Try again goes as it reads again, and hands its focus to the '
      'heading', (tester) async {
    remote.onFetchPage = (_) async => throw _transient;
    await pumpScreen(tester);
    final page = Completer<_Page>();
    remote.onFetchPage = (_) => page.future;

    await focusOn(tester, find.text('Try again'));
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();

    expect(find.byKey(AdminHouseholdListScreen.loadingKey), findsOneWidget);
    expectFocusOn(tester, heading());

    page.complete(adminPageOf([ada]));
    await tester.pumpAndSettle();
    expectFocusOn(tester, heading());
  });

  testWidgets('reads the list again when it comes back into view', (
    tester,
  ) async {
    remote.listing([ada]);
    await pumpScreen(tester);
    expect(remote.calls, hasLength(1));

    unawaited(
      Navigator.of(tester.element(find.text("Ada's table"))).push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('detail')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();

    expect(remote.calls, hasLength(2));
  });

  testWidgets('adminHouseholdsTitle names the section', (tester) async {
    remote.listing([ada]);
    await pumpScreen(tester);

    expect(
      adminHouseholdsTitle(
        HouseholdLocalizations.of(
          tester.element(find.byType(AdminHouseholdListScreen)),
        ),
      ),
      'Households',
    );
  });

  group('accessibility audit', () {
    /// One of each row shape: live with an owner, live without, deleted with
    /// owners, deleted without.
    final rows = [ada, bea, gone, lost];

    /// The screen over the fake as [seed] leaves it; the state is chosen
    /// before the first read goes out.
    Future<void> Function(WidgetTester, ThemeData) screen({
      void Function()? seed,
      bool offline = false,
      bool settle = true,
    }) => (tester, theme) async {
      (seed ?? () => remote.listing(rows))();
      final notifier = offline ? ValueNotifier(true) : null;
      if (notifier != null) addTearDown(notifier.dispose);
      await tester.pumpWidget(harness(theme: theme, offline: notifier));
      if (settle) await tester.pumpAndSettle();
    };

    final ready = screen();

    void expectOutcome(String message) => expect(
      find.descendant(
        of: find.byKey(AdminHouseholdListScreen.outcomeKey),
        matching: find.text(message),
      ),
      findsOneWidget,
    );

    Future<void> restoreGone(WidgetTester tester) async {
      await tester.ensureVisible(
        find.byKey(AdminHouseholdListScreen.restoreKey('h_gone')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(AdminHouseholdListScreen.restoreKey('h_gone')),
      );
      await pumpThrough(tester);
      await tester.tap(find.byKey(AdminHouseholdListScreen.restoreConfirmKey));
      await pumpThrough(tester);
    }

    auditScreen(
      'loading',
      pump: screen(
        seed: () => remote.onFetchPage = (_) => Completer<_Page>().future,
        settle: false,
      ),
      settle: false,
      arrange: (tester) async {
        await tester.pump();
        expect(find.byKey(AdminHouseholdListScreen.loadingKey), findsOneWidget);
      },
    );

    auditScreen(
      'refused',
      pump: screen(
        seed: () => remote.onFetchPage = (_) async => throw _forbidden,
      ),
      arrange: (tester) async {
        expect(find.byKey(AdminHouseholdListScreen.refusedKey), findsOneWidget);
      },
    );

    auditScreen(
      'failed, with retry',
      pump: screen(
        seed: () => remote.onFetchPage = (_) async => throw _transient,
      ),
      arrange: (tester) async {
        expect(find.byKey(AdminHouseholdListScreen.errorKey), findsOneWidget);
      },
    );

    auditScreen(
      'empty',
      pump: screen(seed: () => remote.listing(const [])),
      arrange: (tester) async {
        expect(find.byKey(AdminHouseholdListScreen.emptyKey), findsOneWidget);
      },
    );

    auditScreen(
      'ready',
      pump: ready,
      arrange: (tester) async {
        expect(find.text("Ada's table"), findsOneWidget);
      },
    );

    auditScreen(
      'ready, whole page',
      pump: ready,
      arrange: (tester) async {
        await useWholePage(tester);
        for (final row in rows) {
          expect(
            find.byKey(AdminHouseholdListScreen.rowKey(row.id)),
            findsOneWidget,
            reason: row.id,
          );
        }
        expectWholePage(tester);
      },
    );

    auditScreen(
      'ready, scrolled to the end',
      pump: ready,
      arrange: (tester) async {
        await scrollListToEnd(
          tester,
          find.byKey(AdminHouseholdListScreen.rowKey('h_lost')),
          mustScroll: false,
        );
      },
    );

    auditScreen(
      'ready, with more to load',
      pump: screen(
        seed: () =>
            remote.onFetchPage = (request) async =>
                adminPageOf(rows, page: request.page, hasMore: true),
      ),
      arrange: (tester) async {
        await scrollListToEnd(
          tester,
          find.byKey(AdminHouseholdListScreen.moreKey),
          mustScroll: false,
        );
      },
    );

    auditScreen(
      'load more failed',
      pump: screen(
        seed: () => remote.onFetchPage = (request) async {
          if (request.page > 1) throw _transient;
          return adminPageOf(rows, hasMore: true);
        },
      ),
      arrange: (tester) async {
        final more = find.byKey(AdminHouseholdListScreen.moreKey);
        // Below the rows, which a lazy list builds only near the view.
        await scrollListToEnd(tester, more, mustScroll: false);
        await tester.tap(more);
        await tester.pumpAndSettle();
        expect(find.text("Couldn't load more households."), findsOneWidget);
        await scrollListToEnd(tester, more, mustScroll: false);
      },
    );

    auditScreen(
      'search too short',
      pump: ready,
      arrange: (tester) async {
        await tester.enterText(
          find.byKey(AdminHouseholdListScreen.searchKey),
          'a',
        );
        await tester.pump();
        expect(find.text('Enter at least 2 characters'), findsOneWidget);
        // The bloc's pause, which reads nothing for a term this short.
        await tester.pump(const Duration(milliseconds: 300));
      },
    );

    auditScreen(
      'search too long',
      pump: ready,
      arrange: (tester) async {
        // 60 characters to the field, 120 to the server.
        await tester.enterText(
          find.byKey(AdminHouseholdListScreen.searchKey),
          'e\u{0301}' * 60,
        );
        await tester.pump();
        expect(find.text('Enter at most 100 characters'), findsOneWidget);
        // The bloc's pause, which reads nothing for a term this long.
        await tester.pump(const Duration(milliseconds: 300));
      },
    );

    auditScreen(
      'status menu open',
      pump: ready,
      arrange: (tester) async {
        await tester.tap(find.byKey(AdminHouseholdListScreen.statusKey));
        await tester.pumpAndSettle();
        expect(find.byType(MenuItemButton), findsNWidgets(3));
      },
    );

    auditScreen(
      'sort menu open',
      pump: ready,
      arrange: (tester) async {
        await choose(tester, AdminHouseholdListScreen.statusKey, 'All');
        await tester.tap(find.byKey(AdminHouseholdListScreen.sortKey));
        await tester.pumpAndSettle();
        expect(find.byType(MenuItemButton), findsNWidgets(4));
      },
    );

    auditScreen(
      'restore confirm',
      pump: ready,
      arrange: (tester) async {
        final restore = find.byKey(
          AdminHouseholdListScreen.restoreKey('h_gone'),
        );
        await tester.ensureVisible(restore);
        await tester.pumpAndSettle();
        await tester.tap(restore);
        await tester.pumpAndSettle();
        expect(find.text('Restore Old crew?'), findsOneWidget);
      },
    );

    // The restore never answers, so its spinner keeps going.
    auditScreen(
      'restore in flight',
      pump: screen(
        seed: () {
          remote
            ..listing(rows)
            ..onRestore = (_) => Completer<void>().future;
        },
      ),
      settle: false,
      arrange: (tester) async {
        // Whole, before the spinner starts: a page settled scrolled to
        // Restore can leave a control clipped by the top edge, and the
        // spinner never lets it settle after.
        await useWholePage(tester);
        await restoreGone(tester);
        expect(
          find.descendant(
            of: find.byKey(AdminHouseholdListScreen.restoreKey('h_gone')),
            matching: find.byType(CircularProgressIndicator),
          ),
          findsOneWidget,
        );
        expectWholePage(tester);
      },
    );

    // One call per tone the banner takes: success, warning and error.
    auditScreen(
      'restore outcome, restored',
      pump: screen(
        seed: () {
          remote
            ..listing(rows)
            ..onRestore = (_) async {};
        },
      ),
      arrange: (tester) async {
        await restoreGone(tester);
        await tester.pumpAndSettle();
        expectOutcome('Old crew is restored.');
      },
    );

    auditScreen(
      'restore outcome, not restorable',
      pump: screen(
        seed: () {
          remote
            ..listing(rows)
            ..onRestore = (_) async => throw _notFound;
        },
      ),
      arrange: (tester) async {
        await restoreGone(tester);
        await tester.pumpAndSettle();
        expectOutcome(
          "Old crew couldn't be restored. Your role may not allow restoring "
          'households.',
        );
      },
    );

    auditScreen(
      'restore outcome, failed',
      pump: screen(
        seed: () {
          remote
            ..listing(rows)
            ..onRestore = (_) async => throw _transient;
        },
      ),
      arrange: (tester) async {
        await restoreGone(tester);
        await tester.pumpAndSettle();
        expectOutcome(
          "Old crew couldn't be restored. Check your connection and try "
          'again.',
        );
      },
    );

    auditScreen(
      'offline',
      pump: screen(offline: true),
      arrange: (tester) async {
        await useWholePage(tester);
        expect(find.text(_onlineOnlyCopy), findsNWidgets(2));
        expectWholePage(tester);
      },
    );
  });
}
