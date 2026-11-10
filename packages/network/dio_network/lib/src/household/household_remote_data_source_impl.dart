import 'package:dio/dio.dart';
import 'package:dio_network/src/games/game_summary_json.dart';
import 'package:dio_network/src/household/household_member_json.dart';
import 'package:dio_network/src/network/remote_failure.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

/// [HouseholdRemoteDataSource] over a **per-server** Dio instance (#39).
///
/// The path is relative — the per-server Dio carries the base URL
/// (path-prefix deployments included). The BetterAuth session the endpoint
/// requires is attached below this class: by the per-server auth plumbing
/// (TokenInterceptor) on native, and by the browser, as its session cookie,
/// on web. This class adds no auth handling of its own; it is constructed
/// from the per-server container by the network installer (#39 wiring), so
/// unlike `WellKnownClientImpl` it does **not** build or own its Dio, and it
/// is intentionally **not** an injectable global singleton (the per-server
/// Dio is outside the global graph).
///
/// The body is asked for as a `String` with the response type pinned on
/// every request, and `sendForJson` decodes it after the status is read and
/// classifies a failure through [_HouseholdFailures].
///
/// Failure taxonomy per the [HouseholdRemoteDataSource] contract — see that
/// interface for the transient/permanent split.
class HouseholdRemoteDataSourceImpl implements HouseholdRemoteDataSource {
  const HouseholdRemoteDataSourceImpl(this._dio);

  final Dio _dio;

  static const String _basePath = '/api/households';

  /// Pinned on every request rather than inherited from the injected Dio.
  ///
  /// Asking for `Response<String>` is not sufficient on its own: `fetch`'s
  /// forcing block is skipped when the instance's `responseType` is already
  /// `bytes`/`stream` (`dio_mixin.dart:419-421`), and `assureResponse` then
  /// casts the body to `String` anyway (`:807`). That `TypeError` escapes as
  /// `DioException(type: unknown)` with no response attached — the same
  /// status-losing failure #265 fixed here, arriving by a different route.
  /// #360 finished generalising this: every `_dio` call site under
  /// `packages/network/*/lib` now pins `responseType` per request.
  ///
  /// A fresh instance per call: `Options` is mutable, and one shared between
  /// the request methods is a shared mutable default waiting to be edited.
  static Options get _plainBody => Options(responseType: ResponseType.plain);

  @override
  Future<PaginatedResult<HouseholdWithMembers>> fetchHouseholds({
    int page = 1,
    int limit = HouseholdRemoteDataSource.maxPageSize,
  }) async {
    _checkPaging(page: page, limit: limit);

    const action = 'Household list';
    const failures = _HouseholdFailures();
    final (:body, :status) = await sendForJson(
      () => _dio.get<String>(
        _basePath,
        options: _plainBody,
        queryParameters: {'page': page, 'limit': limit},
      ),
      action: action,
      family: failures,
    );

    return parseRemote(
      failures,
      () => PaginatedResult.fromEnvelope(
        body,
        key: 'households',
        item: _mapHouseholdWithMembers,
      ),
      action: action,
      status: status,
    );
  }

  @override
  Future<GamePoolSample> fetchGamePoolSample({
    int size = GamesRemoteDataSource.defaultSampleSize,
  }) async {
    checkSampleSize(size);

    const action = 'Household game pool sample';
    const failures = _HouseholdFailures();
    final (:body, :status) = await sendForJson(
      () => _dio.get<String>(
        '$_basePath/game-pool/random',
        options: _plainBody,
        queryParameters: {'size': size},
      ),
      action: action,
      family: failures,
    );

    return parseRemote(
      failures,
      () {
        final games = body['games'];
        final gameCount = body['gameCount'];
        if (games is! List) {
          throw const FormatException('response is missing a "games" array');
        }
        // Read strictly: a count defaulted to 0 would tell a user with games
        // that they have none.
        if (gameCount is! int) {
          throw FormatException(
            'response "gameCount" is ${gameCount.runtimeType}, expected an int',
          );
        }
        return (
          games: [
            for (final row in games.cast<Map<String, dynamic>>())
              mapGameSummary(row),
          ],
          gameCount: gameCount,
        );
      },
      action: action,
      status: status,
    );
  }

