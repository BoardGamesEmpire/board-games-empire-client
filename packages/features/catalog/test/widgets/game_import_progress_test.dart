import 'dart:async';

import 'package:bge_test_support/widgets.dart';
import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_catalog/game_catalog.dart';
import 'package:models/domain.dart';

import '../support/catalog_app.dart';

class _MockImportBloc extends MockBloc<GameImportEvent, GameImportState>
    implements GameImportBloc {
  /// What the widget asked of the bloc, in order.
  final sent = <GameImportEvent>[];

  @override
  void add(GameImportEvent event) => sent.add(event);
}

const _requested = ImportJob(
  jobId: 'j1',
  status: ImportJobStatus.running,
  origin: ImportJobOrigin.requested,
  externalId: '1',
);

ImportJob _job(
  String id, {
  ImportJobStatus status = ImportJobStatus.running,
  ImportJobOrigin origin = ImportJobOrigin.chosenExpansion,
  String? title,
  String? parent = 'j1',
  ImportErrorCode? errorCode,
  String? gameId,
}) => ImportJob(
  jobId: id,
  status: status,
  origin: origin,
  externalId: 'ext_$id',
  gameTitle: title,
  parentJobId: parent,
  errorCode: errorCode,
  gameId: gameId,
);

void main() {
  late _MockImportBloc bloc;
  late List<String> imported;
  late StreamController<GameImportState> states;

  setUp(() {
    bloc = _MockImportBloc();
    imported = [];
    states = StreamController<GameImportState>.broadcast();
  });

  tearDown(() => states.close());

  /// Holds [bloc] at [initial], and lets [states] move it.
  void startAt(GameImportState initial) =>
      whenListen(bloc, states.stream, initialState: initial);

  Future<void> move(WidgetTester tester, GameImportState next) async {
    states.add(next);
    await tester.pump();
  }

  Widget host({
    bool autofocus = false,
    Map<String, String> titles = const {},
  }) => BlocProvider<GameImportBloc>.value(
    value: bloc,
    child: Scaffold(
      body: SingleChildScrollView(
        child: GameImportProgress(
          requestedTitle: 'Spirit Island: Jagged Earth',
          titlesByExternalId: titles,
          autofocus: autofocus,
          onImported: (_, gameId) => imported.add(gameId),
        ),
      ),
    ),
  );

  Widget app({ValueNotifier<bool>? offline, Map<String, String>? titles}) =>
      catalogApp(host(titles: titles ?? const {}), offline: offline);

  final status = find.byKey(GameImportProgress.statusKey);

  testWidgets('the status says each stage in one live region', (tester) async {
    final handle = tester.ensureSemantics();
    startAt(const GameImportStarting());
    await tester.pumpWidget(app());
    expect(find.text('Sending the import to the server…'), findsOneWidget);
    final id = tester.getSemantics(status).id;
    expect(tester.getSemantics(status), isSemantics(isLiveRegion: true));

    await move(tester, const GameImportInProgress(running: false));
    expect(
      find.text('Waiting for the server to start the import…'),
      findsOneWidget,
    );
    expect(tester.getSemantics(status).id, id);

    await move(tester, const GameImportInProgress(running: true));
    expect(find.text('Importing from the data source…'), findsOneWidget);
    expect(tester.getSemantics(status).id, id);
    expect(tester.getSemantics(status), isSemantics(isLiveRegion: true));
    handle.dispose();
  });

  testWidgets('a single-game import shows no job rows', (tester) async {
    startAt(const GameImportInProgress(running: true, jobs: [_requested]));
    await tester.pumpWidget(app());

    expect(find.byKey(GameImportProgress.jobKey('j1')), findsNothing);
    expect(find.text('Importing 1 game'), findsNothing);
  });

  testWidgets('an added base game says why it is there', (tester) async {
    final handle = tester.ensureSemantics();
    final base = _job('jb', origin: ImportJobOrigin.addedBaseGame);
    startAt(GameImportInProgress(running: true, jobs: [_requested, base]));
    await tester.pumpWidget(app());

    expect(
      find.text(
        'Also importing the base game Spirit Island: Jagged Earth needs',
      ),
      findsOneWidget,
    );

    await move(
      tester,
      GameImportInProgress(
        running: true,
        jobs: [
          _requested,
          _job(
            'jb',
            origin: ImportJobOrigin.addedBaseGame,
            status: ImportJobStatus.completed,
            title: 'Spirit Island',
          ),
        ],
      ),
    );
    expect(
      find.text(
        'Also importing Spirit Island, the base game Spirit Island: Jagged '
        'Earth needs',
      ),
      findsOneWidget,
    );
    handle.dispose();
  });

  testWidgets('a job row is read as one node', (tester) async {
    final handle = tester.ensureSemantics();
    startAt(
      GameImportInProgress(
        running: true,
        jobs: [
          _requested,
          _job(
            'j2',
            status: ImportJobStatus.completed,
            title: 'Jagged Earth',
            gameId: 'g2',
          ),
        ],
      ),
    );
    await tester.pumpWidget(app());

    expect(
      tester.getSemantics(find.byKey(GameImportProgress.jobKey('j2'))),
      isSemantics(label: 'Jagged Earth\nImported'),
    );
    expect(find.bySemanticsLabel('Importing 2 games'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('rows take their title from the lookup, and say their state', (
    tester,
  ) async {
    startAt(
      GameImportInProgress(
        running: true,
        jobs: [
          _requested,
          _job('j2', status: ImportJobStatus.pending),
          _job('j3', status: ImportJobStatus.unknown),
          _job('j4', status: ImportJobStatus.failed),
          _job('j5', status: ImportJobStatus.cancelled),
          _job(
            'j6',
            status: ImportJobStatus.cancelled,
            errorCode: ImportErrorCode.baseImportFailed,
          ),
          _job('j7'),
        ],
      ),
    );
    await tester.pumpWidget(app(titles: {'ext_j2': 'Branch & Claw'}));

    String line(String id, String text) {
      expect(
        find.descendant(
          of: find.byKey(GameImportProgress.jobKey(id)),
          matching: find.text(text),
        ),
        findsOneWidget,
        reason: '$id: $text',
      );
      return text;
    }

    line('j1', 'Spirit Island: Jagged Earth');
    line('j1', 'Importing');
    line('j2', 'Branch & Claw');
    line('j2', 'Waiting');
    line('j3', 'Importing');
    line('j4', 'Another game');
    line('j4', 'Failed');
    line('j5', 'Cancelled');
    line('j6', "Skipped: the game it goes with wasn't imported");
    line('j7', 'Importing');
  });

  testWidgets('completion calls onImported once', (tester) async {
    startAt(const GameImportInProgress(running: true));
    await tester.pumpWidget(app());

    await move(
      tester,
      const GameImportCompleted(gameId: 'g1', jobs: [_requested]),
    );
    await move(
      tester,
      const GameImportCompleted(gameId: 'g1', jobs: [_requested]),
    );

    expect(imported, ['g1']);
  });

  testWidgets('partly completed says what failed and opens on press', (
    tester,
  ) async {
    startAt(const GameImportInProgress(running: true));
    await tester.pumpWidget(app());

    await move(
      tester,
      GameImportPartlyCompleted(
        gameId: 'g1',
        jobs: [
          _requested.copyWith(
            status: ImportJobStatus.completed,
            gameTitle: 'Spirit Island',
            gameId: 'g1',
          ),
          _job('j2', status: ImportJobStatus.failed),
          _job('j3', status: ImportJobStatus.completed),
        ],
      ),
    );

    expect(
      find.text("Spirit Island was imported, but 1 other game wasn't."),
      findsOneWidget,
    );
    expect(imported, isEmpty);
    await tester.tap(find.byKey(GameImportProgress.openKey));
    await tester.pump();
    expect(imported, ['g1']);
    expect(find.text('Open Spirit Island'), findsOneWidget);
  });

  testWidgets('check again asks the bloc to poll, offline too', (tester) async {
    final offline = ValueNotifier(true);
    addTearDown(offline.dispose);
    startAt(const GameImportStillRunning(jobs: [_requested]));
    await tester.pumpWidget(app(offline: offline));

    final again = find.byKey(GameImportProgress.checkAgainKey);
    expect(tester.widget<TextButton>(again).onPressed, isNotNull);
    await tester.tap(again);
    expect(bloc.sent, [const GameImportCheckAgainRequested()]);
  });

  testWidgets('try again is disabled offline and kept in the tree', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final offline = ValueNotifier(true);
    addTearDown(offline.dispose);
    startAt(const GameImportFailed(failure: GameImportFailure.server));
    await tester.pumpWidget(app(offline: offline));

    final tryAgain = find.byKey(GameImportProgress.tryAgainKey);
    expect(tester.widget<TextButton>(tryAgain).onPressed, isNull);
    expect(
      tester.getSemantics(tryAgain),
      matchesSemantics(
        label: 'Try again',
        hint: onlineOnlyCopy,
        isButton: true,
        hasEnabledState: true,
      ),
    );
    final node = tester.getSemantics(status).id;

    offline.value = false;
    await tester.pump();
    expect(tester.getSemantics(status).id, node);
    expect(tester.widget<TextButton>(tryAgain).onPressed, isNotNull);
    await tester.tap(tryAgain);
    expect(bloc.sent, [const GameImportRequested()]);
    handle.dispose();
  });

  testWidgets('a failure that cannot change offers no try again', (
    tester,
  ) async {
    startAt(const GameImportFailed(failure: GameImportFailure.forbidden));
    await tester.pumpWidget(app());

    expect(find.byKey(GameImportProgress.tryAgainKey), findsNothing);
    expect(
      find.text("You don't have permission to import games on this server."),
      findsOneWidget,
    );
  });

  testWidgets('autofocus focuses the status', (tester) async {
    startAt(const GameImportStarting());
    await tester.pumpWidget(catalogApp(host(autofocus: true)));
    await tester.pump();

    final focus = Focus.of(tester.element(status));
    expect(focus.hasPrimaryFocus, isTrue);
    expect(FocusManager.instance.primaryFocus, focus);
  });

  group('accessibility audit', () {
    auditScreen(
      'partly completed, three jobs',
      build: (theme) {
        whenListen(
          bloc,
          const Stream<GameImportState>.empty(),
          initialState: GameImportPartlyCompleted(
            gameId: 'g1',
            jobs: [
              _requested.copyWith(
                status: ImportJobStatus.completed,
                gameTitle: 'Spirit Island',
                gameId: 'g1',
              ),
              _job('j2', status: ImportJobStatus.failed),
              _job(
                'j3',
                status: ImportJobStatus.cancelled,
                errorCode: ImportErrorCode.baseImportFailed,
              ),
            ],
          ),
        );
        return catalogApp(host(), theme: theme);
      },
    );
  });
}
