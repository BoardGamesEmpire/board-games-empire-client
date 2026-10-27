/// User search (#455, #499): the bloc that asks the server who matches what
/// is being typed, and the rows that show the answer.
///
/// Shared by the household invite form and the event create form's invitees,
/// and the one feature package another feature may depend on. The search
/// field and the pick are each form's own: this package never touches a form,
/// routing or DI. It exports its localizations because the forms take their
/// search field's label and hint from them, and `app_shell` registers the
/// delegate.
library;

export 'l10n/user_search_localizations.dart';

export 'src/user_search_bloc.dart';
export 'src/user_search_event.dart';
export 'src/user_search_result_list.dart';
export 'src/user_search_state.dart';
