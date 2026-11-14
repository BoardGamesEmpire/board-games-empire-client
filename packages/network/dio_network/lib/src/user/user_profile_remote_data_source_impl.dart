import 'package:dio/dio.dart';
import 'package:dio_network/src/network/api_error_envelope.dart';
import 'package:dio_network/src/network/remote_failure.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

/// [UserProfileRemoteDataSource] over a **per-server** Dio instance (#547).
///
/// Built like `SystemSettingsRemoteDataSourceImpl`: the body is asked for as
/// a `String`, `sendForJson` decodes it after the status is read, and a
/// failure is classified through [_UserProfileFailures]. It does not build or
/// own its Dio.
///
/// Failure taxonomy per the [UserProfileRemoteDataSource] contract.
class UserProfileRemoteDataSourceImpl implements UserProfileRemoteDataSource {
  const UserProfileRemoteDataSourceImpl(this._dio);

  final Dio _dio;

  static const String _path = '/api/users/me/profile';
  static const String _routeNotFoundCode = 'ROUTE_NOT_FOUND';
  static const _failures = _UserProfileFailures();

  /// See `GameCollectionRemoteDataSourceImpl._plainBody`: `Response<String>`
  /// alone is not enough when the injected Dio's own response type is
  /// `bytes` or `stream`. A fresh instance per call, because `Options` is
  /// mutable.
  static Options get _plainBody => Options(responseType: ResponseType.plain);

  @override
  Future<UserProfile> fetchOwn() async {
    const action = 'Own profile fetch';
    final response = await sendForJson(
      () => _dio.get<String>(_path, options: _plainBody),
      action: action,
      family: _failures,
    );
    return parseRemote(
      _failures,
      () => _mapProfile(response.body),
      action: action,
      status: response.status,
    );
  }

  @override
  Future<UserProfile> updateOwn(ProfilePatch patch) async {
    // Every check runs before the first `toWire`, so an unknown reach is an
    // ArgumentError and never the StateError its wire name throws.
    _validate(patch);

    const action = 'Own profile update';
    final response = await sendForJson(
      () => _dio.patch<String>(
        _path,
        data: _bodyOf(patch),
        options: _plainBody,
      ),
      action: action,
      family: _failures,
    );
    return parseRemote(
      _failures,
      () => _mapProfile(response.body),
      action: action,
      status: response.status,
    );
  }

  static void _validate(ProfilePatch patch) {
    if (patch.isEmpty) {
      throw ArgumentError.value(patch, 'patch', 'changes nothing');
    }
    if (patch.reach == Reach.unknown) {
      throw ArgumentError.value(patch.reach, 'patch.reach', 'has no wire name');
    }
    final displayName = patch.displayName?.trim();
    if (displayName != null) {
      if (displayName.isEmpty) {
        throw ArgumentError.value(
          patch.displayName,
          'patch.displayName',
          'is blank',
        );
      }
      _checkLength(
        'displayName',
        displayName,
        UserProfileRemoteDataSource.maxDisplayNameLength,
      );
    }
    // The server does not trim the bio: leading spaces are Markdown.
    _checkSetLength(
      'bio',
      patch.bio,
      UserProfileRemoteDataSource.maxBioLength,
      trim: false,
    );
    _checkSetLength(
      'pronouns',
      patch.pronouns,
      UserProfileRemoteDataSource.maxPronounsLength,
    );
    _checkSetLength(
      'location',
      patch.location,
      UserProfileRemoteDataSource.maxLocationLength,
    );
    _checkSetLength(
      'houseRulesPreference',
      patch.houseRulesPreference,
      UserProfileRemoteDataSource.maxHouseRulesLength,
    );
    _checkSetLength(
      'dietaryRestrictions',
      patch.dietaryRestrictions,
      UserProfileRemoteDataSource.maxPracticalInfoLength,
    );
    _checkSetLength(
      'accessibilityNeeds',
      patch.accessibilityNeeds,
      UserProfileRemoteDataSource.maxPracticalInfoLength,
    );
    final count = patch.preferredPlayerCount;
    if (count is SettingSet<int> &&
        (count.value < UserProfileRemoteDataSource.minPlayerCount ||
            count.value > UserProfileRemoteDataSource.maxPlayerCount)) {
      throw ArgumentError.value(
        count.value,
        'patch.preferredPlayerCount',
        'must be between ${UserProfileRemoteDataSource.minPlayerCount} and '
            '${UserProfileRemoteDataSource.maxPlayerCount}',
      );
    }
  }

