import 'package:auth/src/sign_in_methods/sign_in_method_rows.dart';
import 'package:auth/src/sign_in_methods/sign_in_methods_event.dart';
import 'package:auth/src/sign_in_methods/sign_in_methods_state.dart';
import 'package:bloc_concurrency/bloc_concurrency.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:interfaces/repositories.dart';
import 'package:models/domain.dart' show OidcStrategy;

/// The state behind the Sign-in methods screen (#582): the user's methods,
/// the providers still open to link, and how the last link or unlink ended.
class SignInMethodsBloc extends Bloc<SignInMethodsEvent, SignInMethodsState> {
  SignInMethodsBloc({
    required AuthRepository repository,
    required this._strategies,
    required this._passwordSignInOffered,
    required this._returnPath,
  }) : _repository = repository,
       super(
         SignInMethodsState(
           status: SignInMethodsStatus.loading,
           linkSupported: repository.providerLinkSupported,
         ),
       ) {
    on<SignInMethodsRequested>(_onRequested);
    // One handler for both writes, so droppable gates them together: a link
    // and an unlink added before the screen rebuilds can't both go out.
    on<SignInMethodWriteRequested>(
      (event, emit) => switch (event) {
        SignInMethodLinkRequested() => _onLink(event, emit),
        SignInMethodUnlinkRequested() => _onUnlink(event, emit),
      },
      transformer: droppable(),
    );
    on<SignInMethodsOutcomeCleared>(
      (_, emit) => emit(state.copyWith(outcome: () => null)),
    );
  }

  final AuthRepository _repository;
  final List<OidcStrategy> _strategies;

  /// Whether the server's discovery offers email and password sign-in, so
  /// that a password counts as a way in.
  final bool _passwordSignInOffered;
  final String _returnPath;

  List<SignInMethod> _methods = const [];
  bool _returnTaken = false;

  Future<void> _onRequested(
    SignInMethodsRequested event,
    Emitter<SignInMethodsState> emit,
  ) async {
    // Take-once on the repository: only the first request reads it, so a
    // retry never shows the same result twice.
    if (!_returnTaken) {
      _returnTaken = true;
      final taken = _repository.takeProviderLinkReturn();
      if (taken != null) {
        emit(state.copyWith(outcome: () => _outcomeOfReturn(taken)));
      }
    }
    emit(state.copyWith(status: SignInMethodsStatus.loading));
    try {
      _methods = await _repository.listSignInMethods();
    } on Exception {
      // Any failure to read the list reads the same: retry. An Error is a
      // bug and escapes.
      if (emit.isDone) return;
      emit(state.copyWith(status: SignInMethodsStatus.loadFailed));
      return;
    }
    if (emit.isDone) return;
    emit(_loaded(state));
  }

  Future<void> _onLink(
    SignInMethodLinkRequested event,
    Emitter<SignInMethodsState> emit,
  ) async {
    final providerId = event.strategy.providerId;
    emit(
      state.copyWith(linkingProviderId: () => providerId, outcome: () => null),
    );
    try {
      await _repository.linkProvider(event.strategy, returnPath: _returnPath);
    } on AuthSupersededException {
      // The session changed while the link was starting. The screen is
      // rebuilt for the new session, so there is nothing to say.
      if (!emit.isDone) emit(state.copyWith(linkingProviderId: () => null));
      return;
    } on Exception catch (e) {
      if (emit.isDone) return;
      final (reason, retryAfter) = _reasonOf(e);
      emit(
        state.copyWith(
          linkingProviderId: () => null,
          outcome: () => SignInMethodLinkFailed(
            providerId,
            reason,
            retryAfter: retryAfter,
          ),
        ),
      );
      return;
    } on Object {
      // An Error (native's UnsupportedError, say) is a bug: let the line
      // stop being busy, then let it escape as AuthBloc does.
      if (!emit.isDone) emit(state.copyWith(linkingProviderId: () => null));
      rethrow;
    }
    // The page stayed, so the user stopped the link: no outcome.
    if (!emit.isDone) emit(state.copyWith(linkingProviderId: () => null));
  }

  Future<void> _onUnlink(
    SignInMethodUnlinkRequested event,
    Emitter<SignInMethodsState> emit,
  ) async {
    final row = event.row;
    emit(
      state.copyWith(unlinkingId: () => row.method.id, outcome: () => null),
    );
    try {
      await _repository.unlinkSignInMethod(row.method.id);
    } on Exception catch (e) {
      if (emit.isDone) return;
      final (reason, retryAfter) = _reasonOf(e);
      emit(
        state.copyWith(
          unlinkingId: () => null,
          outcome: () =>
              SignInMethodUnlinkFailed(reason, retryAfter: retryAfter),
        ),
      );
      return;
    } on Object {
      if (!emit.isDone) emit(state.copyWith(unlinkingId: () => null));
      rethrow;
    }

    try {
      _methods = await _repository.listSignInMethods();
    } on Exception {
      // The unlink worked, so keep that: drop the row here and keep the
      // screen loaded rather than turn a success into a load failure.
      _methods = [
        for (final m in _methods)
          if (m.id != row.method.id) m,
      ];
    }
    if (emit.isDone) return;
    emit(
      _loaded(
        state,
      ).copyWith(
        unlinkingId: () => null,
        outcome: () => SignInMethodUnlinked(row.label),
      ),
    );
  }

  SignInMethodsState _loaded(SignInMethodsState from) {
    final described = describeSignInMethods(
      _methods,
      _strategies,
      passwordSignInOffered: _passwordSignInOffered,
    );
    return from.copyWith(
      status: SignInMethodsStatus.loaded,
      rows: described.rows,
      linkable: described.linkable,
    );
  }

  SignInMethodsOutcome _outcomeOfReturn(ProviderLinkReturn r) => switch (r) {
    ProviderLinkSucceeded(:final providerId) => SignInMethodLinked(providerId),
    ProviderLinkFailed(:final providerId, :final failure) =>
      SignInMethodLinkFailed(providerId, failure.reason),
  };

  /// Maps what the repository threw to a reason, by type, never by text.
  /// Anything it does not name is generic.
  (ProviderLinkFailureReason, Duration?) _reasonOf(Exception e) => switch (e) {
    AuthProviderLinkException(:final reason) => (reason, null),
    AuthRateLimitedException(:final retryAfter) => (
      ProviderLinkFailureReason.rateLimited,
      retryAfter,
    ),
    AuthNetworkException() => (ProviderLinkFailureReason.network, null),
    _ => (ProviderLinkFailureReason.generic, null),
  };
}
