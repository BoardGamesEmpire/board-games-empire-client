import 'package:freezed_annotation/freezed_annotation.dart';

enum ConnectionState {
  @JsonValue('Active')
  active,

  @JsonValue('Monitoring')
  monitoring,

  @JsonValue('Disconnected')
  disconnected,
}
