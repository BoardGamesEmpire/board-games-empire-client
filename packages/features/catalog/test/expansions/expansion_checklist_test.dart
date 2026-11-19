import 'dart:async';

import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_catalog/src/expansions/expansion_checklist.dart';
import 'package:game_catalog/src/expansions/expansion_checklist_cubit.dart';
import 'package:game_catalog/src/search/data_gateway_search_grant.dart';
import 'package:game_catalog/src/widgets/catalog_slivers.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';

import '../support/catalog_app.dart';
import '../support/fake_games_remote.dart';

const _target = GameExpansionsTarget.dataGateway(
  gatewayId: 'bgg',
  externalId: 'base',
);

GameSearchResults _bgg(
  int count, {
  Set<String> unavailable = const {},
  Set<String> failed = const {},
  Set<String> rateLimited = const {},
}) => GameSearchResults(
  byDataGateway: {
    if (count > 0)
      'bgg': [
        for (var n = 0; n < count; n++)
          GameSearchHit(
            externalId: 'e$n',
            title: 'Expansion $n',
            contentType: ContentType.expansion,
            yearPublished: 2020 + n % 5,
          ),
      ],
  },
  unavailableDataGateways: unavailable,
  failedDataGateways: failed,
  rateLimitedDataGateways: rateLimited,
);

