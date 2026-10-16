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
    Future<void> Function(BuildContext context)? onAdd,
    Future<void> Function(BuildContext context, String id)? onEdit,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: BgeTheme.light(),
        localizationsDelegates: DataGatewayLocalizations.localizationsDelegates,
        supportedLocales: DataGatewayLocalizations.supportedLocales,
        home: DataGatewayListScreen(
          remote: remote,
          access: access,
          onAdd: onAdd ?? (_) async {},
          onEdit: onEdit ?? (_, _) async {},
        ),
      ),
    );
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
      await pumpScreen(tester, onEdit: (_, id) async => edited = id);

      remote.listing([bgg.copyWith(name: 'BGG renamed')]);
      await choose(tester, 'dg_1', DataGatewayListScreen.editKey);

      expect(edited, 'dg_1');
      expect(find.text('BGG renamed'), findsOneWidget);
    });

    testWidgets('add reads the list again when it returns', (tester) async {
      remote.listing(const []);
      await pumpScreen(tester);

      remote.listing([bgg]);
      await tester.tap(find.byKey(DataGatewayListScreen.addKey));
      await tester.pumpAndSettle();

      expect(find.text('BGG'), findsOneWidget);
    });
  });
}
