import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:game_catalog/src/expansions/expansion_checklist_cubit.dart';
import 'package:game_catalog/src/expansions/expansion_checklist_state.dart';
import 'package:game_catalog/src/search/data_gateway_search_grant.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

import '../support/fake_games_remote.dart';

const _target = GameExpansionsTarget.dataGateway(
  gatewayId: 'bgg',
  externalId: 'base',
);

GameSearchResults _results() => GameSearchResults(
  byDataGateway: {
    'bgg': [
      hit('e1', title: 'One', contentType: ContentType.expansion),
      hit('e2', title: 'Two', gameId: 'g-2'),
      hit('e3', title: 'Three'),
    ],
    'igdb': [hit('i1', title: 'Uno')],
  },
);

void main() {
  late FakeGamesRemote remote;

  setUp(() {
    remote = FakeGamesRemote()..onFetchExpansions = (_) async => _results();
  });

  ExpansionChecklistCubit make({
    bool tickOnServer = false,
    DataGatewaySearchGrant? grant,
    GameExpansionsTarget target = _target,
  }) => ExpansionChecklistCubit(
    remote: remote,
    target: target,
    tickOnServer: tickOnServer,
    grant: grant,
  );

  ExpansionChecklistReady ready(ExpansionChecklistCubit cubit) =>
      cubit.state as ExpansionChecklistReady;

  test('loads, then is ready with nothing ticked', () async {
    final cubit = make();
    expect(cubit.state, isA<ExpansionChecklistLoading>());

    await cubit.load();

    expect(remote.expansionTargets, [_target]);
    expect(ready(cubit).results, _results());
    expect(ready(cubit).ticked, isEmpty);
    expect(cubit.tickedIn('bgg'), isEmpty);
    expect(cubit.titlesByExternalId, {
      'e1': 'One',
      'e2': 'Two',
      'e3': 'Three',
      'i1': 'Uno',
    });
    await cubit.close();
  });

  test('toggle ticks and unticks a row', () async {
    final cubit = make();
    await cubit.load();

    cubit.toggle('bgg', 'e1');
    expect(cubit.tickedIn('bgg'), ['e1']);
    cubit.toggle('bgg', 'e1');
    expect(cubit.tickedIn('bgg'), isEmpty);
    await cubit.close();
  });

  test("a game on the server can't be ticked unless tickOnServer", () async {
    final cubit = make();
    await cubit.load();
    cubit.toggle('bgg', 'e2');
    expect(cubit.tickedIn('bgg'), isEmpty);
    await cubit.close();

    final allowing = make(tickOnServer: true);
    await allowing.load();
    allowing.toggle('bgg', 'e2');
    expect(allowing.tickedIn('bgg'), ['e2']);
    await allowing.close();
  });

  test('setAll ticks every tickable row, and unticks them', () async {
    final cubit = make();
    await cubit.load();

    cubit.setAll('bgg', ticked: true);
    expect(cubit.tickedIn('bgg'), ['e1', 'e3']);
    expect(cubit.tickedIn('igdb'), isEmpty);

    cubit.setAll('bgg', ticked: false);
    expect(cubit.tickedIn('bgg'), isEmpty);

    final allowing = make(tickOnServer: true);
    await allowing.load();
    allowing.setAll('bgg', ticked: true);
    expect(allowing.tickedIn('bgg'), ['e1', 'e2', 'e3']);
    await cubit.close();
    await allowing.close();
  });

  test("tickedIn keeps the rows' order", () async {
    final cubit = make();
    await cubit.load();

    cubit
      ..toggle('bgg', 'e3')
      ..toggle('bgg', 'e1');

    expect(cubit.tickedIn('bgg'), ['e1', 'e3']);
    await cubit.close();
  });

  test('a 403 refuses the grant and emits Refused', () async {
    final grant = DataGatewaySearchGrant();
    remote.onFetchExpansions = (_) async =>
        throw const GamesForbiddenException('no', apiMessage: 'Not for you');
    final cubit = make(grant: grant);

    await cubit.load();

    expect(cubit.state, isA<ExpansionChecklistRefused>());
    expect(grant.mayAsk, isFalse);
    expect(grant.serverMessage, 'Not for you');
    await cubit.close();
  });

  // For a game on this server, the server answers 403 for a game the user
  // may not read too, which says nothing about the DataGateways.
  test("a game's 403 emits Refused and leaves the grant", () async {
    final grant = DataGatewaySearchGrant();
    remote.onFetchExpansions = (_) async =>
        throw const GamesForbiddenException('no', apiMessage: 'Not for you');
    final cubit = make(
      grant: grant,
      target: const GameExpansionsTarget.game('g-1'),
    );

    await cubit.load();

    expect(cubit.state, isA<ExpansionChecklistRefused>());
    expect(grant.mayAsk, isTrue);
    expect(grant.serverMessage, isNull);
    await cubit.close();
  });

  blocTest<ExpansionChecklistCubit, ExpansionChecklistState>(
    'a failure emits Failed, and load again recovers',
    build: () {
      var asked = 0;
      remote.onFetchExpansions = (_) async =>
          ++asked == 1 ? throw unreachable() : _results();
      return make();
    },
    act: (cubit) async {
      await cubit.load();
      await cubit.load();
    },
    expect: () => [
      isA<ExpansionChecklistFailed>(),
      isA<ExpansionChecklistLoading>(),
      isA<ExpansionChecklistReady>(),
    ],
  );
}