void main() {
  late FakeGamesRemote remote;

  setUp(() => remote = FakeGamesRemote());

  ExpansionChecklistCubit make({
    bool tickOnServer = false,
    DataGatewaySearchGrant? grant,
  }) => ExpansionChecklistCubit(
    remote: remote,
    target: _target,
    tickOnServer: tickOnServer,
    grant: grant,
  );

  /// The checklist in a scroll view, as the quick look hosts it.
  Widget harness(
    ExpansionChecklistCubit cubit, {
    Map<String, String> sourceNames = const {},
    ThemeData? theme,
  }) => catalogApp(
    theme: theme,
    Scaffold(
      body: SingleChildScrollView(
        child: BlocProvider.value(
          value: cubit,
          child: ExpansionChecklist(sourceNames: sourceNames),
        ),
      ),
    ),
  );

  CheckboxListTile tile(WidgetTester tester, Key key) =>
      tester.widget<CheckboxListTile>(find.byKey(key));

  testWidgets('shows loading, then the rows', (tester) async {
    final answer = Completer<GameSearchResults>();
    remote.onFetchExpansions = (_) => answer.future;
    final cubit = make();
    addTearDown(cubit.close);

    await tester.pumpWidget(harness(cubit));
    unawaited(cubit.load());
    await tester.pump();
    expect(find.byType(BgeLoadingState), findsOneWidget);
    // Headed as the quick look's own sections are.
    expect(
      find.widgetWithText(CatalogSectionHeading, 'Expansions'),
      findsOneWidget,
    );

    answer.complete(_bgg(2));
    await tester.pumpAndSettle();

    expect(find.byType(BgeLoadingState), findsNothing);
    expect(find.text('Expansion 0'), findsOneWidget);
    expect(find.text('Expansion 1'), findsOneWidget);
    expect(find.text('Select all'), findsOneWidget);
  });

  testWidgets('select all is mixed when some rows are ticked', (tester) async {
    remote.onFetchExpansions = (_) async => _bgg(2);
    final cubit = make();
    addTearDown(cubit.close);
    await tester.pumpWidget(harness(cubit));
    await cubit.load();
    await tester.pumpAndSettle();
    final all = ExpansionChecklist.selectAllKey('bgg');

    expect(tile(tester, all).value, isFalse);
    await tester.tap(find.byKey(ExpansionChecklist.rowKey('bgg', 'e0')));
    await tester.pumpAndSettle();
    expect(tile(tester, all).value, isNull);
    expect(tile(tester, all).tristate, isTrue);

    await tester.tap(find.byKey(all));
    await tester.pumpAndSettle();
    expect(tile(tester, all).value, isTrue);
    expect(cubit.tickedIn('bgg'), ['e0', 'e1']);
  });

  testWidgets('an unavailable DataGateway is named, not read as none', (
    tester,
  ) async {
    remote.onFetchExpansions = (_) async => _bgg(2, unavailable: {'igdb'});
    final cubit = make();
    addTearDown(cubit.close);
    await tester.pumpWidget(harness(cubit, sourceNames: {'igdb': 'IGDB'}));
    await cubit.load();
    await tester.pumpAndSettle();

    expect(
      find.text("IGDB didn't answer, so some expansions may be missing."),
      findsOneWidget,
    );
    expect(find.byType(BgeEmptyState), findsNothing);
    expect(find.text('Expansion 0'), findsOneWidget);
  });

  // The server names a source that couldn't say in one of three sets, and
  // each is read the same way.
  for (final (name, results) in [
    ('failed', ({int count = 0}) => _bgg(count, failed: {'igdb'})),
    ('rate limited', ({int count = 0}) => _bgg(count, rateLimited: {'igdb'})),
  ]) {
    testWidgets('a $name DataGateway is named beside the rows', (
      tester,
    ) async {
      remote.onFetchExpansions = (_) async => results(count: 2);
      final cubit = make();
      addTearDown(cubit.close);
      await tester.pumpWidget(harness(cubit, sourceNames: {'igdb': 'IGDB'}));
      await cubit.load();
      await tester.pumpAndSettle();

      expect(
        find.text("IGDB didn't answer, so some expansions may be missing."),
        findsOneWidget,
      );
      expect(find.text('Expansion 0'), findsOneWidget);
      expect(find.byType(BgeErrorState), findsNothing);
    });

    testWidgets('a $name DataGateway and no rows is a failure', (
      tester,
    ) async {
      remote.onFetchExpansions = (_) async => results();
      final cubit = make();
      addTearDown(cubit.close);
      await tester.pumpWidget(harness(cubit, sourceNames: {'igdb': 'IGDB'}));
      await cubit.load();
      await tester.pumpAndSettle();

      expect(find.byType(BgeEmptyState), findsNothing);
      expect(find.text("Couldn't load expansions"), findsOneWidget);
      expect(find.byKey(ExpansionChecklist.retryKey), findsOneWidget);
    });
  }

  testWidgets('no rows with every source answered is empty', (tester) async {
    remote.onFetchExpansions = (_) async => _bgg(0);
    final cubit = make();
    addTearDown(cubit.close);
    await tester.pumpWidget(harness(cubit));
    await cubit.load();
    await tester.pumpAndSettle();

    expect(find.byType(BgeEmptyState), findsOneWidget);
    expect(find.text('No expansions found.'), findsOneWidget);
  });

  testWidgets('no rows and a failed source shows the error with a retry', (
    tester,
  ) async {
    remote.onFetchExpansions = (_) async => _bgg(0, unavailable: {'bgg'});
    final cubit = make();
    addTearDown(cubit.close);
    await tester.pumpWidget(harness(cubit));
    await cubit.load();
    await tester.pumpAndSettle();

    expect(find.byType(BgeEmptyState), findsNothing);
    expect(find.text("Couldn't load expansions"), findsOneWidget);
    expect(remote.expansionTargets, hasLength(1));

    remote.onFetchExpansions = (_) async => _bgg(1);
    await tester.tap(find.byKey(ExpansionChecklist.retryKey));
    await tester.pumpAndSettle();

    expect(remote.expansionTargets, hasLength(2));
    expect(find.text('Expansion 0'), findsOneWidget);
  });

  testWidgets('a thrown failure shows the error with a retry', (tester) async {
    remote.onFetchExpansions = (_) async => throw unreachable();
    final cubit = make();
    addTearDown(cubit.close);
    await tester.pumpWidget(harness(cubit));
    await cubit.load();
    await tester.pumpAndSettle();

    expect(find.byKey(ExpansionChecklist.retryKey), findsOneWidget);
  });

  testWidgets('refused draws nothing', (tester) async {
    remote.onFetchExpansions = (_) async =>
        throw const GamesForbiddenException('no');
    final cubit = make(grant: DataGatewaySearchGrant());
    addTearDown(cubit.close);
    await tester.pumpWidget(harness(cubit));
    await cubit.load();
    await tester.pumpAndSettle();

    expect(find.text('Expansions'), findsNothing);
    expect(find.byType(BgeErrorState), findsNothing);
    expect(find.byType(CheckboxListTile), findsNothing);
  });

  testWidgets('a game on the server says so in words', (tester) async {
    remote.onFetchExpansions = (_) async => GameSearchResults(
      byDataGateway: {
        'bgg': [
          hit(
            'e0',
            title: 'Held',
            gameId: 'g-0',
            contentType: ContentType.expansion,
          ),
        ],
      },
    );
    final cubit = make();
    addTearDown(cubit.close);
    await tester.pumpWidget(harness(cubit));
    await cubit.load();
    await tester.pumpAndSettle();

    expect(find.textContaining('On this server'), findsOneWidget);
    final row = tile(tester, ExpansionChecklist.rowKey('bgg', 'e0'));
    expect(row.onChanged, isNull);
    // Nothing to tick: Select all stays, disabled.
    expect(
      tile(tester, ExpansionChecklist.selectAllKey('bgg')).onChanged,
      isNull,
    );
  });

  testWidgets('two groups are headed by their sources', (tester) async {
    remote.onFetchExpansions = (_) async => const GameSearchResults(
      byDataGateway: {
        'bgg': [
          GameSearchHit(
            externalId: 'a',
            title: 'A',
            contentType: ContentType.expansion,
          ),
        ],
        'igdb': [
          GameSearchHit(
            externalId: 'b',
            title: 'B',
            contentType: ContentType.expansion,
          ),
        ],
      },
    );
    final cubit = make();
    addTearDown(cubit.close);
    await tester.pumpWidget(
      harness(cubit, sourceNames: {'bgg': 'BoardGameGeek'}),
    );
    await cubit.load();
    await tester.pumpAndSettle();

    expect(find.text('BoardGameGeek'), findsOneWidget);
    expect(find.text('igdb'), findsOneWidget);
    expect(find.text('Select all'), findsNWidgets(2));
  });

  group('accessibility audit', () {
    auditScreen(
      'fifty rows',
      build: (theme) {
        remote.onFetchExpansions = (_) async => _bgg(50);
        final cubit = make();
        addTearDown(cubit.close);
        unawaited(cubit.load());
        return harness(cubit, theme: theme);
      },
      arrange: (tester) async {
        await tester.pumpAndSettle();
        expect(find.byType(CheckboxListTile), findsWidgets);
      },
    );
  });
}
