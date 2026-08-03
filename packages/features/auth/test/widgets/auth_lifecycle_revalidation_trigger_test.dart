import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:interfaces/repositories.dart';
import 'package:mocktail/mocktail.dart';
import 'package:models/dto.dart';

import 'package:auth/src/bloc/auth_bloc.dart';
import 'package:auth/src/bloc/auth_bloc_state.dart';
import 'package:auth/src/bloc/auth_event.dart';
import 'package:auth/src/widgets/auth_lifecycle_revalidation_trigger.dart';

class MockAuthBloc extends MockBloc<AuthEvent, AuthBlocState>
    implements AuthBloc {}

const _kChildKey = Key('trigger_child');

AuthResponse _session() => AuthResponse(
  token: 'tok-abc',
  user: AuthUser(
    id: 'u1',
    username: 'testuser',
    email: 'u1@example.com',
    emailVerified: true,
    createdAt: DateTime(2099),
    updatedAt: DateTime(2099),
  ),
  expiresAt: DateTime(2099).toUtc(),
);

/// Drives the real `flutter/lifecycle` platform channel rather than the
/// binding's `@protected` `handleAppLifecycleStateChanged`, matching the
/// idiom Flutter's own `AppLifecycleListener` tests use. This exercises the
/// same path the engine drives in production, including
/// `ServicesBinding`'s message parsing.
Future<void> _setLifecycleState(
  WidgetTester tester,
  AppLifecycleState state,
) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    SystemChannels.lifecycle.name,
    const StringCodec().encodeMessage(state.toString()),
    (_) {},
  );
  await tester.pump();
}

/// The full transition chain the engine emits for background → foreground.
///
/// [AppLifecycleListener] asserts on invalid transitions (`resumed` may
/// only follow `inactive`, `detached`, or nothing), so the cycle is driven
/// state by state rather than jumped. Driving all of it — instead of the
/// single `resumed` hop the issue sketched — is also the point: it proves
/// `onResume` fires exactly once across a realistic suspend/resume, not
/// once per lifecycle message.
Future<void> _suspendAndResume(WidgetTester tester) async {
  await _setLifecycleState(tester, AppLifecycleState.inactive);
  await _setLifecycleState(tester, AppLifecycleState.hidden);
  await _setLifecycleState(tester, AppLifecycleState.paused);
  // Back to the foreground: hidden (onRestart) → inactive (onShow) →
  // resumed (onResume).
  await _setLifecycleState(tester, AppLifecycleState.hidden);
  await _setLifecycleState(tester, AppLifecycleState.inactive);
  await _setLifecycleState(tester, AppLifecycleState.resumed);
}

/// Pins #141: app resume is a revalidation trigger alongside #98's
/// connectivity edge and periodic timer.
///
/// The eligibility rule — revalidate only an `unverifiedOffline` session —
/// is deliberately NOT asserted here. It lives in `AuthBloc`'s handler and
/// is covered by the bloc suite; this widget's contract is that it
/// dispatches on resume and nothing else, which is why the verified and
/// signed-out cases below expect a dispatch rather than silence.
void main() {
  setUpAll(() {
    registerFallbackValue(const AuthSessionCheckRequested());
    registerFallbackValue(const AuthInitial());
  });

  late MockAuthBloc mockBloc;

  setUp(() {
    mockBloc = MockAuthBloc();
    when(() => mockBloc.state).thenReturn(const AuthInitial());
  });

  Widget wrap(MockAuthBloc bloc) => BlocProvider<AuthBloc>.value(
    value: bloc,
    child: const AuthLifecycleRevalidationTrigger(
      child: SizedBox(key: _kChildKey),
    ),
  );

  /// Establishes a resumed baseline BEFORE the trigger mounts, so the
  /// listener seeds itself from a known state exactly as it does in
  /// production (where the app is already resumed when the shell builds).
  /// Without this the binding's initial lifecycle state is unset in tests
  /// and the first `resumed` message would read as a transition.
  Future<void> pumpTrigger(WidgetTester tester) async {
    await _setLifecycleState(tester, AppLifecycleState.resumed);
    await tester.pumpWidget(wrap(mockBloc));
  }

  group('AuthLifecycleRevalidationTrigger', () {
    testWidgets('renders its child unchanged and adds no chrome', (
      tester,
    ) async {
      await pumpTrigger(tester);

      expect(find.byKey(_kChildKey), findsOneWidget);
    });

    testWidgets('dispatches nothing on first build — mounting while already '
        'resumed is not a transition', (tester) async {
      await pumpTrigger(tester);

      verifyNever(() => mockBloc.add(any()));
    });

    testWidgets('dispatches exactly one revalidation across a full '
        'suspend/resume cycle', (tester) async {
      await pumpTrigger(tester);

      await _suspendAndResume(tester);

      verify(
        () => mockBloc.add(const AuthSessionRevalidationRequested()),
      ).called(1);
      // Revalidation, never the startup check — that one owns the gate's
      // splash and would yank a working user back to it (#98).
      verifyNever(() => mockBloc.add(const AuthSessionCheckRequested()));
    });

    testWidgets('dispatches on every subsequent resume, not just the first', (
      tester,
    ) async {
      await pumpTrigger(tester);

      await _suspendAndResume(tester);
      await _suspendAndResume(tester);

      verify(
        () => mockBloc.add(const AuthSessionRevalidationRequested()),
      ).called(2);
    });

    testWidgets('dispatches nothing while backgrounding — inactive, hidden '
        'and paused are not resume', (tester) async {
      await pumpTrigger(tester);

      await _setLifecycleState(tester, AppLifecycleState.inactive);
      await _setLifecycleState(tester, AppLifecycleState.hidden);
      await _setLifecycleState(tester, AppLifecycleState.paused);

      verifyNever(() => mockBloc.add(any()));
    });

    testWidgets('dispatches nothing after unmount — the listener is '
        'disposed with the widget', (tester) async {
      await pumpTrigger(tester);

      await tester.pumpWidget(const SizedBox());
      await _suspendAndResume(tester);

      verifyNever(() => mockBloc.add(any()));
    });

    group('dispatch is unconditional (the bloc owns eligibility)', () {
      testWidgets('dispatches for a verified session — the handler no-ops, '
          'not this widget', (tester) async {
        when(
          () => mockBloc.state,
        ).thenReturn(AuthAuthenticated(session: _session()));
        await pumpTrigger(tester);

        await _suspendAndResume(tester);

        verify(
          () => mockBloc.add(const AuthSessionRevalidationRequested()),
        ).called(1);
      });

      testWidgets('dispatches when signed out', (tester) async {
        when(() => mockBloc.state).thenReturn(const AuthUnauthenticated());
        await pumpTrigger(tester);

        await _suspendAndResume(tester);

        verify(
          () => mockBloc.add(const AuthSessionRevalidationRequested()),
        ).called(1);
      });

      testWidgets('dispatches for an unverified session — the case the '
          'trigger exists for', (tester) async {
        when(() => mockBloc.state).thenReturn(
          AuthAuthenticated(
            session: _session(),
            verification: SessionVerification.unverifiedOffline,
          ),
        );
        await pumpTrigger(tester);

        await _suspendAndResume(tester);

        verify(
          () => mockBloc.add(const AuthSessionRevalidationRequested()),
        ).called(1);
      });
    });
  });
}
