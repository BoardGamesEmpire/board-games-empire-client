import 'dart:async';

import 'package:bge_test_support/access.dart';
import 'package:data_gateway/data_gateway.dart';
import 'package:data_gateway/l10n/data_gateway_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/fake_data_gateway_remote.dart';

void main() {
  late FakeDataGatewayRemote remote;
  late FakeCallerAccessRepository access;

  final bgg = gateway(
    'dg_1',
    name: 'BGG',
    connectionUrl: 'bgg.internal',
    connectionPort: 50051,
  );
  final steam = gateway('dg_2', name: 'Steam', enabled: false);

  setUp(() {
    remote = FakeDataGatewayRemote();
    access = FakeCallerAccessRepository(
      FakeCallerAccessRepository.dataGateway(
        create: AccessExtent.all,
        read: AccessExtent.all,
        update: AccessExtent.all,
        delete: AccessExtent.all,
      ),
    );
  });

  /// [onOpen] is null unless a test gives one, which leaves the rows
  /// untappable, as a composition with no detail route does.
  Future<void> pumpScreen(
    WidgetTester tester, {
    void Function(BuildContext context)? onAdd,
    void Function(BuildContext context, String id)? onEdit,
    void Function(BuildContext context, String id)? onOpen,
    TextScaler textScaler = TextScaler.noScaling,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: BgeTheme.light(),
        localizationsDelegates: DataGatewayLocalizations.localizationsDelegates,
        supportedLocales: DataGatewayLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: textScaler),
          child: child!,
        ),
        home: DataGatewayListScreen(
          remote: remote,
          access: access,
          onAdd: onAdd ?? (_) {},
          onEdit: onEdit ?? (_, _) {},
          onOpen: onOpen,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// [row] with the interview status it would have if it had been
  /// [interviewed] or not, and its last interview had failed with [failure]
  /// or not.
  DataGateway withInterview(
    DataGateway row, {
    bool interviewed = false,
    DataGatewayInterviewFailureCode? failure,
  }) => row.copyWith(
    interview: DataGatewayInterviewStatus(
      interviewed: interviewed,
      failure: failure == null
          ? null
          : DataGatewayInterviewFailure(
              code: failure,
              at: DateTime.utc(2026, 10, 30),
            ),
    ),
  );

  /// Stands in for the add or edit form: a page over the list.
  void openForm(BuildContext context) => unawaited(
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('the form')),
      ),
    ),
  );

  /// Leaves the form opened by [openForm].
  Future<void> leaveForm(WidgetTester tester) async {
    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
  }

  Future<void> choose(WidgetTester tester, String id, Key item) async {
    await tester.tap(find.byKey(DataGatewayListScreen.rowMenuKey(id)));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(item));
    await tester.pumpAndSettle();
  }

  testWidgets('lists each DataGateway with its address and whether it is '
      'enabled', (tester) async {
    remote.listing([bgg, steam]);

    await pumpScreen(tester);

    expect(find.text('BGG'), findsOneWidget);
    expect(find.text('bgg.internal:50051'), findsOneWidget);
    expect(find.text('Enabled'), findsOneWidget);
    expect(find.text('Steam'), findsOneWidget);
    expect(find.text('Disabled'), findsOneWidget);
  });

  testWidgets('an empty list says what a DataGateway is', (tester) async {
    remote.listing(const []);

    await pumpScreen(tester);

    expect(find.byKey(DataGatewayListScreen.emptyKey), findsOneWidget);
    expect(find.text('No data gateways yet'), findsOneWidget);
  });

  testWidgets('a failed read offers a retry that reads again', (tester) async {
    remote.onFetchPage = (_, _) async => throw unreachable();
    await pumpScreen(tester);

    expect(find.text("We couldn't load the data gateways"), findsOneWidget);

    remote.listing([bgg]);
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();

    expect(find.text('BGG'), findsOneWidget);
  });

  group('a caller who may not read DataGateways (#41)', () {
    testWidgets('a deep link shows access-denied, with nothing to act on', (
      tester,
    ) async {
      remote.refusingReads();

      await pumpScreen(tester);

      expect(find.byKey(DataGatewayListScreen.deniedKey), findsOneWidget);
      expect(
        find.text("You don't have access to data gateways"),
        findsOneWidget,
      );
      expect(find.byKey(DataGatewayListScreen.addKey), findsNothing);
    });
  });

  group('what the caller may do (#456)', () {
    final menuItems = [
      DataGatewayListScreen.editKey,
      DataGatewayListScreen.connectKey,
      DataGatewayListScreen.disconnectKey,
      DataGatewayListScreen.deleteKey,
    ];

    /// Which of the row menu's items [id]'s menu offers.
    Future<List<Key>> offered(WidgetTester tester, String id) async {
      await tester.tap(find.byKey(DataGatewayListScreen.rowMenuKey(id)));
      await tester.pumpAndSettle();
      return [
        for (final item in menuItems)
          if (find.byKey(item).evaluate().isNotEmpty) item,
      ];
    }

    testWidgets('no Add button without create', (tester) async {
      access.current = FakeCallerAccessRepository.dataGateway(
        read: AccessExtent.all,
        update: AccessExtent.all,
        delete: AccessExtent.all,
      );
      remote.listing([bgg]);

      await pumpScreen(tester);

      expect(find.byKey(DataGatewayListScreen.addKey), findsNothing);
      expect(
        find.byKey(DataGatewayListScreen.rowMenuKey('dg_1')),
        findsOneWidget,
      );
    });

    testWidgets('the row menu offers delete only with delete', (tester) async {
      access.current = FakeCallerAccessRepository.dataGateway(
        read: AccessExtent.all,
        delete: AccessExtent.all,
      );
      remote.listing([bgg]);
      await pumpScreen(tester);

      expect(await offered(tester, 'dg_1'), [DataGatewayListScreen.deleteKey]);
    });

    testWidgets('the row menu offers edit, connect and disconnect only with '
        'update', (tester) async {
      access.current = FakeCallerAccessRepository.dataGateway(
        read: AccessExtent.all,
        update: AccessExtent.some,
      );
      remote.listing([bgg]);
      await pumpScreen(tester);

      expect(await offered(tester, 'dg_1'), [
        DataGatewayListScreen.editKey,
        DataGatewayListScreen.connectKey,
        DataGatewayListScreen.disconnectKey,
      ]);
    });

    testWidgets('no row menu while access is unknown', (tester) async {
      access.current = const CallerAccess.unknown();
      remote.listing([bgg, steam]);

      await pumpScreen(tester);

      expect(find.byKey(DataGatewayListScreen.addKey), findsNothing);
      expect(
        find.byKey(DataGatewayListScreen.rowMenuKey('dg_1')),
        findsNothing,
      );
      expect(
        find.byKey(DataGatewayListScreen.rowMenuKey('dg_2')),
        findsNothing,
      );
      // Still a reader's list: the rows show.
      expect(find.text('BGG'), findsOneWidget);
    });

    testWidgets('the Add button appears when access arrives', (tester) async {
      access.current = const CallerAccess.unknown();
      remote.listing([bgg]);
      await pumpScreen(tester);
      expect(find.byKey(DataGatewayListScreen.addKey), findsNothing);

      access.current = FakeCallerAccessRepository.dataGateway(
        create: AccessExtent.all,
      );
      await tester.pumpAndSettle();

      expect(find.byKey(DataGatewayListScreen.addKey), findsOneWidget);
    });

    testWidgets('a refused change says so and asks access again, and the '
        'actions follow the answer', (tester) async {
      remote
        ..listing([bgg, steam])
        ..onConnect = (_) async => throw forbidden();
      await pumpScreen(tester);

      await choose(tester, 'dg_2', DataGatewayListScreen.connectKey);

      expect(
        find.text("Your role can't change data gateways."),
        findsOneWidget,
      );
      expect(access.refreshCount, 1);
      // The refusal alone takes nothing away.
      expect(
        find.byKey(DataGatewayListScreen.rowMenuKey('dg_2')),
        findsOneWidget,
      );

      // What the ask found: a reader.
      access.current = FakeCallerAccessRepository.dataGateway(
        read: AccessExtent.all,
      );
      await tester.pumpAndSettle();

      expect(find.byKey(DataGatewayListScreen.addKey), findsNothing);
      expect(
        find.byKey(DataGatewayListScreen.rowMenuKey('dg_1')),
        findsNothing,
      );
      expect(
        find.byKey(DataGatewayListScreen.rowMenuKey('dg_2')),
        findsNothing,
      );
      // Still a reader: the rows stay.
      expect(find.text('BGG'), findsOneWidget);
    });
  });

  group('keeping keyboard focus when access takes a control away (#456)', () {
    /// Puts keyboard focus on the control [control] finds, as a click or a
    /// Tab would: on its own node, with nothing before it in the page's
    /// history to fall back to.
    void focusOn(WidgetTester tester, Finder control) => Focus.of(
      tester.element(
        find
            .descendant(
              of: control,
              matching: find.byWidgetPredicate(
                (widget) => widget is Icon || widget is Text,
              ),
            )
            .first,
      ),
    ).requestFocus();

    /// Expects keyboard focus on the nearest node above the text [label]:
    /// the heading, a row by its name, or a button by its label. Not on the
    /// page's scope, which is above every text and where focus falls when
    /// the control that had it goes.
    void expectFocusOn(WidgetTester tester, String label) {
      final focused = FocusManager.instance.primaryFocus;
      expect(focused, isNot(isA<FocusScopeNode>()));
      expect(
        focused,
        same(
          Focus.of(tester.element(find.text(label)), createDependency: false),
        ),
      );
    }

    /// May read DataGateways and add one, and nothing else.
    final mayOnlyAdd = FakeCallerAccessRepository.dataGateway(
      create: AccessExtent.all,
      read: AccessExtent.all,
    );

    testWidgets('the Add button with focus hands it to the heading when '
        'create falls', (tester) async {
      remote.listing([bgg, steam]);
      await pumpScreen(tester, onOpen: (_, _) {});
      focusOn(tester, find.byKey(DataGatewayListScreen.addKey));
      await tester.pump();
      expectFocusOn(tester, 'Add data gateway');

      access.current = FakeCallerAccessRepository.dataGateway(
        read: AccessExtent.all,
        update: AccessExtent.all,
        delete: AccessExtent.all,
      );
      await tester.pumpAndSettle();

      expect(find.byKey(DataGatewayListScreen.addKey), findsNothing);
      expectFocusOn(tester, 'Data gateways');
    });

    testWidgets('focus the user moves before the Add button goes stays where '
        'they put it', (tester) async {
      remote.listing([bgg, steam]);
      await pumpScreen(tester, onOpen: (_, _) {});
      focusOn(tester, find.byKey(DataGatewayListScreen.addKey));
      await tester.pump();

      access.current = FakeCallerAccessRepository.dataGateway(
        read: AccessExtent.all,
        update: AccessExtent.all,
        delete: AccessExtent.all,
      );
      // The answer reaches the screen, and the user moves on before the
      // frame that takes the button away.
      await tester.binding.delayed(Duration.zero);
      focusOn(tester, find.byKey(DataGatewayListScreen.rowKey('dg_1')));
      await tester.binding.delayed(Duration.zero);
      await tester.pumpAndSettle();

      expect(find.byKey(DataGatewayListScreen.addKey), findsNothing);
      expectFocusOn(tester, 'BGG');
    });

    testWidgets('the Add button with focus keeps it when create falls and '
        'comes back before the next frame', (tester) async {
      final mayDoAnything = access.current;
      remote.listing([bgg, steam]);
      await pumpScreen(tester, onOpen: (_, _) {});
      focusOn(tester, find.byKey(DataGatewayListScreen.addKey));
      await tester.pump();

      // Each answer reaches the screen, but no frame is drawn between them.
      access.current = FakeCallerAccessRepository.dataGateway(
        read: AccessExtent.all,
        update: AccessExtent.all,
        delete: AccessExtent.all,
      );
      await tester.binding.delayed(Duration.zero);
      access.current = mayDoAnything;
      await tester.binding.delayed(Duration.zero);
      await tester.pumpAndSettle();

      expectFocusOn(tester, 'Add data gateway');
    });

    testWidgets('a row menu with focus hands it to its own row when update '
        'and delete fall', (tester) async {
      remote.listing([bgg, steam]);
      await pumpScreen(tester, onOpen: (_, _) {});
      focusOn(tester, find.byKey(DataGatewayListScreen.rowMenuKey('dg_2')));
      await tester.pump();

      access.current = mayOnlyAdd;
      await tester.pumpAndSettle();

      expect(
        find.byKey(DataGatewayListScreen.rowMenuKey('dg_2')),
        findsNothing,
      );
      expectFocusOn(tester, 'Steam');
    });

    testWidgets('with rows that do not open, a row menu with focus hands it '
        'to the heading', (tester) async {
      remote.listing([bgg, steam]);
      await pumpScreen(tester);
      focusOn(tester, find.byKey(DataGatewayListScreen.rowMenuKey('dg_2')));
      await tester.pump();

      access.current = mayOnlyAdd;
      await tester.pumpAndSettle();

      expectFocusOn(tester, 'Data gateways');
    });

    testWidgets("with an outcome showing, focus goes to the banner's Dismiss", (
      tester,
    ) async {
      remote
        ..listing([bgg, steam])
        ..onDisconnect = (_) async => throw unreachable();
      await pumpScreen(tester, onOpen: (_, _) {});
      await choose(tester, 'dg_1', DataGatewayListScreen.disconnectKey);
      expect(find.byKey(DataGatewayListScreen.outcomeKey), findsOneWidget);
      focusOn(tester, find.byKey(DataGatewayListScreen.rowMenuKey('dg_2')));
      await tester.pump();

      access.current = mayOnlyAdd;
      await tester.pumpAndSettle();

      expectFocusOn(tester, 'Dismiss');
    });

    testWidgets('focus on a control that stays is left where it is', (
      tester,
    ) async {
      remote.listing([bgg, steam]);
      await pumpScreen(tester, onOpen: (_, _) {});
      focusOn(tester, find.byKey(DataGatewayListScreen.rowKey('dg_1')));
      await tester.pump();
      expectFocusOn(tester, 'BGG');

      access.current = FakeCallerAccessRepository.dataGateway(
        read: AccessExtent.all,
      );
      await tester.pumpAndSettle();

      expectFocusOn(tester, 'BGG');
    });

    testWidgets('the heading is not a Tab stop', (tester) async {
      remote.listing([bgg]);
      await pumpScreen(tester, onOpen: (_, _) {});

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();

      expectFocusOn(tester, 'BGG');
    });
  });

  group('row actions', () {
    testWidgets('connect reports what the server answered', (tester) async {
      remote
        ..listing([steam])
        ..onConnect = (_) async => changed(
          steam.copyWith(enabled: true),
          attempted: DataGatewayConnectionAction.connect,
          succeeded: false,
        );
      await pumpScreen(tester);

      await choose(tester, 'dg_2', DataGatewayListScreen.connectKey);

      expect(
        find.text("Steam is enabled, but the server couldn't connect to it."),
        findsOneWidget,
      );
      expect(find.text('Enabled'), findsOneWidget);
    });

    testWidgets('disconnect is offered only on an enabled DataGateway', (
      tester,
    ) async {
      remote.listing([steam]);
      await pumpScreen(tester);

      await tester.tap(find.byKey(DataGatewayListScreen.rowMenuKey('dg_2')));
      await tester.pumpAndSettle();

      expect(find.byKey(DataGatewayListScreen.connectKey), findsOneWidget);
      expect(find.byKey(DataGatewayListScreen.disconnectKey), findsNothing);
    });

    testWidgets('delete asks first, and cancelling sends nothing', (
      tester,
    ) async {
      remote.listing([bgg]);
      await pumpScreen(tester);

      await choose(tester, 'dg_1', DataGatewayListScreen.deleteKey);
      expect(find.text('Delete BGG?'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(remote.calls, isNot(contains('delete(dg_1)')));
      expect(find.text('BGG'), findsOneWidget);
    });

    testWidgets('a confirmed delete removes the row', (tester) async {
      remote
        ..listing([bgg])
        ..onDelete = (_) async => changed(bgg);
      await pumpScreen(tester);

      await choose(tester, 'dg_1', DataGatewayListScreen.deleteKey);
      await tester.tap(find.byKey(DataGatewayListScreen.deleteConfirmKey));
      await tester.pumpAndSettle();

      expect(remote.calls, contains('delete(dg_1)'));
      expect(find.text('Deleted BGG.'), findsOneWidget);
      expect(find.byKey(DataGatewayListScreen.rowKey('dg_1')), findsNothing);
    });

    testWidgets('a delete confirmed after a reload took the list down sends '
        'nothing', (tester) async {
      remote.listing([bgg]);
      await pumpScreen(tester);

      await choose(tester, 'dg_1', DataGatewayListScreen.deleteKey);
      // While the dialog is open, a reload (such as the one a return from
      // the form starts) fails and replaces the list.
      remote.onFetchPage = (_, _) async => throw unreachable();
      tester
          .element(find.byKey(DataGatewayListScreen.rowKey('dg_1')))
          .read<DataGatewayListBloc>()
          .add(const DataGatewayListLoadRequested());
      await tester.pumpAndSettle();
      expect(find.byKey(DataGatewayListScreen.errorKey), findsOneWidget);

      await tester.tap(find.byKey(DataGatewayListScreen.deleteConfirmKey));
      await tester.pumpAndSettle();

      expect(remote.calls, isNot(contains('delete(dg_1)')));
    });

    testWidgets('edit hands the row to the caller and reads the list again '
        'when it returns', (tester) async {
      String? edited;
      remote.listing([bgg]);
      await pumpScreen(
        tester,
        onEdit: (context, id) {
          edited = id;
          openForm(context);
        },
      );

      await choose(tester, 'dg_1', DataGatewayListScreen.editKey);
      expect(edited, 'dg_1');
      expect(find.text('the form'), findsOneWidget);

      remote.listing([bgg.copyWith(name: 'BGG renamed')]);
      await leaveForm(tester);

      expect(find.text('BGG renamed'), findsOneWidget);
    });

    testWidgets('add reads the list again when it returns', (tester) async {
      remote.listing(const []);
      await pumpScreen(tester, onAdd: openForm);

      await tester.tap(find.byKey(DataGatewayListScreen.addKey));
      await tester.pumpAndSettle();
      expect(find.text('the form'), findsOneWidget);

      remote.listing([bgg]);
      await leaveForm(tester);

      expect(find.text('BGG'), findsOneWidget);
    });

    testWidgets('a dialog over the list does not read it again', (
      tester,
    ) async {
      remote.listing([bgg]);
      await pumpScreen(tester);
      await choose(tester, 'dg_1', DataGatewayListScreen.deleteKey);

      // The delete confirmation is open over the list. Dismiss it.
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pumpAndSettle();

      expect(
        remote.calls.where((c) => c.startsWith('fetchPage')),
        hasLength(1),
      );
    });

    testWidgets('reads the list again on coming back from a form it did not '
        'open, as after a deep link or a web reload on the form', (
      tester,
    ) async {
      var reads = 0;
      remote.onFetchPage = (_, _) async =>
          pageOf(++reads == 1 ? [bgg] : [bgg, steam]);
      await tester.pumpWidget(
        MaterialApp(
          theme: BgeTheme.light(),
          localizationsDelegates:
              DataGatewayLocalizations.localizationsDelegates,
          supportedLocales: DataGatewayLocalizations.supportedLocales,
          // Builds the list beneath the form, as go_router does for a form
          // it is sent to directly.
          initialRoute: '/form',
          routes: {
            '/': (_) => DataGatewayListScreen(remote: remote, access: access),
            '/form': (_) => const Scaffold(body: Text('the form')),
          },
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('the form'), findsOneWidget);

      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pumpAndSettle();

      expect(reads, 2);
      expect(find.text('Steam'), findsOneWidget);
    });
  });

  group('whether a DataGateway is in use, and opening it (#457)', () {
    testWidgets('a row shows why it is not in use', (tester) async {
      remote.listing([
        withInterview(bgg, failure: DataGatewayInterviewFailureCode.pingFailed),
        steam,
      ]);

      await pumpScreen(tester);

      expect(
        find.descendant(
          of: find.byKey(DataGatewayListScreen.statusKeyOf('dg_1')),
          matching: find.text("Not in use: it didn't answer"),
        ),
        findsOneWidget,
      );
      // Under the row's name, address and badge, not in place of them.
      expect(
        find.descendant(
          of: find.byKey(DataGatewayListScreen.rowKey('dg_1')),
          matching: find.text('Enabled'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('a disabled row shows only that it is disabled', (
      tester,
    ) async {
      remote.listing([
        withInterview(
          steam,
          failure: DataGatewayInterviewFailureCode.pingFailed,
        ),
      ]);

      await pumpScreen(tester);

      expect(find.text('Disabled'), findsOneWidget);
      expect(
        find.byKey(DataGatewayListScreen.statusKeyOf('dg_2')),
        findsNothing,
      );
      expect(find.textContaining('Not in use'), findsNothing);
    });

    testWidgets('tapping a row opens it', (tester) async {
      final opened = <String>[];
      remote.listing([bgg, steam]);
      await pumpScreen(tester, onOpen: (_, id) => opened.add(id));

      await tester.tap(find.text('BGG'));
      await tester.pumpAndSettle();
      expect(opened, ['dg_1']);

      // The status line is part of the row, not a dead patch in it.
      await tester.tap(find.byKey(DataGatewayListScreen.statusKeyOf('dg_1')));
      await tester.pumpAndSettle();
      expect(opened, ['dg_1', 'dg_1']);
    });

    testWidgets('the row menu does not open the row', (tester) async {
      final opened = <String>[];
      String? edited;
      remote.listing([bgg]);
      await pumpScreen(
        tester,
        onOpen: (_, id) => opened.add(id),
        onEdit: (_, id) => edited = id,
      );

      // Both taps: the one that opens the menu, and the one on its item.
      await choose(tester, 'dg_1', DataGatewayListScreen.editKey);

      expect(edited, 'dg_1');
      expect(opened, isEmpty);
    });

    testWidgets('a row with no onOpen is not tappable', (tester) async {
      remote.listing([bgg]);
      await pumpScreen(tester);

      final tile = tester.widget<ListTile>(
        find.descendant(
          of: find.byKey(DataGatewayListScreen.rowKey('dg_1')),
          matching: find.byType(ListTile),
        ),
      );
      expect(tile.onTap, isNull);
      expect(
        tester.getSemantics(find.text('BGG')),
        isSemantics(isButton: false, hasTapAction: false),
      );
    });

    testWidgets('a row that opens is one button that reads its status, and '
        'its menu stays a button of its own', (tester) async {
      remote.listing([
        withInterview(bgg, failure: DataGatewayInterviewFailureCode.pingFailed),
      ]);
      await pumpScreen(tester, onOpen: (_, _) {});

      final row = tester.getSemantics(find.text('BGG'));
      expect(
        row,
        isSemantics(
          isButton: true,
          hasTapAction: true,
          label:
              "BGG\nbgg.internal:50051\nEnabled\nNot in use: it didn't answer",
        ),
      );
      // By its tooltip: getSemantics on the menu would walk up to the row.
      final menu = find.semantics
          .byPredicate((node) => node.tooltip == 'Actions for BGG')
          .evaluate()
          .single;
      expect(menu, isNot(same(row)));
      expect(
        menu,
        isSemantics(
          isButton: true,
          hasTapAction: true,
          tooltip: 'Actions for BGG',
        ),
      );
    });

    testWidgets('a row opens from the keyboard, and its menu is the next '
        'stop rather than part of it', (tester) async {
      final opened = <String>[];
      remote.listing([bgg]);
      await pumpScreen(tester, onOpen: (_, id) => opened.add(id));

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(opened, ['dg_1']);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byKey(DataGatewayListScreen.editKey), findsOneWidget);
      expect(opened, ['dg_1']);
    });

    testWidgets('a long failure line does not overflow at 200% text', (
      tester,
    ) async {
      tester.view
        ..devicePixelRatio = 1
        ..physicalSize = const Size(320, 800);
      addTearDown(tester.view.reset);
      remote.listing([
        withInterview(
          bgg,
          interviewed: true,
          failure: DataGatewayInterviewFailureCode.describeUnsupported,
        ),
      ]);

      await pumpScreen(
        tester,
        onOpen: (_, _) {},
        textScaler: const TextScaler.linear(BgeTextScale.maxScaleFactor),
      );

      expect(tester.takeException(), isNull);
      expect(
        find.text(
          "Last interview failed: it can't describe itself, so it may need "
          'updating',
        ),
        findsOneWidget,
      );
    });
  });

  for (final (label, window) in [
    ('a phone', const Size(360, 640)),
    ('a phone on its side', const Size(640, 360)),
    ('a desktop window', const Size(1024, 768)),
  ]) {
    testWidgets('on $label, the last row scrolls clear of the add button, so '
        'its menu opens rather than the add form', (tester) async {
      tester.view
        ..devicePixelRatio = 1
        ..physicalSize = window;
      addTearDown(tester.view.reset);
      remote.listing([for (var i = 1; i <= 20; i++) gateway('dg_$i')]);
      var adds = 0;
      await pumpScreen(tester, onAdd: (_) => adds++);

      // To the very end. The rows are built as they come into view, so the
      // end is known only once it is reached.
      final list = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      double? end;
      while (end != list.maxScrollExtent) {
        end = list.maxScrollExtent;
        list.jumpTo(end);
        await tester.pumpAndSettle();
      }
      await tester.tap(find.byKey(DataGatewayListScreen.rowMenuKey('dg_20')));
      await tester.pumpAndSettle();

      expect(adds, 0);
      expect(find.byKey(DataGatewayListScreen.editKey), findsOneWidget);
    });
  }
}
