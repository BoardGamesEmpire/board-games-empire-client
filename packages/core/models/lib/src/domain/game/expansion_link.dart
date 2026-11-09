import 'package:freezed_annotation/freezed_annotation.dart';

part 'expansion_link.freezed.dart';
part 'expansion_link.g.dart';

/// A link from an expansion to one of its base games (#711).
///
/// An expansion can have several base games; each link says whether the
/// expansion plays on its own with that base.
@freezed
abstract class ExpansionLink with _$ExpansionLink {
  const factory ExpansionLink({
    /// The base game's id.
    required String gameId,

    /// True when the expansion can be played without the base game.
    required bool isStandalone,
  }) = _ExpansionLink;

  factory ExpansionLink.fromJson(Map<String, dynamic> json) =>
      _$ExpansionLinkFromJson(json);
}
