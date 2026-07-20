import 'package:app_shell/src/bootstrap/app_bootstrap_cubit.dart';
import 'package:app_shell/src/bootstrap/app_bootstrap_state.dart';
import 'package:app_shell/src/bootstrap/platform_bootstrap.dart';
import 'package:app_shell/src/deep_links/deep_link_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hydrated_bloc/hydrated_bloc.dart';
import 'package:interfaces/orchestration.dart';
import 'package:observability/observability.dart';

/// #97 drain-trigger contract:
///
/// - `onAuthenticated` fires `drainPending()` on **every** invocation,
///   before (and independently of) the state guard — sign-in and startup
///   restore arrive from [AppBootstrapNeedsAuth], but a server-switch
///   re-auth arrives while the cubit is already [AppBootstrapReady] and
///   must still drain the new server's queue.
/// - Fire-and-forget: a drain fault never surfaces into (or blocks) the
///   auth transition.
/// - No feedback service wired → no drain, and the state machine is
///   byte-for-byte the pre-#97 one.
void main() {
  AppBootstrapCubit cubit({FeedbackService? feedbackService}) =>
      AppBootstrapCubit(
        platformBootstrap: _UnusedPlatformBootstrap(),
        feedbackService: feedbackService,
      );

  group('AppBootstrapCubit feedback drain (#97)', () {
    test('onAuthenticated drains even when the state guard makes the '
        'transition a no-op (server-switch re-auth while Ready)', () async {
      final service = _RecordingFeedbackService();
      final c = cubit(feedbackService: service);
      addTearDown(c.close);

      // Initial state is AppBootstrapInitializing — not NeedsAuth, so
      // the emit is guarded off; the drain must fire anyway.
      c.onAuthenticated();

      expect(service.drainCalls, 1);
      expect(c.state, isA<AppBootstrapInitializing>());
    });

    test('drains on every authenticated signal, not just the '
        'first', () async {
      final service = _RecordingFeedbackService();
      final c = cubit(feedbackService: service);
      addTearDown(c.close);

      c.onAuthenticated();
      c.onAuthenticated();
      c.onAuthenticated();

      expect(service.drainCalls, 3);
    });

    test('a failing drain neither blocks nor breaks onAuthenticated '
        '(fire-and-forget)', () async {
      final service = _RecordingFeedbackService(
        error: StateError('sink exploded'),
      );
      final c = cubit(feedbackService: service);
      addTearDown(c.close);

      c.onAuthenticated();
      // Let the unawaited future reject; an unhandled rejection would
      // fail this test zone.
      await Future<void>.delayed(Duration.zero);

      expect(service.drainCalls, 1);
    });

    test('no feedback service wired → no drain, state machine '
        'untouched', () async {
      final c = cubit();
      addTearDown(c.close);

      expect(c.onAuthenticated, returnsNormally);
      expect(c.state, isA<AppBootstrapInitializing>());
    });
  });
}

class _RecordingFeedbackService implements FeedbackService {
  _RecordingFeedbackService({this.error});

  final Object? error;
  int drainCalls = 0;

  @override
  Future<int> drainPending() async {
    drainCalls++;
    if (error != null) throw error!;
    return 1;
  }

  @override
  FeedbackReport buildReport({
    required FeedbackCategory category,
    FeedbackSeverity? severity,
    String? title,
    String? errorMessage,
    String? stackTrace,
    String? userComment,
    String? correlationKey,
  }) => throw UnimplementedError();

  @override
  Future<FeedbackSubmitResult> submit(FeedbackReport report) =>
      throw UnimplementedError();
}

/// The cubit only stores this at construction; these tests never run the
/// bootstrap sequence, so every member is a loud contract tripwire.
class _UnusedPlatformBootstrap implements PlatformBootstrap {
  @override
  Future<DependencyContainer> createRootContainer() =>
      throw UnimplementedError();

  @override
  DeepLinkSource? createDeepLinkSource() => throw UnimplementedError();

  @override
  LogSink createLogSink() => throw UnimplementedError();

  @override
  Future<BootstrapResult> initialize() => throw UnimplementedError();

  @override
  bool get supportsReset => false;

  @override
  Future<void> reset() => throw UnimplementedError();

  @override
  Future<HydratedStorageDirectory> hydratedStorageDirectory() =>
      throw UnimplementedError();
}
