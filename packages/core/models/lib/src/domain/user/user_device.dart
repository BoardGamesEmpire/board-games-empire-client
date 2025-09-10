import 'package:freezed_annotation/freezed_annotation.dart';

part 'user_device.freezed.dart';
part 'user_device.g.dart';

@freezed
abstract class UserDevice with _$UserDevice {
  const factory UserDevice({
    required String id,
    required String authenticationId,
    String? deviceName,
    required String deviceIdentifier,
    required DateTime lastUsed,
    required bool isTrusted,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) = _UserDevice;

  factory UserDevice.fromJson(Map<String, dynamic> json) =>
      _$UserDeviceFromJson(json);
}
