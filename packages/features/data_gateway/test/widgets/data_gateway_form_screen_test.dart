import 'dart:async';

import 'package:bge_test_support/access.dart';
import 'package:bge_test_support/session.dart';
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
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/connectivity.dart';
import '../support/fake_data_gateway_remote.dart';

/// What a save that failed for any other reason says (#464 reuses it late).
const _failedCopy = "We couldn't save this data gateway. Try again.";

void main() {
  late FakeDataGatewayRemote remote;
  late FakeCallerAccessRepository access;
  late int doneCount;
  late FakeSessionLease lease;

  final bgg = gateway(
    'dg_1',
    name: 'BGG',
    description: 'The BGG bridge',
    connectionUrl: 'bgg.internal',
  );

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
    doneCount = 0;
    lease = FakeSessionLease();
  });

  /// [settle] false pumps one frame only, for a state whose spinner never
  /// lets the screen settle.
  Future<void> pumpForm(
    WidgetTester tester, {
    String? editingId,
    ValueListenable<bool>? offline,
    ThemeData? theme,
    bool settle = true,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: theme ?? BgeTheme.light(),
        localizationsDelegates: DataGatewayLocalizations.localizationsDelegates,
        supportedLocales: DataGatewayLocalizations.supportedLocales,
        builder: offline == null ? null : connectivityBuilder(offline),
        home: DataGatewayFormScreen(
          remote: remote,
          session: lease,
          access: access,
          editingId: editingId,
          onDone: (_) => doneCount++,
        ),
      ),
    );
    if (settle) await tester.pumpAndSettle();
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

    testWidgets('a save that lands after the user went back says it saved, '
        'and leaves nothing more', (tester) async {
      final pending = Completer<DataGatewayChangeResult>();
      remote.onCreate = (_) => pending.future;
      await tester.pumpWidget(
        MaterialApp(
          theme: BgeTheme.light(),
          localizationsDelegates:
              DataGatewayLocalizations.localizationsDelegates,
          supportedLocales: DataGatewayLocalizations.supportedLocales,
          home: const Scaffold(body: Text('home')),
        ),
      );
      final navigator = tester.state<NavigatorState>(find.byType(Navigator))
        ..push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('list')),
          ),
        );
      await tester.pumpAndSettle();
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => DataGatewayFormScreen(
            remote: remote,
            session: lease,
            access: access,
            // As the shell's does: leaving is a pop.
            onDone: (context) {
              doneCount++;
              Navigator.of(context).pop();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await fillValid(tester);
      await tester.ensureVisible(find.byKey(DataGatewayForm.submitKey));
      await tester.tap(find.byKey(DataGatewayForm.submitKey));
      await tester.pump();

      await tester.tap(find.byType(BackButton));
      // Partway through the form's way out, while it still listens.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      pending.complete(
        changed(bgg, attempted: DataGatewayConnectionAction.connect),
      );
      await tester.pumpAndSettle();

      expect(find.text('Added BGG and connected to it.'), findsOneWidget);
      expect(doneCount, 0);
      expect(find.text('list'), findsOneWidget);
    });

    testWidgets('a save that lands while a page covers the form says it '
        'saved, and leaves once the user comes back', (tester) async {
      final pending = Completer<DataGatewayChangeResult>();
      remote.onCreate = (_) => pending.future;
      await tester.pumpWidget(
        MaterialApp(
          theme: BgeTheme.light(),
          localizationsDelegates:
              DataGatewayLocalizations.localizationsDelegates,
          supportedLocales: DataGatewayLocalizations.supportedLocales,
          home: const Scaffold(body: Text('list')),
        ),
      );
      final navigator = tester.state<NavigatorState>(find.byType(Navigator))
        ..push(
          MaterialPageRoute<void>(
            builder: (_) => DataGatewayFormScreen(
              remote: remote,
              session: lease,
              access: access,
              // As the shell's does: leaving is a pop.
              onDone: (context) {
                doneCount++;
                Navigator.of(context).pop();
              },
            ),
          ),
        );
      await tester.pumpAndSettle();
      await fillValid(tester);
      await tester.ensureVisible(find.byKey(DataGatewayForm.submitKey));
      await tester.tap(find.byKey(DataGatewayForm.submitKey));
      await tester.pump();

      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('cover')),
        ),
      );
      await tester.pumpAndSettle();
      pending.complete(
        changed(bgg, attempted: DataGatewayConnectionAction.connect),
      );
      await tester.pumpAndSettle();

      expect(find.text('Added BGG and connected to it.'), findsOneWidget);
      expect(doneCount, 0);
      expect(find.text('cover'), findsOneWidget);

      navigator.pop();
      await tester.pumpAndSettle();

      expect(doneCount, 1);
      expect(find.text('list'), findsOneWidget);
      expect(find.byType(DataGatewayFormScreen), findsNothing);
    });
  });

  // #464, #694: a save outlives the form. Left while it is under way, it
  // still says how it went, on the page the user went back to, while the
  // session it started in is live.
  group('left mid-save', () {
    late Completer<DataGatewayChangeResult> gate;
    late DataGatewayFormBloc bloc;

    /// Opens the add form over a list page and submits a create that waits
    /// on [gate].
    Future<void> submitHeld(WidgetTester tester) async {
      // Made in the test body, inside its fake async zone: one made in
      // setUp completes outside it, where pumping never gets to it.
      gate = Completer<DataGatewayChangeResult>();
      remote.onCreate = (_) => gate.future;
      await tester.pumpWidget(
        MaterialApp(
          theme: BgeTheme.light(),
          localizationsDelegates:
              DataGatewayLocalizations.localizationsDelegates,
          supportedLocales: DataGatewayLocalizations.supportedLocales,
          home: const Scaffold(body: Text('list')),
        ),
      );
      tester
          .state<NavigatorState>(find.byType(Navigator))
          .push(
            MaterialPageRoute<void>(
              builder: (_) => DataGatewayFormScreen(
                remote: remote,
                access: access,
                session: lease,
                onDone: (context) {
                  doneCount++;
                  Navigator.of(context).pop();
                },
              ),
            ),
          );
      await tester.pumpAndSettle();
      await fillValid(tester);
      await tester.ensureVisible(find.byKey(DataGatewayForm.submitKey));
      await tester.tap(find.byKey(DataGatewayForm.submitKey));
      await tester.pump();
      bloc = BlocProvider.of<DataGatewayFormBloc>(
        tester.element(find.byType(DataGatewayForm)),
      );
    }

    /// Opens the add form over a list page, submits a create that waits on
    /// [gate], and goes back while it is under way.
    Future<void> submitThenLeave(WidgetTester tester) async {
      await submitHeld(tester);

      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(DataGatewayFormScreen), findsNothing);
    }

    Future<bool> closed(WidgetTester tester) async {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      return bloc.isClosed;
    }

    Finder inSnackBar(String copy) =>
        find.descendant(of: find.byType(SnackBar), matching: find.text(copy));

    testWidgets('the outcome is still said, and nothing is left', (
      tester,
    ) async {
      await submitThenLeave(tester);

      gate.complete(
        changed(bgg, attempted: DataGatewayConnectionAction.connect),
      );
      await tester.pumpAndSettle();

      expect(find.text('Added BGG and connected to it.'), findsOneWidget);
      expect(find.text('list'), findsOneWidget);
      expect(doneCount, 0);
    });

    testWidgets('a failure is still said', (tester) async {
      await submitThenLeave(tester);

      gate.completeError(StateError('db is down'));
      await tester.pumpAndSettle();

      expect(inSnackBar(_failedCopy), findsOneWidget);
      expect(find.text('list'), findsOneWidget);
      expect(doneCount, 0);
    });

    // An add that fails after access has fallen settles as access-denied,
    // not as a failure. The user has left, so it is still said.
    testWidgets('an add that fails once access no longer allows it says the '
        "role's refusal", (tester) async {
      await submitThenLeave(tester);
      access.current = FakeCallerAccessRepository.dataGateway(
        read: AccessExtent.all,
      );
      await tester.pump();

      gate.completeError(forbidden());
      await tester.pumpAndSettle();

      expect(bloc.state, isA<DataGatewayFormDenied>());
      expect(inSnackBar("Your role can't change data gateways."), findsOne);
      expect(find.text('list'), findsOneWidget);
      expect(doneCount, 0);
      expect(await closed(tester), isTrue);
    });

    testWidgets('nothing is said once the session has ended', (tester) async {
      await submitThenLeave(tester);
      lease.isLive = false;

      gate.complete(
        changed(bgg, attempted: DataGatewayConnectionAction.connect),
      );
      await tester.pumpAndSettle();

      expect(find.byType(SnackBar), findsNothing);
      expect(find.text('list'), findsOneWidget);
      expect(doneCount, 0);
      // Still closed: ending the session skips the message, not the close.
      expect(await closed(tester), isTrue);
    });

    // The shell ends a session in the same turn it routes away, and the
    // popped route stays mounted through its exit. A save that settles there
    // asks the lease (#694), is said as it would be once the form had gone,
    // and goes nowhere (#464).
    group("on the route's way out", () {
      /// Submits a create that waits on [gate], pops the form and, in the
      /// same turn when [endSession], ends the session, then pumps 50 ms
      /// into the exit.
      Future<void> submitThenPop(
        WidgetTester tester, {
        bool endSession = false,
      }) async {
        await submitHeld(tester);
        Navigator.of(tester.element(find.byType(DataGatewayForm))).pop();
        if (endSession) lease.isLive = false;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(find.byType(DataGatewayFormScreen), findsOneWidget);
      }

      /// Gives the answer, and lets it reach the form, still inside the exit.
      Future<void> answer(WidgetTester tester, {required bool fails}) async {
        if (fails) {
          gate.completeError(StateError('db is down'));
        } else {
          gate.complete(
            changed(bgg, attempted: DataGatewayConnectionAction.connect),
          );
        }
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(find.byType(DataGatewayFormScreen), findsOneWidget);
      }

      /// The keys of the bars showing: a bar said again is a new key.
      Set<Key?> barKeys(WidgetTester tester) => {
        for (final bar in tester.widgetList<SnackBar>(find.byType(SnackBar)))
          bar.key,
      };

      for (final (name, fails) in [('lands', false), ('fails', true)]) {
        testWidgets('a save that $name after the session ended says nothing, '
            'and the bloc still closes', (tester) async {
          await submitThenPop(tester, endSession: true);

          await answer(tester, fails: fails);
          expect(find.byType(SnackBar), findsNothing);
          await tester.pumpAndSettle();

          expect(find.byType(SnackBar), findsNothing);
          expect(find.text('list'), findsOneWidget);
          expect(doneCount, 0);
          expect(await closed(tester), isTrue);
        });
      }

      for (final (name, fails, copy) in [
        ('lands', false, 'Added BGG and connected to it.'),
        ('fails', true, _failedCopy),
      ]) {
        testWidgets('a save that $name is said once, and goes nowhere', (
          tester,
        ) async {
          await submitThenPop(tester);

          await answer(tester, fails: fails);
          // One bar, drawn in both pages' scaffolds while the exit runs.
          expect(inSnackBar(copy), findsWidgets);
          final said = barKeys(tester);
          expect(said, hasLength(1));
          await tester.pumpAndSettle();

          expect(inSnackBar(copy), findsOneWidget);
          expect(barKeys(tester), said);
          expect(find.byType(DataGatewayFormScreen), findsNothing);
          expect(find.text('list'), findsOneWidget);
          expect(doneCount, 0);
          expect(await closed(tester), isTrue);
        });
      }
    });

    testWidgets("going to another row's edit mid-save still says the first "
        'save, and the second form starts fresh', (tester) async {
      final first = gateway('dg_1', name: 'First', connectionUrl: 'a.internal');
      final second = gateway(
        'dg_2',
        name: 'Second',
        connectionUrl: 'b.internal',
      );
      final pending = Completer<DataGatewayChangeResult>();
      remote
        ..onFetchOne = ((id) async => id == 'dg_1' ? first : second)
        ..onUpdate = ((_, _) => pending.future);
      await pumpForm(tester, editingId: 'dg_1');
      await enter(tester, DataGatewayForm.portFieldKey, '50060');
      await tester.ensureVisible(find.byKey(DataGatewayForm.submitKey));
      await tester.tap(find.byKey(DataGatewayForm.submitKey));
      await tester.pump();

      // go_router rebuilds the same page in place for another id.
      await pumpForm(tester, editingId: 'dg_2');
      pending.complete(changed(first.copyWith(connectionPort: 50060)));
      await tester.pumpAndSettle();

      expect(find.text('Saved First.'), findsOneWidget);
      expect(doneCount, 0);
      expect(find.text('b.internal'), findsOneWidget);
      // The fresh bloc is idle: the first save's submitting did not carry
      // over to the second row's form.
      expect(
        tester
            .widget<BgeSubmitButton>(find.byKey(DataGatewayForm.submitKey))
            .submitting,
        isFalse,
      );
    });
  });

  group('editing', () {
    testWidgets('opens on the row and saves only what changed', (tester) async {
      DataGatewayChanges? sent;
      remote
        ..onFetchOne = ((_) async => bgg)
        ..onUpdate = (_, changes) async {
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

    group('a row saved elsewhere with spaces around its values', () {
      // The server keeps what it is sent; only this form trims.
      final padded = bgg.copyWith(
        name: ' BGG ',
        description: ' The BGG bridge ',
        connectionUrl: ' bgg.internal ',
      );

      testWidgets("left as it was, can't be saved with nothing changed", (
        tester,
      ) async {
        remote.onFetchOne = (_) async => padded;
        await pumpForm(tester, editingId: 'dg_1');

        await submit(tester);

        expect(find.text('Nothing has changed yet.'), findsOneWidget);
        expect(remote.calls, ['fetchOne(dg_1)']);
      });

      testWidgets('with only its port edited, sends only the port, so the '
          "fields left alone can't overwrite someone else's change", (
        tester,
      ) async {
        DataGatewayChanges? sent;
        remote
          ..onFetchOne = ((_) async => padded)
          ..onUpdate = (_, changes) async {
            sent = changes;
            return changed(padded.copyWith(connectionPort: 50060));
          };
        await pumpForm(tester, editingId: 'dg_1');

        await enter(tester, DataGatewayForm.portFieldKey, '50060');
        await submit(tester);

        expect(sent, const DataGatewayChanges(connectionPort: 50060));
      });
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
      remote
        ..onFetchOne = ((id) async => id == 'dg_1' ? bgg : other)
        ..onUpdate = (_, _) async => changed(other);
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

  group('what the caller may do (#456)', () {
    /// Whether the field [key] finds takes no typing.
    bool readOnly(WidgetTester tester, Key key) => tester
        .widget<TextField>(
          find.descendant(
            of: find.byKey(key),
            matching: find.byType(TextField),
          ),
        )
        .readOnly;

    testWidgets('a deep link by a user who may not read shows access-denied, '
        'and asks access again', (tester) async {
      remote.onFetchOne = (_) async => throw forbidden();

      await pumpForm(tester, editingId: 'dg_1');

      expect(
        find.text("You don't have access to data gateways"),
        findsOneWidget,
      );
      expect(find.byKey(DataGatewayForm.submitKey), findsNothing);
      expect(access.refreshCount, 1);
    });

    testWidgets('an add while access is unknown shows read-only fields, then '
        'opens when create arrives', (tester) async {
      access.current = const CallerAccess.unknown();
      await pumpForm(tester);

      expect(find.byKey(DataGatewayForm.submitKey), findsNothing);
      expect(find.byKey(DataGatewayForm.refusedKey), findsNothing);
      expect(readOnly(tester, DataGatewayForm.nameFieldKey), isTrue);

      access.current = FakeCallerAccessRepository.dataGateway(
        create: AccessExtent.all,
      );
      await tester.pumpAndSettle();

      expect(find.byKey(DataGatewayForm.submitKey), findsOneWidget);
      expect(readOnly(tester, DataGatewayForm.nameFieldKey), isFalse);
    });

    testWidgets('while access is unknown an edit says nothing about the role, '
        'and says why once access answers without update', (tester) async {
      access.current = const CallerAccess.unknown();
      remote.onFetchOne = (_) async => bgg;
      await pumpForm(tester, editingId: 'dg_1');

      expect(readOnly(tester, DataGatewayForm.addressFieldKey), isTrue);
      expect(find.byKey(DataGatewayForm.submitKey), findsNothing);
      expect(find.byKey(DataGatewayForm.refusedKey), findsNothing);
      expect(find.text("Your role can't change data gateways."), findsNothing);

      access.current = FakeCallerAccessRepository.dataGateway(
        create: AccessExtent.all,
        read: AccessExtent.all,
      );
      await tester.pumpAndSettle();

      expect(find.byKey(DataGatewayForm.submitKey), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(DataGatewayForm.refusedKey),
          matching: find.text("Your role can't change data gateways."),
        ),
        findsOneWidget,
      );
    });

    testWidgets('without a session to ask, an edit says nothing about the '
        'role', (tester) async {
      remote.onFetchOne = (_) async => bgg;
      await tester.pumpWidget(
        MaterialApp(
          theme: BgeTheme.light(),
          localizationsDelegates:
              DataGatewayLocalizations.localizationsDelegates,
          supportedLocales: DataGatewayLocalizations.supportedLocales,
          home: DataGatewayFormScreen(
            remote: remote,
            session: lease,
            editingId: 'dg_1',
            onDone: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('bgg.internal'), findsOneWidget);
      expect(find.byKey(DataGatewayForm.submitKey), findsNothing);
      expect(find.byKey(DataGatewayForm.refusedKey), findsNothing);
    });

    testWidgets('an add without create shows access-denied', (tester) async {
      access.current = FakeCallerAccessRepository.dataGateway(
        read: AccessExtent.all,
        update: AccessExtent.all,
      );

      await pumpForm(tester);

      expect(
        find.text("You don't have access to data gateways"),
        findsOneWidget,
      );
      expect(find.byType(TextField), findsNothing);
    });

    testWidgets('an edit without update shows the fields read-only and says '
        'why instead of the save', (tester) async {
      access.current = FakeCallerAccessRepository.dataGateway(
        create: AccessExtent.all,
        read: AccessExtent.all,
      );
      remote.onFetchOne = (_) async => bgg;

      await pumpForm(tester, editingId: 'dg_1');

      expect(find.text('bgg.internal'), findsOneWidget);
      expect(readOnly(tester, DataGatewayForm.addressFieldKey), isTrue);
      expect(find.byKey(DataGatewayForm.submitKey), findsNothing);
      expect(find.byKey(DataGatewayForm.refusedKey), findsOneWidget);
    });

    testWidgets('a refused save says why and asks access again, and the save '
        'goes once access says no', (tester) async {
      remote
        ..onFetchOne = ((_) async => bgg)
        ..onUpdate = (_, _) async => throw forbidden();
      await pumpForm(tester, editingId: 'dg_1');

      await enter(tester, DataGatewayForm.portFieldKey, '50060');
      await submit(tester);

      expect(
        find.descendant(
          of: find.byKey(DataGatewayFormScreen.errorBannerKey),
          matching: find.text("Your role can't change data gateways."),
        ),
        findsOneWidget,
      );
      expect(access.refreshCount, 1);
      expect(doneCount, 0);
      // Access has not said no yet.
      expect(find.byKey(DataGatewayForm.submitKey), findsOneWidget);

      access.current = FakeCallerAccessRepository.dataGateway(
        read: AccessExtent.all,
      );
      await tester.pumpAndSettle();

      expect(find.byKey(DataGatewayForm.submitKey), findsNothing);
      expect(find.byKey(DataGatewayFormScreen.errorBannerKey), findsNothing);
      expect(
        find.text("Your role can't change data gateways."),
        findsOneWidget,
      );
      // What the user typed stays.
      expect(find.text('50060'), findsOneWidget);
    });
  });

  group('keeping keyboard focus when access takes a control away (#456)', () {
    /// Puts keyboard focus on the button [button] finds, as a click or a Tab
    /// would: on its own node, with nothing before it in the page's history
    /// to fall back to.
    Future<void> focusButton(WidgetTester tester, Finder button) async {
      await tester.ensureVisible(button);
      Focus.of(
        tester.element(
          find.descendant(of: button, matching: find.byType(Text)).first,
        ),
      ).requestFocus();
      await tester.pump();
    }

    /// The node of the field [key] finds.
    FocusNode fieldNode(WidgetTester tester, Key key) => tester
        .widget<EditableText>(
          find.descendant(
            of: find.byKey(key),
            matching: find.byType(EditableText),
          ),
        )
        .focusNode;

    /// The node of the [Focus] nearest above the text [label]: the heading,
    /// or a button by its label.
    FocusNode nodeAbove(WidgetTester tester, String label) =>
        Focus.of(tester.element(find.text(label)), createDependency: false);

    /// Expects keyboard focus on [node], not on the page's scope, which is
    /// above every control and where focus falls when the one that had it
    /// goes.
    void expectFocusOn(FocusNode node) {
      final focused = FocusManager.instance.primaryFocus;
      expect(focused, isNot(isA<FocusScopeNode>()));
      expect(focused, same(node));
    }

    final mayOnlyRead = FakeCallerAccessRepository.dataGateway(
      read: AccessExtent.all,
    );

    testWidgets('the save with focus hands it to the last field when update '
        'falls', (tester) async {
      remote.onFetchOne = (_) async => bgg;
      await pumpForm(tester, editingId: 'dg_1');
      await focusButton(tester, find.byKey(DataGatewayForm.submitKey));
      expectFocusOn(nodeAbove(tester, 'Save'));

      access.current = mayOnlyRead;
      await tester.pumpAndSettle();

      expect(find.byKey(DataGatewayForm.submitKey), findsNothing);
      expectFocusOn(fieldNode(tester, DataGatewayForm.descriptionFieldKey));
    });

    testWidgets('a field with focus keeps it as the fields turn read-only', (
      tester,
    ) async {
      remote.onFetchOne = (_) async => bgg;
      await pumpForm(tester, editingId: 'dg_1');
      final name = fieldNode(tester, DataGatewayForm.nameFieldKey)
        ..requestFocus();
      await tester.pump();

      access.current = mayOnlyRead;
      await tester.pumpAndSettle();

      expectFocusOn(name);
    });

    testWidgets('a field with focus keeps it when access answers without the '
        'save, which only adds the reason', (tester) async {
      access.current = const CallerAccess.unknown();
      remote.onFetchOne = (_) async => bgg;
      await pumpForm(tester, editingId: 'dg_1');
      final port = fieldNode(tester, DataGatewayForm.portFieldKey)
        ..requestFocus();
      await tester.pump();

      access.current = mayOnlyRead;
      await tester.pumpAndSettle();

      expect(find.byKey(DataGatewayForm.refusedKey), findsOneWidget);
      expectFocusOn(port);
    });

    testWidgets('the reason that arrives with access does not scroll the '
        'page, so a focused field stays in view', (tester) async {
      // A phone at 200% text, where the reason sits far below the fold.
      tester.view
        ..physicalSize = const Size(320, 480)
        ..devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      access.current = const CallerAccess.unknown();
      remote.onFetchOne = (_) async => bgg;
      await tester.pumpWidget(
        MaterialApp(
          theme: BgeTheme.light(),
          localizationsDelegates:
              DataGatewayLocalizations.localizationsDelegates,
          supportedLocales: DataGatewayLocalizations.supportedLocales,
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: DataGatewayFormScreen(
            remote: remote,
            session: lease,
            access: access,
            editingId: 'dg_1',
            onDone: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      final name = fieldNode(tester, DataGatewayForm.nameFieldKey)
        ..requestFocus();
      await tester.pump();
      final page = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      expect(page.pixels, 0);

      access.current = mayOnlyRead;
      await tester.pumpAndSettle();

      expect(find.byKey(DataGatewayForm.refusedKey), findsOneWidget);
      expect(page.pixels, 0);
      expectFocusOn(name);
    });

    testWidgets('an add whose field has focus hands it to the heading when '
        'create falls and the form closes', (tester) async {
      await pumpForm(tester);
      fieldNode(tester, DataGatewayForm.nameFieldKey).requestFocus();
      await tester.pump();

      access.current = mayOnlyRead;
      await tester.pumpAndSettle();

      expect(
        find.text("You don't have access to data gateways"),
        findsOneWidget,
      );
      expectFocusOn(nodeAbove(tester, 'Add data gateway'));
    });

    testWidgets('an add whose field has focus keeps it when create falls and '
        'comes back before the next frame', (tester) async {
      final mayDoAnything = access.current;
      await pumpForm(tester);
      final name = fieldNode(tester, DataGatewayForm.nameFieldKey)
        ..requestFocus();
      await tester.pump();

      // Each answer reaches the form, but no frame is drawn between them.
      access.current = mayOnlyRead;
      await tester.binding.delayed(Duration.zero);
      access.current = mayDoAnything;
      await tester.binding.delayed(Duration.zero);
      await tester.pumpAndSettle();

      expect(find.byKey(DataGatewayForm.nameFieldKey), findsOneWidget);
      expectFocusOn(name);
    });

    testWidgets('an add whose save has focus hands it to the heading when '
        'create falls and the form closes', (tester) async {
      await pumpForm(tester);
      await focusButton(tester, find.byKey(DataGatewayForm.submitKey));

      access.current = mayOnlyRead;
      await tester.pumpAndSettle();

      expectFocusOn(nodeAbove(tester, 'Add data gateway'));
    });

    testWidgets('the heading is not a Tab stop', (tester) async {
      await pumpForm(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();

      expectFocusOn(fieldNode(tester, DataGatewayForm.nameFieldKey));
    });
  });

  group('offline (#49)', () {
    late ValueNotifier<bool> offline;

    setUp(() => offline = ValueNotifier(true));
    tearDown(() => offline.dispose());

    Matcher gatedSubmit(String label) => matchesSemantics(
      label: label,
      hint: onlineOnlyCopy,
      isButton: true,
      hasEnabledState: true,
    );

    testWidgets('Add is disabled and says why, and offline leaves the form '
        'untouched', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpForm(tester, offline: offline);

      final create = find.byKey(DataGatewayForm.submitKey);
      await tester.ensureVisible(create);
      await tester.pump();
      expect(tester.widget<BgeSubmitButton>(create).onPressed, isNull);
      expect(tester.getSemantics(create), gatedSubmit('Add'));
      expect(find.text(onlineOnlyCopy), findsOneWidget);

      // Neither a press nor Enter in the last field submits, or marks the
      // blank form touched, which would show its errors.
      await tester.tap(create, warnIfMissed: false);
      await tester.pump();
      await tester.tap(find.byKey(DataGatewayForm.descriptionFieldKey));
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(find.text('Enter a name.'), findsNothing);
      expect(remote.calls, isEmpty);

      offline.value = false;
      await tester.pump();

      expect(tester.widget<BgeSubmitButton>(create).onPressed, isNotNull);
      expect(find.text(onlineOnlyCopy), findsNothing);
      expect(find.text('Enter a name.'), findsNothing);
      await submit(tester);
      expect(find.text('Enter a name.'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('Save is disabled and says why, and sends nothing', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      DataGatewayChanges? sent;
      remote
        ..onFetchOne = ((_) async => bgg)
        ..onUpdate = (_, changes) async {
          sent = changes;
          return changed(bgg.copyWith(connectionPort: 50060));
        };
      await pumpForm(tester, editingId: 'dg_1', offline: offline);
      await enter(tester, DataGatewayForm.portFieldKey, '50060');

      final save = find.byKey(DataGatewayForm.submitKey);
      await tester.ensureVisible(save);
      await tester.pump();
      expect(tester.widget<BgeSubmitButton>(save).onPressed, isNull);
      expect(tester.getSemantics(save), gatedSubmit('Save'));

      await tester.tap(save, warnIfMissed: false);
      await tester.pump();
      expect(sent, isNull);

      offline.value = false;
      await tester.pump();
      await submit(tester);

      expect(sent, const DataGatewayChanges(connectionPort: 50060));
      handle.dispose();
    });
  });

  group('accessibility audit', () {
    /// The form as the shell composes it: an edit of [editingId], or an add
    /// without one. [seed] scripts the fakes before the form opens.
    /// [offline] holds the connection down through a notifier of the cell's
    /// own, which goes with it.
    Future<void> Function(WidgetTester, ThemeData) form({
      String? editingId,
      void Function()? seed,
      bool offline = false,
      bool settle = true,
    }) => (tester, theme) {
      seed?.call();
      final notifier = offline ? ValueNotifier(true) : null;
      if (notifier != null) addTearDown(notifier.dispose);
      return pumpForm(
        tester,
        editingId: editingId,
        offline: notifier,
        theme: theme,
        settle: settle,
      );
    };

    final add = form();

    /// An edit of BGG whose read [answer] gives.
    Future<void> Function(WidgetTester, ThemeData) edit(
      Future<DataGateway> Function(String id) answer, {
      bool settle = true,
    }) => form(
      editingId: 'dg_1',
      seed: () => remote.onFetchOne = answer,
      settle: settle,
    );

    /// May read DataGateways and add one, but not change one: an edit opens
    /// read-only.
    void mayNotUpdate() {
      access.current = FakeCallerAccessRepository.dataGateway(
        create: AccessExtent.all,
        read: AccessExtent.all,
      );
      remote.onFetchOne = (_) async => bgg;
    }

    void nameInUse() =>
        remote.onCreate = (_) async =>
            throw const DataGatewayNameInUseException('taken', statusCode: 409);

    /// Submits blank name and address fields and a port out of range.
    Future<void> submitInvalid(WidgetTester tester) async {
      await enter(tester, DataGatewayForm.portFieldKey, '70000');
      await submit(tester);
      expect(find.text('Enter a name.'), findsOneWidget);
      expect(find.text('Enter a connection address.'), findsOneWidget);
      expect(find.text('Enter a port from 1 to 65535.'), findsOneWidget);
      expect(remote.calls, isEmpty);
    }

    Future<void> submitTaken(WidgetTester tester) async {
      await fillValid(tester);
      await submit(tester);
      expect(
        find.descendant(
          of: find.byKey(DataGatewayFormScreen.errorBannerKey),
          matching: find.text('Another data gateway already uses this name.'),
        ),
        findsOneWidget,
      );
    }

    /// Makes the add one that never answers.
    void holdAdd() =>
        remote.onCreate = (_) => Completer<DataGatewayChangeResult>().future;

    /// Fills the form and submits it. Pumps rather than settles: the button's
    /// spinner never stops.
    Future<void> startAdd(WidgetTester tester) async {
      await fillValid(tester);
      await tester.ensureVisible(find.byKey(DataGatewayForm.submitKey));
      await tester.tap(find.byKey(DataGatewayForm.submitKey));
      await tester.pump();
      expect(
        tester
            .widget<BgeSubmitButton>(find.byKey(DataGatewayForm.submitKey))
            .submitting,
        isTrue,
      );
    }

    void expectReadOnly() {
      expect(find.text('bgg.internal'), findsOneWidget);
      expect(find.byKey(DataGatewayForm.submitKey), findsNothing);
      expect(find.byKey(DataGatewayForm.refusedKey), findsOneWidget);
    }

    /// The Add, disabled and saying why.
    void expectOffline(WidgetTester tester) {
      expect(
        tester
            .widget<BgeSubmitButton>(find.byKey(DataGatewayForm.submitKey))
            .onPressed,
        isNull,
      );
      expect(find.text(onlineOnlyCopy), findsOneWidget);
    }

    auditScreen(
      'loading',
      pump: edit((_) => Completer<DataGateway>().future, settle: false),
      settle: false,
      arrange: (tester) async {
        await tester.pump();
        expect(find.byKey(DataGatewayFormScreen.loadingKey), findsOneWidget);
      },
    );

    auditScreen(
      'access denied',
      pump: edit((_) async => throw forbidden()),
      arrange: (tester) async {
        expect(
          find.text("You don't have access to data gateways"),
          findsOneWidget,
        );
      },
    );

    auditScreen(
      'missing',
      pump: edit(
        (_) async =>
            throw const DataGatewayNotFoundException('gone', statusCode: 404),
      ),
      arrange: (tester) async {
        expect(find.text("This data gateway doesn't exist"), findsOneWidget);
      },
    );

    auditScreen(
      'load failed, with retry',
      pump: edit((_) async => throw unreachable()),
      arrange: (tester) async {
        expect(find.text("We couldn't load this data gateway"), findsOneWidget);
        expect(find.text('Try again'), findsOneWidget);
      },
    );

    auditScreen(
      'add, blank',
      pump: add,
      arrange: (tester) async {
        expect(find.byKey(DataGatewayForm.nameFieldKey), findsOneWidget);
        expect(find.byKey(DataGatewayForm.submitKey), findsOneWidget);
      },
    );

    auditScreen(
      'add, blank, scrolled to the end',
      pump: add,
      arrange: (tester) async {
        await scrollPageToEnd(tester);
        expect(find.byKey(DataGatewayForm.submitKey), findsOneWidget);
      },
    );

    auditScreen(
      'editing',
      pump: edit((_) async => bgg),
      arrange: (tester) async {
        expect(find.text('bgg.internal'), findsOneWidget);
        expect(find.byKey(DataGatewayForm.submitKey), findsOneWidget);
      },
    );

    auditScreen(
      'editing, scrolled to the end',
      pump: edit((_) async => bgg),
      arrange: (tester) async {
        await scrollPageToEnd(tester);
        expect(find.text('The BGG bridge'), findsOneWidget);
        expect(find.byKey(DataGatewayForm.submitKey), findsOneWidget);
      },
    );

    auditScreen(
      'invalid',
      pump: add,
      arrange: (tester) async {
        await submitInvalid(tester);
        await scrollPageToTop(tester);
      },
    );

    auditScreen(
      'invalid, scrolled to the end',
      pump: add,
      arrange: (tester) async {
        await submitInvalid(tester);
        await scrollPageToEnd(tester);
      },
    );

    auditScreen(
      'rejected submit',
      pump: form(seed: nameInUse),
      arrange: (tester) async {
        await submitTaken(tester);
        await scrollPageToTop(tester);
      },
    );

    auditScreen(
      'rejected submit, scrolled to the end',
      pump: form(seed: nameInUse),
      arrange: (tester) async {
        await submitTaken(tester);
        await scrollPageToEnd(tester);
      },
    );

    // The add never answers, so the button keeps spinning. The failing node
    // is the button, disabled while the add is in flight and dimmed by
    // design: WCAG 1.4.3 exempts inactive controls. Online, its
    // `BgeOnlineOnly` merge has no disabled state of its own, which is what
    // the guideline reads, so it measures the label (#50).
    auditScreen(
      'submitting',
      pump: form(seed: holdAdd),
      settle: false,
      arrange: startAdd,
      textContrast: false,
    );

    auditScreen(
      'read-only, with its reason',
      pump: form(editingId: 'dg_1', seed: mayNotUpdate),
      arrange: (tester) async => expectReadOnly(),
    );

    auditScreen(
      'read-only, with its reason, scrolled to the end',
      pump: form(editingId: 'dg_1', seed: mayNotUpdate),
      arrange: (tester) async {
        await scrollPageToEnd(tester);
        expectReadOnly();
      },
    );

    // At 320dp × 2.0 the rejected and read-only forms run 900 and 842dp past
    // a 744dp view, so the top and the end leave a band of each on screen in
    // neither. The submitting one is otherwise audited only where its tap
    // scrolled it. These audit them in a view tall enough to hold the form
    // whole (#50).
    auditScreen(
      'rejected submit, whole page',
      pump: form(seed: nameInUse),
      arrange: (tester) async {
        await useWholePage(tester);
        await submitTaken(tester);
        expectWholePage(tester);
      },
    );

    auditScreen(
      'submitting, whole page',
      pump: form(seed: holdAdd),
      settle: false,
      arrange: (tester) async {
        await useWholePage(tester);
        await startAdd(tester);
        expectWholePage(tester);
      },
      // The same disabled button as in 'submitting'.
      textContrast: false,
    );

    auditScreen(
      'read-only, with its reason, whole page',
      pump: form(editingId: 'dg_1', seed: mayNotUpdate),
      arrange: (tester) async {
        await useWholePage(tester);
        expectReadOnly();
        expectWholePage(tester);
      },
    );

    // Offline the disabled Add's `BgeOnlineOnly` node says it is disabled, so
    // the guideline leaves its dimmed label alone, as WCAG 1.4.3 does.
    auditScreen(
      'offline',
      pump: form(offline: true),
      arrange: (tester) async => expectOffline(tester),
    );

    auditScreen(
      'offline, scrolled to the end',
      pump: form(offline: true),
      arrange: (tester) async {
        await scrollPageToEnd(tester);
        expectOffline(tester);
      },
    );
  });
}
