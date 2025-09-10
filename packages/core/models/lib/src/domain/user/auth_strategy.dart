import 'package:freezed_annotation/freezed_annotation.dart';

enum AuthStrategy {
  @JsonValue('Apple')
  apple,
  @JsonValue('Custom')
  custom,
  @JsonValue('Facebook')
  facebook,
  @JsonValue('GitHub')
  gitHub,
  @JsonValue('Google')
  google,
  @JsonValue('Local')
  local,
  @JsonValue('Microsoft')
  microsoft,
}
