import 'package:equatable/equatable.dart';
import 'package:models/domain.dart';

/// What a game's expansion checklist holds (#713).
sealed class ExpansionChecklistState extends Equatable {
  const ExpansionChecklistState();

  @override
  List<Object?> get props => [];
}

/// The expansions are being read.
final class ExpansionChecklistLoading extends ExpansionChecklistState {
  const ExpansionChecklistLoading();
}

/// The server answered. [results] holds the expansions by DataGateway, and
/// [ticked] the External IDs ticked in each.
///
/// An answer can still be short: a DataGateway that failed, was rate limited
/// or could not be reached is named in [results], and its expansions may be
/// missing.
final class ExpansionChecklistReady extends ExpansionChecklistState {
  const ExpansionChecklistReady({required this.results, required this.ticked});

  final GameSearchResults results;

  /// The External IDs ticked, by DataGateway id.
  final Map<String, Set<String>> ticked;

  @override
  List<Object?> get props => [results, ticked];
}

/// The read failed. Reading again may recover.
final class ExpansionChecklistFailed extends ExpansionChecklistState {
  const ExpansionChecklistFailed();
}

/// The server refused the read: this user may not read DataGateways. The
/// checklist draws nothing, and the search grant remembers the refusal.
final class ExpansionChecklistRefused extends ExpansionChecklistState {
  const ExpansionChecklistRefused();
}