  @override
  Future<Household> createHousehold({
    required String name,
    required String clientRequestId,
    String? description,
    String? image,
    String? language,
    String? visibility,
  }) async {
    _checkClientRequestId(clientRequestId);
    return _sendForHousehold(
      () => _dio.post<String>(
        '/api/households',
        options: _plainBody,
        data: {
          'name': name,
          'clientRequestId': clientRequestId,
          'description': ?description,
          'image': ?image,
          'language': ?language,
          'visibility': ?visibility,
        },
      ),
      action: 'Household create',
    );
  }

  @override
  Future<Household> updateHousehold(
    String householdId,
    HouseholdUpdate update,
  ) async {
    if (householdId.isEmpty) {
      throw ArgumentError.value(householdId, 'householdId', 'is empty');
    }
    if (update.isEmpty) {
      throw ArgumentError.value(
        update,
        'update',
        'changes nothing (the server rejects an empty patch with a 400)',
      );
    }

    return _sendForHousehold(
      () => _dio.patch<String>(
        '$_basePath/${Uri.encodeComponent(householdId)}',
        options: _plainBody,
        data: {
          'name': ?update.name,
          // A null description is how the server is told to clear it, so
          // the key is sent rather than dropped (#476).
          if (update.clearDescription)
            'description': null
          else
            'description': ?update.description,
          if (update.memberInvitePolicy case final policy?)
            'settings': {'memberInvitePolicy': policy.toWire()},
        },
      ),
      action: 'Household update',
      // The route names the household, so an enveloped 404 is about it.
      rowRoute: true,
    );
  }

  /// Sends [request] and reads the `{ message, household }` answer the
  /// create and the update share. [rowRoute] is passed to
  /// [_HouseholdFailures].
  Future<Household> _sendForHousehold(
    Future<Response<String>> Function() request, {
    required String action,
    bool rowRoute = false,
  }) async {
    final family = _HouseholdFailures(rowRoute: rowRoute);
    final (body: data, :status) = await sendForJson(
      request,
      action: action,
      family: family,
    );

    final household = data['household'];
    if (household is! Map<String, dynamic>) {
      throw HouseholdRemotePermanentException(
        '$action response missing a "household" object',
        statusCode: status,
      );
    }

    return parseRemote(
      family,
      () => _mapHousehold(household),
      action: action,
      status: status,
    );
  }

  /// Maps the server household payload to the domain [Household].
  ///
  /// Explicit field mapping (not [Household.fromJson]) keeps the server
  /// representation decoupled from the local-persistence representation:
  /// the server response carries fields the model doesn't (languageTagId,
  /// createdById, visibility, embedded members …) and omits the client-only
  /// sync flags, which default to `false` for this server-confirmed row.
  Household _mapHousehold(Map<String, dynamic> json) => Household(
    id: json['id'] as String,
    name: json['name'] as String,
    description: json['description'] as String?,
    image: json['image'] as String?,
    settings: _mapSettings(json['settings']),
    deletedAt: _dateOrNull(json['deletedAt']),
    createdAt: DateTime.parse(json['createdAt'] as String),
    updatedAt: DateTime.parse(json['updatedAt'] as String),
  );

  /// Maps one row of the list endpoint — a household plus the members the
  /// include embeds.
  /// An absent `members` key is an empty roster — a response that did not
  /// carry the include. A `members` of the wrong type is a contract breach and
  /// throws, for the same reason the role projection does: silently reporting
  /// "no members" for a payload we failed to read would look exactly like a
  /// household the user is alone in.
  HouseholdWithMembers _mapHouseholdWithMembers(Map<String, dynamic> json) {
    final members = json['members'];
    if (members != null && members is! List) {
      throw FormatException(
        'household "members" is ${members.runtimeType}, expected a list',
      );
    }
    return (
      household: _mapHousehold(json),
      members: members == null
          ? const <HouseholdMember>[]
          : (members as List)
                .map(
                  (member) =>
                      mapHouseholdMember(member as Map<String, dynamic>),
                )
                .toList(growable: false),
    );
  }

  /// Reads the household's settings: the list, the detail and the update
  /// answer carry them, and the create answer does not (#476).
  ///
  /// An absent or null `settings` is none, which leaves a cached policy as
  /// it is. One of the wrong shape, or a policy that is not a string, is a
  /// contract breach and throws, for the same reason the role projection
  /// does: [MemberInvitePolicy.unknown] is for a policy name this client
  /// does not know, not for a payload it failed to read.
  static HouseholdSettings? _mapSettings(Object? settings) {
    if (settings == null) return null;
    if (settings is! Map<String, dynamic>) {
      throw FormatException(
        'household "settings" is ${settings.runtimeType}, expected an object',
      );
    }
    final policy = settings['memberInvitePolicy'];
    if (policy is! String) {
      throw FormatException(
        'household settings "memberInvitePolicy" is ${policy.runtimeType}, '
        'expected a string',
      );
    }
    return HouseholdSettings(
      memberInvitePolicy: MemberInvitePolicy.fromWire(policy),
    );
  }

