import 'package:bloc_test/bloc_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:server_onboarding/server_onboarding.dart';

/// The bloc double both widget suites drive.
///
/// Shared because everything here names the bloc's event and state types.
/// Held in each suite instead, a change to either shape is the same edit in
/// two files — and the drift shows up as one suite quietly testing an older
/// contract than the other.
class MockServerOnboardingBloc
    extends MockBloc<ServerOnboardingEvent, ServerOnboardingState>
    implements ServerOnboardingBloc {}

/// Registers the fallback `any` needs for `add`'s parameter type.
///
/// mocktail resolves fallbacks by `is T`, so this single value also serves
/// `any` at the base event type — which is the type `add` gives it.
///
/// It does **not** make `any` type-aware: mocktail's `any` is `anything`,
/// and the type argument filters nothing. Callers pass an explicit
/// `that: isA<…>()` to say which event they mean. Without it, a
/// `verifyNever` for a submit is satisfied by any dispatch at all.
void registerServerOnboardingFallbacks() {
  registerFallbackValue(const ServerOnboardingSubmitted(url: ''));
}

/// Parks [bloc] in [state] and emits nothing further.
void stubState(MockServerOnboardingBloc bloc, ServerOnboardingState state) {
  whenListen(
    bloc,
    const Stream<ServerOnboardingState>.empty(),
    initialState: state,
  );
}
