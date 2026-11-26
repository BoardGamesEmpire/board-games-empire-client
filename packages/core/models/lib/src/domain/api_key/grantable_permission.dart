import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:models/src/domain/api_key/risk_level.dart';

part 'grantable_permission.freezed.dart';

/// A permission the signed-in user may give an API key (#1028).
@freezed
abstract class GrantablePermission with _$GrantablePermission {
  const factory GrantablePermission({
    required String slug,

    /// The server's own description, in the request's locale.
    required String description,
    required RiskLevel riskLevel,

    /// Whether the permission may be limited to one record.
    required bool pinnable,
  }) = _GrantablePermission;
}
