import 'dart:async';

import 'package:data_gateway/data_gateway.dart';
import 'package:data_gateway/l10n/data_gateway_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/fake_data_gateway_remote.dart';

void main() {
  late FakeDataGatewayRemote remote;
  late DataGatewayAccess access;

  final bgg = gateway(
    'dg_1',
    name: 'BGG',
    connectionUrl: 'bgg.internal',
    connectionPort: 50051,
  );
  final steam = gateway('dg_2', name: 'Steam', enabled: false);

  setUp(() {
    remote = FakeDataGatewayRemote();
    access = DataGatewayAccess(remote: remote);
  });

  tearDown(() => access.dispose());

  Future<void> pumpScreen(
    WidgetTester tester, {
    void Function(BuildContext context)? onAdd,
    void Function(BuildContext context, String id)? onEdit,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: BgeTheme.light(),
        localizationsDelegates: DataGatewayLocalizations.localizationsDelegates,
        supportedLocales: DataGatewayLocalizations.supportedLocales,
        home: DataGatewayListScreen(
          remote: remote,
          access: access,
          onAdd: onAdd ?? (_) {},
          onEdit: onEdit ?? (_, _) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

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

  group('a caller who may read but not change DataGateways (#41)', () {
    testWidgets('sees the change actions until the first change is refused, '
        'then not at all', (tester) async {
      remote
        ..listing([bgg, steam])
        ..onConnect = (_) async => throw forbidden();
      await pumpScreen(tester);

      expect(find.byKey(DataGatewayListScreen.addKey), findsOneWidget);
      expect(
        find.byKey(DataGatewayListScreen.rowMenuKey('dg_2')),
        findsOneWidget,
      );

      await choose(tester, 'dg_2', DataGatewayListScreen.connectKey);

      expect(
        find.text("Your role can't change data gateways."),
        findsOneWidget,
      );
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
