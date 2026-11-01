import 'package:equatable/equatable.dart';
import 'package:models/domain.dart';

/// Which of a DataGateway's language links the worklist shows (#457).
enum LanguageLinkFilter {
  /// The links waiting on a review: pending and unresolved. The server's own
  /// default, so a read under it names no status.
  waiting,

  /// The links an admin dismissed. Linking one is how an ignore is undone.
  ignored,

  /// The links linked to a language tag.
  resolved,
}

/// An action on one language link (#457).
enum LanguageLinkAction {
  /// Link it to the language tag the user picks, whatever its status.
  link,

  /// Dismiss it, whatever its status. Interviews and imports leave an ignored
  /// link alone.
  ignore,

  /// Add the language it names, where the server has none, and link it to
  /// that. For a pending link only.
  accept,
}

/// The actions a link in [status] offers, in menu order.
///
/// Link and ignore are offered whatever the status, because the server takes
/// them from any: linking an ignored link is how an ignore is undone (#457).
/// An ignored link doesn't offer ignore, which would change nothing. Accept
/// is offered on a pending link alone, the one status it takes. A status this
/// client doesn't know offers link and ignore.
List<LanguageLinkAction> languageLinkActions(LanguageLinkStatus status) =>
    switch (status) {
      LanguageLinkStatus.pending => const [
        LanguageLinkAction.accept,
        LanguageLinkAction.link,
        LanguageLinkAction.ignore,
      ],
      LanguageLinkStatus.ignored => const [LanguageLinkAction.link],
      LanguageLinkStatus.unresolved ||
      LanguageLinkStatus.resolved ||
      LanguageLinkStatus.unknown => const [
        LanguageLinkAction.link,
        LanguageLinkAction.ignore,
      ],
    };

/// What a DataGateway's language worklist is showing (#457).
///
/// Every state carries the [filter] it is for, so the filter control shows
/// the one chosen while its first read runs, and after that read fails.
sealed class LanguageLinkListState extends Equatable {
  const LanguageLinkListState(this.filter);

  final LanguageLinkFilter filter;

  @override
  List<Object?> get props => [filter];
}

/// The first page is being read, with no rows to show meanwhile.
final class LanguageLinkListLoading extends LanguageLinkListState {
  const LanguageLinkListLoading(super.filter);
}

/// The server refused the read: the user's role may not see DataGateways.
final class LanguageLinkListDenied extends LanguageLinkListState {
  const LanguageLinkListDenied(super.filter);
}

/// The read failed for a reason that says nothing about access or about the
/// DataGateway. Retryable.
final class LanguageLinkListFailed extends LanguageLinkListState {
  const LanguageLinkListFailed(super.filter);
}

/// The DataGateway does not exist, or was deleted.
final class LanguageLinkListGone extends LanguageLinkListState {
  const LanguageLinkListGone(super.filter);
}

/// The links under [filter]: every page read so far.
final class LanguageLinkListReady extends LanguageLinkListState {
  const LanguageLinkListReady({
    required LanguageLinkFilter filter,
    required this.links,
    required this.hasMore,
    this.loadingMore = false,
    this.moreFailed = false,
    this.mayChange = true,
    this.busy = const {},
    this.outcome,
  }) : super(filter);

  /// In the server's order, by value. May be empty while [hasMore] is true,
  /// because an action takes its row off when the row leaves the filter.
  final List<LanguageLink> links;

  /// Whether the server has more links under [filter] past the ones shown.
  final bool hasMore;

  /// Whether the next page has been asked for and hasn't come: it is being
  /// read, or it is waiting for an action or a read to end first.
  final bool loadingMore;

  /// The last More failed. The rows shown are still right, and More can be
  /// tried again.
  final bool moreFailed;

  /// Whether to offer link, ignore and accept. False once the session has
  /// seen a change refused (#41).
  final bool mayChange;

  /// Ids of the links with an action in flight.
  final Set<String> busy;

  /// What the last action answered, until the user dismisses it or changes
  /// the filter, or another answers.
  final LanguageLinkOutcome? outcome;

  @override
  List<Object?> get props => [
    filter,
    links,
    hasMore,
    loadingMore,
    moreFailed,
    mayChange,
    busy,
    outcome,
  ];
}

/// How an action on a link ended, for the worklist's banner.
enum LanguageLinkOutcomeKind {
  /// Linked to the tag the user picked.
  linked,

  /// Ignored.
  ignored,

  /// Accepted: the server added the language where it had none, and linked
  /// the link to it.
  accepted,

  /// The server wouldn't accept the link: it was settled first, or it names
  /// no language the server knows. The list is read again, which shows where
  /// the link stands.
  conflict,

  /// The server has no tag with the id the user picked (a 400 from the API),
  /// most likely because it was removed after the picker listed it. Nothing
  /// changed.
  unknownTag,

  /// The user's role may not change DataGateways.
  refused,

  /// The link, or the DataGateway, is gone. The list is read again.
  gone,

  /// The request got no answer that says anything about the link. The change
  /// may have been made (#627).
  noAnswer,
}

/// The last action's outcome.
final class LanguageLinkOutcome extends Equatable {
  const LanguageLinkOutcome({
    required this.kind,
    required this.value,
    this.format = LanguageCodeFormat.unknown,
  });

  final LanguageLinkOutcomeKind kind;

  /// The link's value, as it was when the action started.
  final String value;

  /// How [value] is spelled, since a value can be listed once per format.
  final LanguageCodeFormat format;

  @override
  List<Object?> get props => [kind, value, format];
}
