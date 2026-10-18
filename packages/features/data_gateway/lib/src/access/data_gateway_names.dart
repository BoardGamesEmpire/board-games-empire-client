import 'package:network_interface/network_interface.dart';

/// A bound on how many pages one read of the DataGateway list follows.
///
/// DataGateways are installation configuration, so a real list is one page;
/// this only stops a server that always says `hasMore` from looping forever.
/// Reaching it is a failed read, not a partial list.
const int dataGatewayListMaxPages = 50;

/// Reads every live DataGateway's name, by id (#42).
///
/// For a screen that names DataGateways without managing them, such as the
/// game search, which shows which DataGateway found a result. Only a user who
/// may read DataGateways can call it: anyone else gets a
/// [DataGatewayForbiddenException], like any other read.
///
/// Throws [StateError] when the list still has more after
/// [dataGatewayListMaxPages] pages, as `DataGatewayListBloc` treats that
/// list, and whatever the remote throws for a failed page.
Future<Map<String, String>> readDataGatewayNames(
  DataGatewayRemoteDataSource remote,
) async {
  final names = <String, String>{};
  for (var page = 1; page <= dataGatewayListMaxPages; page++) {
    final result = await remote.fetchPage(page: page);
    for (final gateway in result.items) {
      names[gateway.id] = gateway.name;
    }
    if (!result.meta.hasMore) return names;
  }
  throw StateError(
    'the DataGateway list still had more after $dataGatewayListMaxPages pages',
  );
}
