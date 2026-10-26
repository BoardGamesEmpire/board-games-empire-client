import 'dart:async';
import 'dart:collection';

import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_catalog/game_catalog.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/catalog_app.dart';
import '../support/fake_games_remote.dart';

/// The batch every scripted start queues.
const _batchId = '0b7c2f9e-3a41-4c8e-9d2a-5f6b7c8d9e0f';

const _seafarers = GameSearchHit(
  externalId: '926',
  title: 'Catan: Seafarers',
  contentType: ContentType.expansion,
);

/// A poll's answer whose base game's job is [status].
ImportBatch _batch(
  ImportJobStatus status, {
  String? gameId,
  ImportErrorCode? errorCode,
}) => ImportBatch(
  batchId: _batchId,
  correlationId: 'corr',
  status: ImportBatchStatus.running,
  jobs: [
    ImportJob(
      jobId: 'job_base',
      status: status,
      isExpansion: false,
      externalId: '926',
      gameId: gameId,
      errorCode: errorCode,
    ),
  ],
);

void main() {
  late FakeGamesRemote remote;

  /// What each dialog completed with, in order. Empty while one is open.
  late List<String?> results;

  setUp(() {
    remote = FakeGamesRemote();
    results = [];
  });

  /// Every start is queued, as batch [_batchId].
  void queues() => remote.onStartImport = (_, _, correlationId) async =>
      GameImportReceipt(
        batchId: _batchId,
        baseJobId: 'job_base',
        correlationId: correlationId,
      );

  /// Answers each poll with the next of [answers]: a batch to return, or
  /// anything else to throw.
  void polls(List<Object> answers) {
    final queue = Queue.of(answers);
    remote.onFetchImport = (_) async => switch (queue.removeFirst()) {
      final ImportBatch batch => batch,
      final failure => throw failure,
    };
  }

  /// How many calls the remote has had to [method].
  int sent(String method) =>
      remote.calls.where((call) => call.startsWith('$method(')).length;

  /// A page with a button that opens the dialog for [hit], keeping what it
  /// completes with.
  Widget host({GameSearchHit hit = _seafarers}) => Builder(
    builder: (context) => Scaffold(
      body: Center(
        child: TextButton(
          onPressed: () async => results.add(
            await GameImportDialog.show(
              context,
              remote: remote,
              gatewayId: 'dg_bgg',
              hit: hit,
            ),
          ),
          child: const Text('Import'),
        ),
      ),
    ),
  );

  /// Opens the dialog, and lets the start answer and the dialog finish
  /// fading in: until then it carries no semantics.
  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.text('Import'));
    await tester.pump(); // The dialog's first frame, which starts the import.
    await tester.pump(const Duration(milliseconds: 150));
  }

  /// Waits out one poll's interval, and shows its answer.
  Future<void> poll(WidgetTester tester) =>
      tester.pump(const Duration(seconds: 2));

  testWidgets("shows progress, then closes with the imported game's id", (
    tester,
  ) async {
    queues();
    polls([
      _batch(ImportJobStatus.running),
      _batch(ImportJobStatus.completed, gameId: 'g_seafarers'),
    ]);
    await tester.pumpWidget(catalogApp(host()));

    await open(tester);
    expect(find.text('Catan: Seafarers'), findsOneWidget);
    expect(find.byKey(GameImportDialog.progressKey), findsOneWidget);
    expect(
      find.text('Waiting for the server to start the import…'),
      findsOneWidget,
    );

    await poll(tester);
    expect(find.text('Importing from the data source…'), findsOneWidget);

    await poll(tester);
    await tester.pumpAndSettle();
    expect(find.byType(GameImportDialog), findsNothing);
    expect(results, ['g_seafarers']);
  });

  testWidgets("sets the spinner a control's inner gap from its line", (
    tester,
  ) async {
    queues();
    polls([_batch(ImportJobStatus.running)]);
    await tester.pumpWidget(catalogApp(host()));
    await open(tester);

    // The style guide's intra-control step: spinner to label is spaceSm.
    final tokens = BgeTokens.of(tester.element(find.byType(AlertDialog)));
    final spinner = tester.getRect(
      find.descendant(
        of: find.byKey(GameImportDialog.progressKey),
        matching: find.byType(CircularProgressIndicator),
      ),
    );
    final line = tester.getRect(
      find.text('Waiting for the server to start the import…'),
    );
    expect(line.left - spinner.right, tokens.spaceSm);

    await tester.tap(find.byKey(GameImportDialog.closeKey));
    await poll(tester);
  });

  testWidgets('announces each change in where the import stands', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    queues();
    polls([_batch(ImportJobStatus.failed, errorCode: ImportErrorCode.unknown)]);
    await tester.pumpWidget(catalogApp(host()));

    await open(tester);
    expect(
      tester.getSemantics(find.byKey(GameImportDialog.progressKey)),
      isSemantics(
        label: 'Waiting for the server to start the import…',
        isLiveRegion: true,
      ),
    );

    await poll(tester);
    expect(
      tester.getSemantics(find.byKey(GameImportDialog.failedKey)),
      isSemantics(
        label: "The server couldn't import this game.",
        isLiveRegion: true,
      ),
    );
    handle.dispose();
  });

  testWidgets('a failure shows its copy and a try again', (tester) async {
    queues();
    polls([
      _batch(ImportJobStatus.failed, errorCode: ImportErrorCode.gatewayError),
    ]);
    await tester.pumpWidget(catalogApp(host()));
    await open(tester);
    await poll(tester);

    expect(find.byKey(GameImportDialog.failedKey), findsOneWidget);
    expect(
      find.text("The data source didn't answer. Try again later."),
      findsOneWidget,
    );

    await tester.tap(find.byKey(GameImportDialog.tryAgainKey));
    await tester.pump();
    expect(sent('startImport'), 2);

    // Leave, so the new attempt's poll does not outlive the test.
    await tester.tap(find.byKey(GameImportDialog.closeKey));
    await poll(tester);
  });

  testWidgets('a refusal offers no try again', (tester) async {
    remote.onStartImport = (_, _, _) async =>
        throw const GamesForbiddenException('403');
    await tester.pumpWidget(catalogApp(host()));

    await open(tester);

    expect(find.byKey(GameImportDialog.failedKey), findsOneWidget);
    expect(
      find.text("You don't have permission to import games on this server."),
      findsOneWidget,
    );
    expect(find.byKey(GameImportDialog.tryAgainKey), findsNothing);
    expect(find.byKey(GameImportDialog.closeKey), findsOneWidget);
  });

  testWidgets('a game the data source no longer has offers no try again', (
    tester,
  ) async {
    queues();
    polls([
      _batch(ImportJobStatus.failed, errorCode: ImportErrorCode.notFound),
    ]);
    await tester.pumpWidget(catalogApp(host()));

    await open(tester);
    await poll(tester);

    expect(
      find.text('The data source no longer has this game.'),
      findsOneWidget,
    );
    expect(find.byKey(GameImportDialog.tryAgainKey), findsNothing);
  });

  testWidgets('after the deadline it offers check again', (tester) async {
    queues();
    polls([
      for (var i = 0; i < 45; i++) _batch(ImportJobStatus.running),
      _batch(ImportJobStatus.completed, gameId: 'g_seafarers'),
    ]);
    await tester.pumpWidget(catalogApp(host()));
    await open(tester);

    for (var i = 0; i < 45; i++) {
      await poll(tester);
    }
    expect(find.byKey(GameImportDialog.stillRunningKey), findsOneWidget);
    expect(sent('fetchImport'), 45);

    await tester.tap(find.byKey(GameImportDialog.checkAgainKey));
    await tester.pump();
    await poll(tester);
    await tester.pumpAndSettle();

    expect(results, ['g_seafarers']);
    expect(sent('startImport'), 1);
  });

  testWidgets('completing beneath another page leaves that page in place', (
    tester,
  ) async {
    queues();
    polls([_batch(ImportJobStatus.completed, gameId: 'g_seafarers')]);
    await tester.pumpWidget(catalogApp(host()));
    await open(tester);

    unawaited(
      Navigator.of(tester.element(find.byType(GameImportDialog)))
          .push(MaterialPageRoute<void>(builder: (_) => const Text('Above'))),
    );
    // The dialog's spinner never settles: wait out the page's transition.
    await tester.pump(const Duration(milliseconds: 500));
    await poll(tester);
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Above'), findsOneWidget);
    expect(find.byType(GameImportDialog), findsNothing);
    expect(results, [null]);
  });

  testWidgets('closing returns nothing and stops polling', (tester) async {
    queues();
    polls([for (var i = 0; i < 10; i++) _batch(ImportJobStatus.running)]);
    await tester.pumpWidget(catalogApp(host()));
    await open(tester);
    await poll(tester);
    final polledBeforeClosing = sent('fetchImport');

    await tester.tap(find.byKey(GameImportDialog.closeKey));
    await tester.pump(const Duration(seconds: 10));

    expect(results, [null]);
    expect(sent('fetchImport'), polledBeforeClosing);
    await tester.pumpAndSettle();
    expect(find.byType(GameImportDialog), findsNothing);
  });

  testWidgets('lays out at 200% text on a narrow window', (tester) async {
    const title =
        'Catan: Seafarers of the Distant Isles, with Each Scenario and the '
        'Fishermen Pack';
    expect(title.length, 80);
    useViewSize(tester, const Size(320, 640));

    /// Where the import stands must start in view, not under the title.
    void expectInView(Key status) {
      final view = tester.getRect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(SingleChildScrollView),
        ),
      );
      final shown = tester.getRect(find.byKey(status));
      expect(shown.top, lessThan(view.bottom), reason: '$shown in $view');
    }

    // The first start goes unanswered. Trying again queues the import,
    // which then outlasts the deadline.
    var starts = 0;
    remote.onStartImport = (_, _, correlationId) async {
      if (starts++ == 0) throw unreachable();
      return GameImportReceipt(
        batchId: _batchId,
        baseJobId: 'job_base',
        correlationId: correlationId,
      );
    };
    polls([for (var i = 0; i < 45; i++) _batch(ImportJobStatus.running)]);
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(
          size: Size(320, 640),
          textScaler: TextScaler.linear(2),
        ),
        child: catalogApp(
          host(
            hit: const GameSearchHit(
              externalId: '926',
              title: title,
              contentType: ContentType.expansion,
            ),
          ),
        ),
      ),
    );

    await open(tester);
    expect(
      find.text(
        "Couldn't reach the server. Check your connection and try again.",
      ),
      findsOneWidget,
    );
    expectInView(GameImportDialog.failedKey);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(GameImportDialog.tryAgainKey));
    await tester.pump();
    await tester.pump();
    expectInView(GameImportDialog.progressKey);
    expect(tester.takeException(), isNull);

    for (var i = 0; i < 45; i++) {
      await poll(tester);
    }
    expectInView(GameImportDialog.stillRunningKey);
    expect(tester.takeException(), isNull);
  });
}
