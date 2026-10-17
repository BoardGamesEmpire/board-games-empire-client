import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

/// A [DataGatewayRemoteDataSource] whose every answer the test scripts.
///
/// Each method records its call in [calls] and then runs the matching
/// handler. An unscripted call throws [StateError], so a test can't pass by
/// reaching a route it never meant to.
class FakeDataGatewayRemote implements DataGatewayRemoteDataSource {
  final List<String> calls = [];

  Future<PaginatedResult<DataGateway>> Function(int page, int limit)?
  onFetchPage;
  Future<DataGateway> Function(String id)? onFetchOne;
  Future<DataGatewayChangeResult> Function(DataGatewayInput input)? onCreate;
  Future<DataGatewayChangeResult> Function(
    String id,
    DataGatewayChanges changes,
  )?
  onUpdate;
  Future<DataGatewayChangeResult> Function(String id)? onDelete;
  Future<DataGatewayChangeResult> Function(String id)? onConnect;
  Future<DataGatewayChangeResult> Function(String id)? onDisconnect;

  /// Answers every list read with [rows] on one page.
  void listing(List<DataGateway> rows) =>
      onFetchPage = (page, limit) async => pageOf(rows);

  /// Refuses every list read the way the API refuses a role.
  void refusingReads() => onFetchPage = (_, _) async => throw forbidden();

  @override
  Future<PaginatedResult<DataGateway>> fetchPage({
    int page = 1,
    int limit = DataGatewayRemoteDataSource.maxPageSize,
  }) {
    calls.add('fetchPage($page, $limit)');
    return _run(onFetchPage, 'fetchPage')(page, limit);
  }

  @override
  Future<DataGateway> fetchOne(String id) {
    calls.add('fetchOne($id)');
    return _run(onFetchOne, 'fetchOne')(id);
  }

  @override
  Future<DataGatewayChangeResult> create(DataGatewayInput input) {
    calls.add('create(${input.name})');
    return _run(onCreate, 'create')(input);
  }

  @override
  Future<DataGatewayChangeResult> update(
    String id,
    DataGatewayChanges changes,
  ) {
    calls.add('update($id)');
    return _run(onUpdate, 'update')(id, changes);
  }

  @override
  Future<DataGatewayChangeResult> delete(String id) {
    calls.add('delete($id)');
    return _run(onDelete, 'delete')(id);
  }

  @override
  Future<DataGatewayChangeResult> connect(String id) {
    calls.add('connect($id)');
    return _run(onConnect, 'connect')(id);
  }

  @override
  Future<DataGatewayChangeResult> disconnect(String id) {
    calls.add('disconnect($id)');
    return _run(onDisconnect, 'disconnect')(id);
  }

  static T _run<T extends Function>(T? handler, String name) =>
      handler ?? (throw StateError('$name was not scripted'));
}

DataGateway gateway(
  String id, {
  String? name,
  bool enabled = true,
  String? description,
  String connectionUrl = 'gateway.internal',
  int connectionPort = 50051,
}) => DataGateway(
  id: id,
  name: name ?? 'Gateway $id',
  description: description,
  connectionUrl: connectionUrl,
  connectionPort: connectionPort,
  enabled: enabled,
  authType: DataGatewayAuthType.none,
);

PaginatedResult<DataGateway> pageOf(
  List<DataGateway> rows, {
  int page = 1,
  bool hasMore = false,
}) => PaginatedResult(
  items: rows,
  meta: PaginationMeta(
    page: page,
    limit: DataGatewayRemoteDataSource.maxPageSize,
    total: rows.length,
    totalPages: 1,
    hasMore: hasMore,
  ),
);

DataGatewayChangeResult changed(
  DataGateway row, {
  DataGatewayConnectionAction? attempted,
  bool succeeded = true,
}) => DataGatewayChangeResult(
  dataGateway: row,
  connectionAttempt: attempted == null
      ? null
      : DataGatewayConnectionAttempt(action: attempted, succeeded: succeeded),
);

DataGatewayForbiddenException forbidden() =>
    const DataGatewayForbiddenException('refused', statusCode: 403);

DataGatewayTransientException unreachable() =>
    const DataGatewayTransientException('unreachable');
