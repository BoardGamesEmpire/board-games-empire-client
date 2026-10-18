import 'package:data_gateway/data_gateway.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_interface/network_interface.dart';

import '../support/fake_data_gateway_remote.dart';

/// The DataGateways' names, for a screen that shows which one found a game
/// search result (#42).
void main() {
  late FakeDataGatewayRemote remote;

  setUp(() => remote = FakeDataGatewayRemote());

  test(
    'reads every DataGateway\'s name, by id, to the end of the list',
    () async {
      remote.onFetchPage = (page, _) async => page == 1
          ? pageOf([gateway('dg_1', name: 'BGG')], hasMore: true)
          : pageOf([gateway('dg_2', name: 'Steam')], page: 2);

      expect(await readDataGatewayNames(remote), {
        'dg_1': 'BGG',
        'dg_2': 'Steam',
      });
    },
  );

  test('a list that never ends is a failed read, not a partial one', () {
    remote.onFetchPage = (page, _) async =>
        pageOf([gateway('dg_$page')], page: page, hasMore: true);

    expect(readDataGatewayNames(remote), throwsStateError);
  });

  test('a refusal reaches the caller', () {
    remote.refusingReads();

    expect(
      readDataGatewayNames(remote),
      throwsA(isA<DataGatewayForbiddenException>()),
    );
  });
}
