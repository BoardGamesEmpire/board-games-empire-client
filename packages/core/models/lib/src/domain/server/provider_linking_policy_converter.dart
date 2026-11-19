import 'package:json_annotation/json_annotation.dart';
import 'package:models/src/domain/system_settings/system_settings.dart';

/// Reads and writes the discovery document's provider linking policy (#791).
///
/// An absent key reads as [ProviderLinkingPolicy.unknown], and `unknown` is
/// written as `null`, since it has no wire name.
class ProviderLinkingPolicyConverter
    implements JsonConverter<ProviderLinkingPolicy, String?> {
  const ProviderLinkingPolicyConverter();

  @override
  ProviderLinkingPolicy fromJson(String? json) => json == null
      ? ProviderLinkingPolicy.unknown
      : ProviderLinkingPolicy.fromWire(json);

  @override
  String? toJson(ProviderLinkingPolicy policy) =>
      policy == ProviderLinkingPolicy.unknown ? null : policy.wireName;
}
