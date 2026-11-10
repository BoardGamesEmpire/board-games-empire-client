import 'package:equatable/equatable.dart';
import 'package:models/domain.dart';

/// Events of `AdminHouseholdListBloc` (#685).
sealed class AdminHouseholdListEvent extends Equatable {
  const AdminHouseholdListEvent();

  @override
  List<Object?> get props => [];
}

/// Read the list from the server under the query it shows: on opening, on
/// retry, and on coming back into view. Rows already shown stay until it
/// answers. Put off while a search that asks something new waits out its
/// pause, since that search reads anew.
final class AdminHouseholdListLoadRequested extends AdminHouseholdListEvent {
  const AdminHouseholdListLoadRequested();
}

/// Read the next page and add it below the rows shown.
final class AdminHouseholdListMoreRequested extends AdminHouseholdListEvent {
  const AdminHouseholdListMoreRequested();
}

/// The search field now holds [text], as typed. It is read once typing
/// pauses.
final class AdminHouseholdListSearchChanged extends AdminHouseholdListEvent {
  const AdminHouseholdListSearchChanged(this.text);

  final String text;

  @override
  List<Object?> get props => [text];
}

/// Typing paused on [text]. Internal: the bloc sends it to itself once a
/// [AdminHouseholdListSearchChanged] has waited out its pause, so the read
/// that follows is not cut short by the next keystroke.
final class AdminHouseholdListSearchSettled extends AdminHouseholdListEvent {
  const AdminHouseholdListSearchSettled(this.text);

  final String text;

  @override
  List<Object?> get props => [text];
}

/// Show [status]'s households instead.
final class AdminHouseholdListStatusChanged extends AdminHouseholdListEvent {
  const AdminHouseholdListStatusChanged(this.status);

  final AdminHouseholdStatus status;

  @override
  List<Object?> get props => [status];
}

/// Order the list by [sort]. Dropped when the status shown doesn't allow it
/// (see [AdminHouseholdSort.allowedWith]).
final class AdminHouseholdListSortChanged extends AdminHouseholdListEvent {
  const AdminHouseholdListSortChanged(this.sort);

  final AdminHouseholdSort sort;

  @override
  List<Object?> get props => [sort];
}

/// Restore the deleted household [id]. The person has confirmed it by then.
final class AdminHouseholdListRestoreRequested extends AdminHouseholdListEvent {
  const AdminHouseholdListRestoreRequested(this.id);

  final String id;

  @override
  List<Object?> get props => [id];
}

/// The person closed the banner reporting the last restore.
final class AdminHouseholdListOutcomeDismissed extends AdminHouseholdListEvent {
  const AdminHouseholdListOutcomeDismissed();
}
