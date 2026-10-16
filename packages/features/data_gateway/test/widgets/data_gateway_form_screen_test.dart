import 'package:data_gateway/data_gateway.dart';
import 'package:data_gateway/l10n/data_gateway_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/fake_data_gateway_remote.dart';

void main() {
  late FakeDataGatewayRemote remote;
  late DataGatewayAccess access;
  late int doneCount;

  final bgg = gateway(
    'dg_1',
    name: 'BGG',
    description: 'The BGG bridge',
    connectionUrl: 'bgg.internal',
    connectionPort: 50051,
  );

  setUp(() {
    remote = FakeDataGatewayRemote();
    access = DataGatewayAccess(remote: remote);
    doneCount = 0;
  });

  tearDown(() => access.dispose());

  Future<void> pumpForm(WidgetTester tester, {String? editingId}) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: BgeTheme.light(),
        localizationsDelegates: DataGatewayLocalizations.localizationsDelegates,
        supportedLocales: DataGatewayLocalizations.supportedLocales,
        home: DataGatewayFormScreen(
          remote: remote,
          access: access,
          editingId: editingId,
          onDone: (_) => doneCount++,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> enter(WidgetTester tester, Key field, String text) async {
    await tester.enterText(find.byKey(field), text);
    await tester.pump();
  }

  Future<void> fillValid(WidgetTester tester) async {
    await enter(tester, DataGatewayForm.nameFieldKey, 'BGG');
    await enter(tester, DataGatewayForm.addressFieldKey, 'bgg.internal');
    await enter(tester, DataGatewayForm.portFieldKey, '50051');
  }

  Future<void> submit(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(DataGatewayForm.submitKey));
    await tester.tap(find.byKey(DataGatewayForm.submitKey));
    await tester.pumpAndSettle();
  }

  group('adding', () {
    testWidgets('has no credentials field, and says why (#41)', (tester) async {
      await pumpForm(tester);

      expect(
        find.text(
          'The server connects without credentials. Other sign-in methods '
          "aren't supported yet.",
        ),
        findsOneWidget,
      );
      expect(find.byType(TextField), findsNWidgets(4));
    });

    testWidgets('creates the DataGateway, says what the connect answered, '
        'and leaves', (tester) async {
      DataGatewayInput? sent;
      remote.onCreate = (input) async {
        sent = input;
        return changed(bgg, attempted: DataGatewayConnectionAction.connect);
      };
      await pumpForm(tester);

      await fillValid(tester);
      await submit(tester);

      expect(
        sent,
        const DataGatewayInput(
          name: 'BGG',
          connectionUrl: 'bgg.internal',
          connectionPort: 50051,
        ),
      );
      expect(find.text('Added BGG and connected to it.'), findsOneWidget);
      expect(doneCount, 1);
    });

    testWidgets('a port outside 1–65535 is refused on the form', (
      tester,
    ) async {
      await pumpForm(tester);

      await fillValid(tester);
      await enter(tester, DataGatewayForm.portFieldKey, '70000');
      await submit(tester);

      expect(find.text('Enter a port from 1 to 65535.'), findsOneWidget);
      expect(remote.calls, isEmpty);
    });

    for (final port in ['0x50', '+8080']) {
      testWidgets('a port that is not plain digits, such as "$port", is '
          'refused rather than read as another number', (tester) async {
        await pumpForm(tester);

        await fillValid(tester);
        await enter(tester, DataGatewayForm.portFieldKey, port);
        await submit(tester);

        expect(find.text('Enter a port from 1 to 65535.'), findsOneWidget);
        expect(remote.calls, isEmpty);
      });
    }

    testWidgets('blank required fields are refused on the form', (
      tester,
    ) async {
      await pumpForm(tester);

      await submit(tester);

      expect(find.text('Enter a name.'), findsOneWidget);
      expect(find.text('Enter a connection address.'), findsOneWidget);
      expect(remote.calls, isEmpty);
    });

    testWidgets('a name already in use is said so, and the form stays', (
      tester,
    ) async {
      remote.onCreate = (_) async =>
          throw const DataGatewayNameInUseException('taken', statusCode: 409);
      await pumpForm(tester);

      await fillValid(tester);
      await submit(tester);

      expect(
        find.text('Another data gateway already uses this name.'),
        findsOneWidget,
      );
      expect(doneCount, 0);
    });
  });

  group('editing', () {
    testWidgets('opens on the row and saves only what changed', (tester) async {
      DataGatewayChanges? sent;
      remote.onFetchOne = (_) async => bgg;
      remote.onUpdate = (_, changes) async {
        sent = changes;
        return changed(bgg.copyWith(connectionPort: 50060));
      };
      await pumpForm(tester, editingId: 'dg_1');

      expect(find.text('bgg.internal'), findsOneWidget);
      await enter(tester, DataGatewayForm.portFieldKey, '50060');
      await submit(tester);

      expect(sent, const DataGatewayChanges(connectionPort: 50060));
      expect(find.text('Saved BGG.'), findsOneWidget);
      expect(doneCount, 1);
    });

    testWidgets('a row with credentials is not described as having none, and '
        'keeps its sign-in method', (tester) async {
      // Created outside this app with another auth type. The edit sends only
      // what changed (#41), so the auth type is left as it is.
      remote.onFetchOne = (_) async =>
          bgg.copyWith(authType: DataGatewayAuthType.bearer);
      await pumpForm(tester, editingId: 'dg_1');

      expect(
        find.text(
          "This data gateway uses a sign-in method this app can't change "
          'yet. Saving leaves it as it is.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('connects without credentials'), findsNothing);
    });

    testWidgets("can't be saved with nothing changed (#41)", (tester) async {
      remote.onFetchOne = (_) async => bgg;
      await pumpForm(tester, editingId: 'dg_1');

      await submit(tester);

      expect(find.text('Nothing has changed yet.'), findsOneWidget);
      expect(remote.calls, ['fetchOne(dg_1)']);
    });

    testWidgets('a row that does not exist says so', (tester) async {
      remote.onFetchOne = (_) async =>
          throw const DataGatewayNotFoundException('gone', statusCode: 404);

      await pumpForm(tester, editingId: 'dg_404');

      expect(find.text("This data gateway doesn't exist"), findsOneWidget);
    });

    testWidgets('rebuilt for another row, opens on that row and saves to it, '
        'as when a router reuses the page', (tester) async {
      final other = gateway('dg_2', name: 'Other', connectionUrl: 'other.host');
      remote.onFetchOne = (id) async => id == 'dg_1' ? bgg : other;
      remote.onUpdate = (_, _) async => changed(other);
      await pumpForm(tester, editingId: 'dg_1');

      await pumpForm(tester, editingId: 'dg_2');

      expect(find.text('other.host'), findsOneWidget);
      expect(find.text('bgg.internal'), findsNothing);
      await enter(tester, DataGatewayForm.portFieldKey, '50060');
      await submit(tester);
      expect(remote.calls, [
        'fetchOne(dg_1)',
        'fetchOne(dg_2)',
        'update(dg_2)',
      ]);
    });
  });

  group('access (#41)', () {
    testWidgets('a deep link by a user who may not read shows access-denied', (
      tester,
    ) async {
      remote.onFetchOne = (_) async => throw forbidden();

      await pumpForm(tester, editingId: 'dg_1');

      expect(
        find.text("You don't have access to data gateways"),
        findsOneWidget,
      );
      expect(find.byKey(DataGatewayForm.submitKey), findsNothing);
    });

    testWidgets('a refused save says why and stops offering the save', (
      tester,
    ) async {
      remote.onCreate = (_) async => throw forbidden();
      await pumpForm(tester);

      await fillValid(tester);
      await submit(tester);

      expect(
        find.text("Your role can't change data gateways."),
        findsOneWidget,
      );
      expect(find.byKey(DataGatewayForm.submitKey), findsNothing);
      expect(doneCount, 0);
    });
  });
}
