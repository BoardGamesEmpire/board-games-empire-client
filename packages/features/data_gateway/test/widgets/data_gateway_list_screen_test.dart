import 'dart:async';

import 'package:bge_test_support/access.dart';
import 'package:bge_test_support/widgets.dart';
import 'package:data_gateway/data_gateway.dart';
import 'package:data_gateway/l10n/data_gateway_localizations.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/connectivity.dart';
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
  ///
  /// [textScaler] null leaves the view's own scale. [settle] false pumps one
  /// frame only, for a state whose spinner never lets the screen settle.
  Future<void> pumpScreen(
    WidgetTester tester, {
    void Function(BuildContext context)? onAdd,
    void Function(BuildContext context, String id)? onEdit,
    void Function(BuildContext context, String id)? onOpen,
    TextScaler? textScaler,
    ValueListenable<bool>? offline,
    ThemeData? theme,
    bool settle = true,
  }) async {
    final TransitionBuilder? scaled = textScaler == null
        ? null
        : (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: textScaler),
            child: child!,
          );
    await tester.pumpWidget(
      MaterialApp(
        theme: theme ?? BgeTheme.light(),
        localizationsDelegates: DataGatewayLocalizations.localizationsDelegates,
        supportedLocales: DataGatewayLocalizations.supportedLocales,
        builder: offline == null
            ? scaled
            : connectivityBuilder(offline, inner: scaled),
        home: DataGatewayListScreen(
          remote: remote,
          access: access,
          onAdd: onAdd ?? (_) {},
          onEdit: onEdit ?? (_, _) {},
          onOpen: onOpen,
        ),
      ),
    );
    if (settle) await tester.pumpAndSettle();
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

    testWidgets('a row menu with focus hands it to the heading when its row '
        'goes as update and delete fall', (tester) async {
      remote.listing([bgg, steam]);
      await pumpScreen(tester, onOpen: (_, _) {});
      focusOn(tester, find.byKey(DataGatewayListScreen.rowMenuKey('dg_2')));
      await tester.pump();

      // A read lands without Steam under access that has just fallen: one
      // state drops the row and takes every menu away.
      final reread = Completer<PaginatedResult<DataGateway>>();
      remote.onFetchPage = (_, _) => reread.future;
      tester
          .element(find.text('BGG'))
          .read<DataGatewayListBloc>()
          .add(const DataGatewayListLoadRequested());
      await tester.binding.delayed(Duration.zero);
      access.current = mayOnlyAdd;
      reread.complete(pageOf([bgg]));
      await tester.pumpAndSettle();

      expect(find.text('Steam'), findsNothing);
      expectFocusOn(tester, 'Data gateways');
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

    testWidgets('with the outcome dismissed before the next frame, focus goes '
        'to the row, not the Dismiss that frame takes away', (tester) async {
      remote
        ..listing([bgg, steam])
        ..onDisconnect = (_) async => throw unreachable();
      await pumpScreen(tester, onOpen: (_, _) {});
      await choose(tester, 'dg_1', DataGatewayListScreen.disconnectKey);
      expect(find.byKey(DataGatewayListScreen.outcomeKey), findsOneWidget);
      focusOn(tester, find.byKey(DataGatewayListScreen.rowMenuKey('dg_2')));
      await tester.pump();

      // The answer reaches the screen, and a click dismisses the banner
      // before the frame that takes the menus away. A click focuses nothing.
      access.current = mayOnlyAdd;
      await tester.binding.delayed(Duration.zero);
      tester
          .element(find.text('BGG'))
          .read<DataGatewayListBloc>()
          .add(const DataGatewayListOutcomeDismissed());
      await tester.binding.delayed(Duration.zero);
      await tester.pumpAndSettle();

      expect(find.byKey(DataGatewayListScreen.outcomeKey), findsNothing);
      expectFocusOn(tester, 'Steam');
    });

    testWidgets('a row menu with focus hands it to the heading when a read '
        'refused under access that has just fallen takes the list away', (
      tester,
    ) async {
      remote.listing([bgg, steam]);
      await pumpScreen(tester, onOpen: (_, _) {});
      focusOn(tester, find.byKey(DataGatewayListScreen.rowMenuKey('dg_2')));
      await tester.pump();

      // The answer that takes the menus away lands, and the read out at the
      // time is refused before the next frame.
      final reread = Completer<PaginatedResult<DataGateway>>();
      remote.onFetchPage = (_, _) => reread.future;
      tester
          .element(find.text('BGG'))
          .read<DataGatewayListBloc>()
          .add(const DataGatewayListLoadRequested());
      await tester.binding.delayed(Duration.zero);
      access.current = mayOnlyAdd;
      await tester.binding.delayed(Duration.zero);
      remote.refusingReads();
      reread.completeError(forbidden());
      await tester.pumpAndSettle();

      expect(find.byKey(DataGatewayListScreen.deniedKey), findsOneWidget);
      expectFocusOn(tester, 'Data gateways');
    });

    testWidgets('a row menu with focus hands it to the heading when the read '
        'that takes the menus away moves its row out of view', (tester) async {
      remote.listing([bgg, steam]);
      await pumpScreen(tester, onOpen: (_, _) {});
      focusOn(tester, find.byKey(DataGatewayListScreen.rowMenuKey('dg_2')));
      await tester.pump();

      // A read lands under access that has just fallen, with rows enough
      // above Steam to take it out of the built range.
      final above = [
        for (var i = 0; i < 40; i++) gateway('dg_new_$i', name: 'New $i'),
      ];
      final reread = Completer<PaginatedResult<DataGateway>>();
      remote.onFetchPage = (_, _) => reread.future;
      tester
          .element(find.text('BGG'))
          .read<DataGatewayListBloc>()
          .add(const DataGatewayListLoadRequested());
      await tester.binding.delayed(Duration.zero);
      access.current = mayOnlyAdd;
      reread.complete(pageOf([bgg, ...above, steam]));
      await tester.pumpAndSettle();

      expect(find.text('Steam', skipOffstage: false), findsNothing);
      expectFocusOn(tester, 'Data gateways');

      // Steam coming back into view doesn't take focus either.
      await tester.scrollUntilVisible(find.text('Steam'), 200);
      await tester.pumpAndSettle();
      expectFocusOn(tester, 'Data gateways');
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
      // Clear of the button, not only clear at its centre: the tap below
      // lands mid-menu, which stays above the button's top even when the
      // page leaves it no room and the menu's lower edge sits under it.
      final menu = find.byKey(DataGatewayListScreen.rowMenuKey('dg_20'));
      expect(
        tester
            .getRect(menu)
            .overlaps(tester.getRect(find.byKey(DataGatewayListScreen.addKey))),
        isFalse,
      );
      await tester.tap(menu);
      await tester.pumpAndSettle();

      expect(adds, 0);
      expect(find.byKey(DataGatewayListScreen.editKey), findsOneWidget);
    });
  }

  group('offline (#49)', () {
    late ValueNotifier<bool> offline;

    setUp(() => offline = ValueNotifier(true));

    /// Whether the popup item under [entry] is enabled.
    bool itemEnabled(WidgetTester tester, Finder entry) => tester
        .widget<PopupMenuItem<dynamic>>(
          find.descendant(
            of: entry,
            matching: find.byWidgetPredicate((w) => w is PopupMenuItem),
          ),
        )
        .enabled;

    tearDown(() => offline.dispose());

    Future<void> open(WidgetTester tester, String id) async {
      await tester.tap(find.byKey(DataGatewayListScreen.rowMenuKey(id)));
      await tester.pumpAndSettle();
    }

    /// A popup menu item's one node: both lines in its label, a button that
    /// is not enabled, with no actions.
    Matcher gatedItem(String label) => matchesSemantics(
      label: '$label\n$onlineOnlyCopy',
      isButton: true,
      hasEnabledState: true,
    );

    testWidgets('Connect, Disconnect and Delete are disabled and say why', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      remote.listing([bgg, steam]);
      await pumpScreen(tester, offline: offline);

      // BGG is enabled, so it offers Disconnect as well.
      await open(tester, 'dg_1');
      for (final (key, label) in [
        (DataGatewayListScreen.connectKey, 'Connect'),
        (DataGatewayListScreen.disconnectKey, 'Disconnect'),
        (DataGatewayListScreen.deleteKey, 'Delete'),
      ]) {
        final item = find.byKey(key);
        expect(itemEnabled(tester, item), isFalse);
        expect(tester.getSemantics(item), gatedItem(label), reason: label);
      }
      // Edit writes nothing here: it opens the form.
      expect(
        tester
            .widget<PopupMenuItem<Object?>>(
              find.byKey(DataGatewayListScreen.editKey),
            )
            .enabled,
        isTrue,
      );
      expect(find.text(onlineOnlyCopy), findsNWidgets(3));
      // The anchor stays enabled, so the menu can be opened to read this.
      expect(
        tester
            .widget<PopupMenuButton<Object?>>(
              find.byKey(DataGatewayListScreen.rowMenuKey('dg_1')),
            )
            .enabled,
        isTrue,
      );

      await tester.tap(
        find.byKey(DataGatewayListScreen.deleteKey),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();
      expect(find.byKey(DataGatewayListScreen.deleteConfirmKey), findsNothing);
      expect(remote.calls.where((c) => c.startsWith('delete')), isEmpty);
      handle.dispose();
    });

    testWidgets('online, the same menu is enabled and unannotated', (
      tester,
    ) async {
      offline.value = false;
      remote.listing([bgg]);
      await pumpScreen(tester, offline: offline);

      await open(tester, 'dg_1');

      expect(find.text(onlineOnlyCopy), findsNothing);
      for (final key in [
        DataGatewayListScreen.connectKey,
        DataGatewayListScreen.disconnectKey,
        DataGatewayListScreen.deleteKey,
      ]) {
        expect(itemEnabled(tester, find.byKey(key)), isTrue);
      }
    });

    testWidgets('a menu open when the connection drops goes disabled and says '
        'why, and a press does nothing', (tester) async {
      final handle = tester.ensureSemantics();
      offline.value = false;
      remote.listing([bgg]);
      await pumpScreen(tester, offline: offline);
      await open(tester, 'dg_1');

      offline.value = true;
      await tester.pump();
      await tester.pump();

      for (final (key, label) in [
        (DataGatewayListScreen.connectKey, 'Connect'),
        (DataGatewayListScreen.disconnectKey, 'Disconnect'),
        (DataGatewayListScreen.deleteKey, 'Delete'),
      ]) {
        expect(
          tester.getSemantics(find.byKey(key)),
          gatedItem(label),
          reason: label,
        );
      }
      await tester.tap(
        find.byKey(DataGatewayListScreen.connectKey),
        warnIfMissed: false,
      );
      await tester.pumpAndSettle();

      expect(remote.calls.where((c) => c.startsWith('connect')), isEmpty);
      handle.dispose();
    });

    testWidgets('a menu open when the connection returns goes enabled, loses '
        'the reason, and a press selects', (tester) async {
      final handle = tester.ensureSemantics();
      remote.listing([bgg]);
      remote.onConnect = (_) async => changed(bgg);
      await pumpScreen(tester, offline: offline);
      await open(tester, 'dg_1');
      expect(find.text(onlineOnlyCopy), findsNWidgets(3));

      offline.value = false;
      await tester.pump();

      expect(find.text(onlineOnlyCopy), findsNothing);
      expect(
        tester.getSemantics(find.byKey(DataGatewayListScreen.connectKey)),
        matchesSemantics(
          label: 'Connect',
          isButton: true,
          hasEnabledState: true,
          isEnabled: true,
          hasTapAction: true,
        ),
      );
      await tester.tap(find.byKey(DataGatewayListScreen.connectKey));
      await tester.pumpAndSettle();

      expect(remote.calls.where((c) => c.startsWith('connect')), hasLength(1));
      handle.dispose();
    });
  });

  group('accessibility audit', () {
    /// One of each line a row can show: not in use and why, disabled, in use
    /// with a description, a later interview failed, and waiting for its
    /// first. At 320dp × 2.0 they run below the fold.
    final rows = [
      withInterview(bgg, failure: DataGatewayInterviewFailureCode.pingFailed),
      steam,
      withInterview(
        gateway('dg_3', name: 'Catalog', description: 'The catalog bridge'),
        interviewed: true,
      ),
      withInterview(
        gateway('dg_4', name: 'Archive'),
        interviewed: true,
        failure: DataGatewayInterviewFailureCode.describeFailed,
      ),
      gateway('dg_5', name: 'Spare'),
    ];

    /// The screen as the shell composes it, with add, edit and open all
    /// passed, so the caller's access alone decides which controls show.
    /// [seed] scripts the fakes before the first read goes out. [offline]
    /// holds the connection down through a notifier of the cell's own, which
    /// goes with it.
    Future<void> Function(WidgetTester, ThemeData) screen({
      void Function()? seed,
      bool offline = false,
      bool settle = true,
    }) => (tester, theme) {
      (seed ?? () => remote.listing(rows))();
      final notifier = offline ? ValueNotifier(true) : null;
      if (notifier != null) addTearDown(notifier.dispose);
      return pumpScreen(
        tester,
        theme: theme,
        onAdd: (_) {},
        onEdit: (_, _) {},
        onOpen: (_, _) {},
        offline: notifier,
        settle: settle,
      );
    };

    final ready = screen();

    /// May read DataGateways, and nothing else: the fewest controls.
    void reader() {
      access.current = FakeCallerAccessRepository.dataGateway(
        read: AccessExtent.all,
      );
      remote.listing(rows);
    }

    void expectFullAccess() {
      expect(find.byKey(DataGatewayListScreen.addKey), findsOneWidget);
      expect(
        find.byKey(DataGatewayListScreen.rowMenuKey('dg_1')),
        findsOneWidget,
      );
    }

    /// Opens BGG's menu, which offers every item: BGG is enabled, so it has
    /// Disconnect as well.
    Future<void> openBggsMenu(WidgetTester tester) async {
      await tester.tap(find.byKey(DataGatewayListScreen.rowMenuKey('dg_1')));
      await tester.pumpAndSettle();
      for (final key in [
        DataGatewayListScreen.editKey,
        DataGatewayListScreen.connectKey,
        DataGatewayListScreen.disconnectKey,
        DataGatewayListScreen.deleteKey,
      ]) {
        expect(find.byKey(key), findsOneWidget, reason: '$key');
      }
      // The last item is on screen, not merely built in a panel that scrolls.
      expect(
        find.byKey(DataGatewayListScreen.deleteKey).hitTestable(),
        findsOneWidget,
      );
    }

    /// The spinner that stands in for [id]'s menu while its action runs.
    Finder busyOn(String id) => find.descendant(
      of: find.byKey(DataGatewayListScreen.rowKey(id)),
      matching: find.byType(CircularProgressIndicator),
    );

    /// Makes every connect one that never answers.
    void holdConnects() =>
        remote.onConnect = (_) => Completer<DataGatewayChangeResult>().future;

    /// Pumps through a menu's or a dialog's way in or out. Not a settle: a
    /// row's spinner never stops.
    Future<void> pumpThrough(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    }

    void expectOutcome(String message) => expect(
      find.descendant(
        of: find.byKey(DataGatewayListScreen.outcomeKey),
        matching: find.text(message),
      ),
      findsOneWidget,
    );

    auditScreen(
      'loading',
      pump: screen(
        seed: () =>
            remote.onFetchPage = (_, _) =>
                Completer<PaginatedResult<DataGateway>>().future,
        settle: false,
      ),
      settle: false,
      arrange: (tester) async {
        await tester.pump();
        expect(find.byKey(DataGatewayListScreen.loadingKey), findsOneWidget);
      },
    );

    auditScreen(
      'access denied',
      pump: screen(seed: () => remote.refusingReads()),
      arrange: (tester) async {
        expect(find.byKey(DataGatewayListScreen.deniedKey), findsOneWidget);
      },
    );

    auditScreen(
      'failed, with retry',
      pump: screen(
        seed: () => remote.onFetchPage = (_, _) async => throw unreachable(),
      ),
      arrange: (tester) async {
        expect(find.byKey(DataGatewayListScreen.errorKey), findsOneWidget);
        expect(find.text('Try again'), findsOneWidget);
      },
    );

    auditScreen(
      'empty',
      pump: screen(seed: () => remote.listing(const [])),
      arrange: (tester) async {
        expect(find.byKey(DataGatewayListScreen.emptyKey), findsOneWidget);
        expect(find.byKey(DataGatewayListScreen.addKey), findsOneWidget);
      },
    );

    auditScreen(
      'ready, full access',
      pump: ready,
      arrange: (tester) async => expectFullAccess(),
    );

    auditScreen(
      'ready, scrolled to the end',
      pump: ready,
      arrange: (tester) async {
        await scrollListToEnd(
          tester,
          find.byKey(DataGatewayListScreen.rowKey('dg_5')),
        );
        expect(
          find.byKey(DataGatewayListScreen.rowMenuKey('dg_5')),
          findsOneWidget,
        );
        expect(find.byKey(DataGatewayListScreen.addKey), findsOneWidget);
      },
    );

    // At 320dp × 2.0 a row is 340–700dp tall: the top holds BGG and Steam,
    // the end holds Spare alone, and Catalog and Archive are on screen in
    // neither. This audits every row in a view tall enough to hold the list
    // whole (#50).
    auditScreen(
      'ready, whole page',
      pump: ready,
      arrange: (tester) async {
        await useWholePage(tester);
        for (final row in rows) {
          expect(
            find.byKey(DataGatewayListScreen.rowMenuKey(row.id)),
            findsOneWidget,
            reason: row.id,
          );
        }
        expectWholePage(tester);
      },
    );

    auditScreen(
      'ready, read-only',
      pump: screen(seed: reader),
      arrange: (tester) async {
        expect(find.text('BGG'), findsOneWidget);
        expect(find.byKey(DataGatewayListScreen.addKey), findsNothing);
        for (final row in rows) {
          expect(
            find.byKey(DataGatewayListScreen.rowMenuKey(row.id)),
            findsNothing,
          );
        }
      },
    );

    auditScreen('row menu open', pump: ready, arrange: openBggsMenu);

    auditScreen(
      'delete confirm',
      pump: ready,
      arrange: (tester) async {
        await choose(tester, 'dg_1', DataGatewayListScreen.deleteKey);
        expect(find.text('Delete BGG?'), findsOneWidget);
        expect(
          find.byKey(DataGatewayListScreen.deleteConfirmKey),
          findsOneWidget,
        );
      },
    );

    // The connect never answers, so BGG's row keeps spinning.
    auditScreen(
      'connect in flight',
      pump: ready,
      settle: false,
      arrange: (tester) async {
        holdConnects();
        await tester.tap(find.byKey(DataGatewayListScreen.rowMenuKey('dg_1')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(DataGatewayListScreen.connectKey));
        await pumpThrough(tester);
        expect(busyOn('dg_1'), findsOneWidget);
      },
    );

    // A dialog over a busy list: BGG's delete confirm while Steam spins.
    auditScreen(
      'delete confirm, over a connect in flight',
      pump: ready,
      settle: false,
      arrange: (tester) async {
        holdConnects();
        // At 320dp × 2.0 Steam's menu sits under the Add button, so its
        // connect starts as its menu item would start it.
        tester
            .element(find.text('BGG'))
            .read<DataGatewayListBloc>()
            .add(
              const DataGatewayListActionRequested(
                DataGatewayRowAction.connect,
                'dg_2',
              ),
            );
        await pumpThrough(tester);
        expect(busyOn('dg_2'), findsOneWidget);

        await tester.tap(find.byKey(DataGatewayListScreen.rowMenuKey('dg_1')));
        await pumpThrough(tester);
        await tester.tap(find.byKey(DataGatewayListScreen.deleteKey));
        await pumpThrough(tester);
        expect(find.text('Delete BGG?'), findsOneWidget);
        expect(busyOn('dg_2'), findsOneWidget);
      },
    );

    // One call per tone the banner takes: info, error, warning and success.
    auditScreen(
      'action outcome, refused',
      pump: screen(
        seed: () {
          remote
            ..listing(rows)
            ..onConnect = (_) async => throw forbidden();
        },
      ),
      arrange: (tester) async {
        await choose(tester, 'dg_1', DataGatewayListScreen.connectKey);
        expectOutcome("Your role can't change data gateways.");
      },
    );

    auditScreen(
      'action outcome, failed',
      pump: screen(
        seed: () {
          remote
            ..listing(rows)
            ..onDisconnect = (_) async => throw unreachable();
        },
      ),
      arrange: (tester) async {
        await choose(tester, 'dg_1', DataGatewayListScreen.disconnectKey);
        expectOutcome("We couldn't disconnect from BGG. Try again.");
      },
    );

    auditScreen(
      'action outcome, attempt failed',
      pump: screen(
        seed: () {
          remote
            ..listing(rows)
            ..onConnect = (_) async => changed(
              bgg,
              attempted: DataGatewayConnectionAction.connect,
              succeeded: false,
            );
        },
      ),
      arrange: (tester) async {
        await choose(tester, 'dg_1', DataGatewayListScreen.connectKey);
        expectOutcome("BGG is enabled, but the server couldn't connect to it.");
      },
    );

    auditScreen(
      'action outcome, done',
      pump: screen(
        seed: () {
          remote
            ..listing(rows)
            ..onConnect = (_) async =>
                changed(bgg, attempted: DataGatewayConnectionAction.connect);
        },
      ),
      arrange: (tester) async {
        await choose(tester, 'dg_1', DataGatewayListScreen.connectKey);
        expectOutcome('Connected to BGG.');
      },
    );

    // Offline changes nothing on the list itself: only the menu's direct
    // writes go disabled, with the reason under each.
    auditScreen(
      'offline, row menu open',
      pump: screen(offline: true),
      arrange: (tester) async {
        await openBggsMenu(tester);
        expect(find.text(onlineOnlyCopy), findsNWidgets(3));
      },
    );
  });
}
