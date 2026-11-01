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
  Future<DataGatewayChangeResult> Function(String id, List<String> disabled)?
  onSetDisabledCapabilities;
  Future<DataGatewayChangeResult> Function(String id)? onDelete;
  Future<DataGatewayChangeResult> Function(String id)? onConnect;
  Future<DataGatewayChangeResult> Function(String id)? onDisconnect;
  Future<DataGatewayInterviewResult> Function(String id)? onInterview;
  Future<PaginatedResult<LanguageLink>> Function(
    String id,
    Set<LanguageLinkStatus>? statuses,
    int page,
    int limit,
  )?
  onFetchLanguageLinks;
  Future<LanguageLink> Function(String id, String linkId, String tagId)?
  onLinkLanguageLink;
  Future<LanguageLink> Function(String id, String linkId)? onIgnoreLanguageLink;
  Future<LanguageLink> Function(String id, String linkId)? onAcceptLanguageLink;
  Future<PaginatedResult<LanguageTagRef>> Function(
    String? name,
    int page,
    int limit,
  )?
  onFetchLanguageTags;

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
  Future<DataGatewayChangeResult> setDisabledCapabilities(
    String id,
    List<String> disabled,
  ) {
    calls.add('setDisabledCapabilities($id, $disabled)');
    return _run(onSetDisabledCapabilities, 'setDisabledCapabilities')(
      id,
      disabled,
    );
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

  @override
  Future<DataGatewayInterviewResult> interview(String id) {
    calls.add('interview($id)');
    return _run(onInterview, 'interview')(id);
  }

  @override
  Future<PaginatedResult<LanguageLink>> fetchLanguageLinks(
    String id, {
    Set<LanguageLinkStatus>? statuses,
    int page = 1,
    int limit = DataGatewayRemoteDataSource.languageLinkPageSize,
  }) {
    calls.add('fetchLanguageLinks($id, $statuses, $page)');
    return _run(onFetchLanguageLinks, 'fetchLanguageLinks')(
      id,
      statuses,
      page,
      limit,
    );
  }

  @override
  Future<LanguageLink> linkLanguageLink(
    String id,
    String linkId,
    String tagId,
  ) {
    calls.add('linkLanguageLink($id, $linkId, $tagId)');
    return _run(onLinkLanguageLink, 'linkLanguageLink')(id, linkId, tagId);
  }

  @override
  Future<LanguageLink> ignoreLanguageLink(String id, String linkId) {
    calls.add('ignoreLanguageLink($id, $linkId)');
    return _run(onIgnoreLanguageLink, 'ignoreLanguageLink')(id, linkId);
  }

  @override
  Future<LanguageLink> acceptLanguageLink(String id, String linkId) {
    calls.add('acceptLanguageLink($id, $linkId)');
    return _run(onAcceptLanguageLink, 'acceptLanguageLink')(id, linkId);
  }

  @override
  Future<PaginatedResult<LanguageTagRef>> fetchLanguageTags({
    String? name,
    int page = 1,
    int limit = DataGatewayRemoteDataSource.languageTagPageSize,
  }) {
    calls.add('fetchLanguageTags($name, $page)');
    return _run(onFetchLanguageTags, 'fetchLanguageTags')(name, page, limit);
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

/// A language tag whose name and tag say which one it is.
LanguageTagRef languageTag(String id, {String? name, String? tag}) =>
    LanguageTagRef(id: id, tag: tag ?? 'x-$id', name: name ?? 'Language $id');

/// One page of language tags, as the remote hands them over: flattened from
/// the languages the server paged.
///
/// [page] and [hasMore] are the languages' paging, so they say nothing about
/// how many tags came back: a page can hold none and have more behind it.
PaginatedResult<LanguageTagRef> tagPageOf(
  List<LanguageTagRef> tags, {
  int page = 1,
  bool hasMore = false,
}) => PaginatedResult(
  items: tags,
  meta: PaginationMeta(
    page: page,
    limit: DataGatewayRemoteDataSource.languageTagPageSize,
    total: tags.length,
    totalPages: hasMore ? page + 1 : page,
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