  /// A [SettingClear] is never over a cap.
  static void _checkSetLength(
    String name,
    SettingValue<String>? value,
    int max, {
    bool trim = true,
  }) {
    if (value is SettingSet<String>) {
      _checkLength(name, trim ? value.value.trim() : value.value, max);
    }
  }

  static void _checkLength(String name, String measured, int max) {
    if (serverStringLength(measured) > max) {
      throw ArgumentError.value(
        name,
        'patch.$name',
        'is longer than $max characters',
      );
    }
  }

  /// Only the fields the patch changes: a [SettingClear] is JSON `null`.
  static Map<String, Object?> _bodyOf(ProfilePatch patch) {
    Object? read<T extends Object>(SettingValue<T> value) => switch (value) {
      SettingSet<T>(:final value) => value,
      SettingClear<T>() => null,
    };
    return {
      'displayName': ?patch.displayName,
      if (patch.bio case final value?) 'bio': read(value),
      if (patch.pronouns case final value?) 'pronouns': read(value),
      if (patch.location case final value?) 'location': read(value),
      if (patch.houseRulesPreference case final value?)
        'houseRulesPreference': read(value),
      if (patch.dietaryRestrictions case final value?)
        'dietaryRestrictions': read(value),
      if (patch.accessibilityNeeds case final value?)
        'accessibilityNeeds': read(value),
      if (patch.preferredPlayerCount case final value?)
        'preferredPlayerCount': read(value),
      'willingToTeach': ?patch.willingToTeach,
      'openToNewPlayers': ?patch.openToNewPlayers,
      'hostingCapability': ?patch.hostingCapability,
      'isSearchable': ?patch.isSearchable,
      if (patch.reach case final value?) 'reach': value.toWire(),
    };
  }

  /// Reads `{ profile: {...} }`. The owner-only fields are absent for anyone
  /// but the owner, and read as null.
  static UserProfile _mapProfile(Map<String, dynamic> body) {
    final json = body['profile'];
    if (json is! Map<String, dynamic>) {
      throw FormatException(
        json == null
            ? 'response is missing the "profile" object'
            : 'response field "profile" is ${json.runtimeType}, expected '
                  'an object',
      );
    }
    final reach = json['reach'];
    return UserProfile(
      userId: json['userId'] as String,
      username: json['username'] as String,
      displayName: json['displayName'] as String?,
      avatarUrl: json['avatarUrl'] as String?,
      bio: json['bio'] as String?,
      pronouns: json['pronouns'] as String?,
      location: json['location'] as String?,
      preferredPlayerCount: json['preferredPlayerCount'] as int?,
      willingToTeach: json['willingToTeach'] as bool,
      openToNewPlayers: json['openToNewPlayers'] as bool,
      houseRulesPreference: json['houseRulesPreference'] as String?,
      hostingCapability: json['hostingCapability'] as bool,
      dietaryRestrictions: json['dietaryRestrictions'] as String?,
      accessibilityNeeds: json['accessibilityNeeds'] as String?,
      reach: reach == null ? null : Reach.fromWire(reach as String),
      isSearchable: json['isSearchable'] as bool?,
    );
  }
}

/// How the profile source builds its failures for the shared classifier.
final class _UserProfileFailures
    extends RemoteFailureFamily<UserProfileRemoteException> {
  const _UserProfileFailures()
    : super(
        transient: UserProfileTransientException.new,
        permanent: UserProfilePermanentException.new,
      );

  /// Both refusals need the API's envelope: without it the shared rules
  /// already called a 403 or a 404 not the API, and it never reaches here.
  ///
  /// An enveloped 404 is a missing profile unless it is the router's own
  /// `ROUTE_NOT_FOUND`, which says the route does not exist. That one is not
  /// claimed, so the shared default applies, and at 404 it is transient.
  @override
  UserProfileRemoteException? refused(RemoteRefusal refusal) {
    final status = refusal.status;
    if (!refusal.fromApi) return null;
    if (status == 404 &&
        apiErrorField(refusal.body, 'code') !=
            UserProfileRemoteDataSourceImpl._routeNotFoundCode) {
      return UserProfileNotFoundException(
        refusal.message,
        statusCode: status,
        cause: refusal.cause,
      );
    }
    if (status == 403) {
      return UserProfileRefusedException(
        refusal.message,
        statusCode: status,
        cause: refusal.cause,
      );
    }
    return null;
  }
}
