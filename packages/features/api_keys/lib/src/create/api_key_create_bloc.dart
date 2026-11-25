import 'package:api_keys/src/create/api_key_create_event.dart';
import 'package:api_keys/src/create/api_key_create_state.dart';
import 'package:api_keys/src/failure/api_key_failure.dart';
import 'package:api_keys/src/widgets/scope_picker.dart';
import 'package:bloc_concurrency/bloc_concurrency.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';

/// Drives the page that makes an API key (#1028): reads the permissions the
/// user may give one, and sends the create.
///
/// Nothing is stored. [ApiKeyCreateStarted] reads the grantable permissions,
/// which the form can't be drawn without, so a failed read is
/// [ApiKeyGrantableStatus.loadFailed] and starting again reads again.
///
/// ## The create
///
/// [ApiKeyCreateSubmitted] goes straight to the server: the page is
/// online-only. One is on its way at a time, in
/// [ApiKeyCreateState.submitting], and another meanwhile is dropped, as is
/// one before the permissions have loaded.
///
/// - One that goes through holds the key and its secret in
///   [ApiKeyCreateState.created]. Nothing is sent or read after that: the
///   page shows the secret until it closes, and the secret goes with this
///   bloc.
/// - One that fails keeps what the page had, with the
///   [ApiKeyCreateState.failure]. The next create retires it, and so does
///   [ApiKeyCreateFailureCleared].
/// - `confirmCritical` is sent only when the event carries it. When the
///   server refuses a create that didn't, saying it holds a Critical
///   permission, the permissions the form was built from are out of date:
///   they are read again before the failure is emitted, so that the page's
///   question can name what is Critical now. A failed read keeps the ones it
///   had.
///
/// The secret is never in an event, an exception or a message, and
/// [ApiKeyCreateState.toString] leaves it out.
class ApiKeyCreateBloc extends Bloc<ApiKeyCreateEvent, ApiKeyCreateState> {
  ApiKeyCreateBloc(this._remote) : super(const ApiKeyCreateState()) {
    on<ApiKeyCreateStarted>(_onStarted, transformer: restartable());
    on<ApiKeyCreateSubmitted>(_onSubmitted, transformer: droppable());
    on<ApiKeyCreateFailureCleared>(_onFailureCleared);
  }

  final ApiKeyRemoteDataSource _remote;

  Future<void> _onStarted(
    ApiKeyCreateStarted event,
    Emitter<ApiKeyCreateState> emit,
  ) async {
    // Reading again would take a create on its way, or the key it made, off
    // the page.
    if (state.submitting || state.created != null) return;
    // A bloc's first emit is not compared with its initial state, so the
    // spinner it starts on is not emitted again.
    if (state.grantableStatus != ApiKeyGrantableStatus.loading) {
      emit(const ApiKeyCreateState());
    }
    try {
      final grantable = await _remote.fetchGrantable();
      // A read asked for since has taken this one's place.
      if (emit.isDone) return;
      emit(
        ApiKeyCreateState(
          grantableStatus: ApiKeyGrantableStatus.loaded,
          grantable: grantable,
        ),
      );
    } on Object {
      if (emit.isDone) return;
      emit(
        const ApiKeyCreateState(
          grantableStatus: ApiKeyGrantableStatus.loadFailed,
        ),
      );
    }
  }

  Future<void> _onSubmitted(
    ApiKeyCreateSubmitted event,
    Emitter<ApiKeyCreateState> emit,
  ) async {
    if (state.grantableStatus != ApiKeyGrantableStatus.loaded ||
        state.submitting ||
        state.created != null) {
      return;
    }
    emit(state.copyWith(submitting: true, failure: () => null));
    try {
      final created = await _remote.create(
        ApiKeyCreate(
          name: event.name,
          grant: switch (event.selection) {
            EverythingScopes() => const ApiKeyEverythingGrant(),
            PickedScopes(:final scopes) => ApiKeyScopesGrant(scopes),
          },
          expiresInDays: event.days,
          confirmCritical: event.confirmCritical,
        ),
      );
      emit(state.copyWith(submitting: false, created: created));
    } on ApiKeyCriticalNeedsConfirmationException catch (error) {
      // Unconfirmed, the form found nothing Critical to ask about, and the
      // server did: what the form was built from has changed under it.
      final grantable = event.confirmCritical ? null : await _readGrantable();
      emit(
        state.copyWith(
          submitting: false,
          failure: () => apiKeyFailureOf(error),
          grantable: grantable,
        ),
      );
    } on Object catch (error) {
      emit(
        state.copyWith(
          submitting: false,
          failure: () => apiKeyFailureOf(error),
        ),
      );
    }
  }

  /// The permissions the user may give a key now, or null when the read
  /// fails. Never throws.
  Future<List<GrantablePermission>?> _readGrantable() async {
    try {
      return await _remote.fetchGrantable();
    } on Object {
      return null;
    }
  }

  void _onFailureCleared(
    ApiKeyCreateFailureCleared event,
    Emitter<ApiKeyCreateState> emit,
  ) {
    if (state.failure != null && !state.submitting) {
      emit(state.copyWith(failure: () => null));
    }
  }
}