  static DateTime? _dateOrNull(Object? value) =>
      value == null ? null : DateTime.parse(value as String);

  /// `page` is 1-based and `limit` is capped at
  /// [HouseholdRemoteDataSource.maxPageSize]; the server **rejects** a
  /// violation with a 400 rather than clamping it. A 400 mid-hydrate
  /// classifies as permanent, so an out-of-range page would fail the whole
  /// sync for a reason the caller could have known locally.
  void _checkPaging({required int page, required int limit}) {
    const maxPageSize = HouseholdRemoteDataSource.maxPageSize;
    const maxPageDepth = HouseholdRemoteDataSource.maxPageDepth;
    if (limit < 1 || limit > maxPageSize) {
      throw ArgumentError.value(
        limit,
        'limit',
        'must be between 1 and $maxPageSize (the server rejects a larger '
            'page rather than clamping it)',
      );
    }
    if (page < 1) {
      throw ArgumentError.value(page, 'page', 'is 1-based');
    }
    // Divided rather than multiplied: `(page - 1) * limit` wraps on the VM for
    // a large enough page and would land back under the ceiling. For integers,
    // `x * limit > depth` holds exactly when `x > depth ~/ limit`, and `limit`
    // is at least 1 by now.
    if (page - 1 > maxPageDepth ~/ limit) {
      throw ArgumentError.value(
        page,
        'page',
        '(page - 1) * limit must not exceed $maxPageDepth',
      );
    }
  }

  /// The server trims `clientRequestId`, then requires 1 to
  /// [HouseholdRemoteDataSource.maxClientRequestIdLength] characters, and
  /// answers a violation with a 400. That is permanent, and a permanent
  /// create is parked on its first attempt (#121), so a key the caller got
  /// wrong is refused here instead, with an error outside the
  /// transient/permanent split: the sender counts it as a client fault
  /// rather than parking it as the server's verdict.
  ///
  /// This matches the server exactly for ASCII keys, and every key this
  /// client mints is a cuid2, which is ASCII. Past ASCII the two can
  /// disagree at the edges: Dart's `trim` also strips U+0085, which the
  /// server's does not, and the server counts a surrogate pair as one
  /// character where `length` counts two.
  ///
  /// The key is still sent untrimmed: the server trims it before storing or
  /// matching it, so the two forms are one key.
  void _checkClientRequestId(String clientRequestId) {
    const maxLength = HouseholdRemoteDataSource.maxClientRequestIdLength;
    final length = clientRequestId.trim().length;
    if (length == 0 || length > maxLength) {
      throw ArgumentError.value(
        clientRequestId,
        'clientRequestId',
        'must be 1 to $maxLength characters after trimming (the server '
            'rejects anything else with a 400)',
      );
    }
  }
}

/// How the household source builds its failures for the shared classifier.
final class _HouseholdFailures
    extends RemoteFailureFamily<HouseholdRemoteException> {
  const _HouseholdFailures({this.rowRoute = false})
    : super(
        transient: HouseholdRemoteTransientException.new,
        permanent: HouseholdRemotePermanentException.new,
      );

  /// Whether the route names a household by id, so that an enveloped 404 from
  /// it is about that household. Only the update sets it.
  final bool rowRoute;

  /// On a route that names the household, an enveloped 404 says it is gone
  /// (#476). The envelope is the minimum bar, and why it is accepted though
  /// Nest's route-not-found carries it too is in the contract.
  ///
  /// The list and the create are fixed routes, so a 404 from either falls
  /// to the shared default, transient: it can only mean the request did not
  /// reach the household module, and on the create path a permanent verdict
  /// would park the queued create (#121) over a failure a retry would have
  /// survived (#297). A 404 without the envelope never reaches this hook, not
  /// even from the update: the shared rules have already read it as something
  /// in front of the API answering, and made it transient.
  @override
  HouseholdRemoteException? refused(RemoteRefusal refusal) =>
      refusal.status == 404 && rowRoute
      ? HouseholdNotFoundException(
          '${refusal.message}; the household is gone',
          statusCode: refusal.status,
          cause: refusal.cause,
        )
      : null;
}
