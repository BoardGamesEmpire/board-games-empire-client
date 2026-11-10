import 'package:data_gateway/src/bloc/language_link_list_state.dart';
import 'package:equatable/equatable.dart';

/// Events of `LanguageLinkListBloc`.
sealed class LanguageLinkListEvent extends Equatable {
  const LanguageLinkListEvent();

  @override
  List<Object?> get props => [];
}

/// Read the first page under the filter shown: on opening, on retry, on a
/// refresh, and on coming back into view. The rows on screen stay while it
/// runs.
final class LanguageLinkListLoadRequested extends LanguageLinkListEvent {
  const LanguageLinkListLoadRequested();
}

/// The user chose [filter]: show its links instead, read afresh. Choosing the
/// filter already shown changes nothing.
final class LanguageLinkListFilterChanged extends LanguageLinkListEvent {
  const LanguageLinkListFilterChanged(this.filter);

  final LanguageLinkFilter filter;

  @override
  List<Object?> get props => [filter];
}

/// Read the next page and add it below the rows on screen.
final class LanguageLinkListMoreRequested extends LanguageLinkListEvent {
  const LanguageLinkListMoreRequested();
}

/// The user asked for [action] on the link [linkId].
///
/// A link sends [tagId], the tag the user picked, and one that names none is
/// dropped. The other actions don't read it.
final class LanguageLinkListActionRequested extends LanguageLinkListEvent {
  const LanguageLinkListActionRequested(this.action, this.linkId, {this.tagId});

  final LanguageLinkAction action;
  final String linkId;
  final String? tagId;

  @override
  List<Object?> get props => [action, linkId, tagId];
}

/// The user closed the banner reporting the last action.
final class LanguageLinkListOutcomeDismissed extends LanguageLinkListEvent {
  const LanguageLinkListOutcomeDismissed();
}

/// The caller's access changed under the screen: the session kept a new
/// answer (#456). Internal.
final class LanguageLinkListAccessChanged extends LanguageLinkListEvent {
  const LanguageLinkListAccessChanged();
}
