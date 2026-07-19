import 'package:app_shell/app_shell.dart';
import 'package:feedback/feedback.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:observability/observability.dart';

/// Pinned (#107): the user-initiated feedback flow is ONE route with two
/// phases. Compose builds the report via `FeedbackService.buildReport`
/// (`message` → `userComment`, `errorMessage` null) and swaps in-place to
/// the shared [FeedbackReviewScreen] (#76); backing out of review — its
/// `BackButton` or system back via the route-level `PopScope` — restores
/// the compose step with the user's input intact; closing a terminal
/// outcome pops the route. Nothing is sent before the review surface's
/// send (#34 contract — exercised by the review screen's own suite).
void main() {
  late _RecordingFeedbackService service;

  setUp(() => service = _RecordingFeedbackService());

  /// Hosts the flow behind a launcher route so pop behavior is
  /// observable. Delegates mirror BgeApp's composition: the shell bundle
  /// (the review surface reads ShellLocalizations) plus the feedback
  /// feature's single delegate.
  Widget harness() => MaterialApp(
    localizationsDelegates: [
      ...ShellLocalizations.localizationsDelegates,
      FeedbackLocalizations.delegate,
    ],
    supportedLocales: ShellLocalizations.supportedLocales,
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => FeedbackFlowScreen(feedbackService: service),
              ),
            ),
            child: const Text('launch'),
          ),
        ),
      ),
    ),
  );

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(harness());
    await tester.tap(find.text('launch'));
    await tester.pumpAndSettle();
  }

  Future<void> pick(WidgetTester tester, Key field, String option) async {
    await tester.ensureVisible(find.byKey(field));
    await tester.tap(find.byKey(field));
    await tester.pumpAndSettle();
    await tester.tap(find.text(option).last);
    await tester.pumpAndSettle();
  }

  Future<void> composeValidBug(WidgetTester tester) async {
    await pick(tester, FeedbackComposeForm.severityFieldKey, 'High');
    await tester.enterText(
      find.byKey(FeedbackComposeForm.messageFieldKey),
      'it broke',
    );
    await tester.ensureVisible(find.byKey(FeedbackComposeForm.submitButtonKey));
    await tester.tap(find.byKey(FeedbackComposeForm.submitButtonKey));
    await tester.pump();
  }

  /// System back exactly as the platform delivers it — with a real route
  /// under the flow, this exercises the route-level PopScope.
  Future<void> systemBack(WidgetTester tester) async {
    final message = SystemChannels.navigation.codec.encodeMethodCall(
      const MethodCall('popRoute'),
    );
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      SystemChannels.navigation.name,
      message,
      (_) {},
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a valid compose submit builds the report (message → '
      'userComment) and swaps to the review surface in place', (tester) async {
    await open(tester);
    expect(find.byType(FeedbackComposeForm), findsOneWidget);

    await composeValidBug(tester);

    expect(find.byType(FeedbackReviewScreen), findsOneWidget);
    expect(find.byType(FeedbackComposeForm), findsNothing);
    expect(service.buildCalls, hasLength(1));
    final call = service.buildCalls.single;
    expect(call.category, FeedbackCategory.bug);
    expect(call.severity, FeedbackSeverity.high);
    expect(call.userComment, 'it broke');
    expect(call.errorMessage, isNull);
    expect(call.title, isNull);
  });

  testWidgets('the review BackButton returns to compose with the typed '
      'input intact', (tester) async {
    await open(tester);
    await composeValidBug(tester);

    await tester.tap(find.byKey(FeedbackReviewScreen.backButtonKey));
    await tester.pumpAndSettle();

    expect(find.byType(FeedbackComposeForm), findsOneWidget);
    expect(
      find.text('it broke'),
      findsOneWidget,
      reason: 'the host-owned form model preserves the round trip',
    );
  });

  testWidgets('system back on the review phase bounces to compose instead '
      'of popping the route; on compose it pops the route', (tester) async {
    await open(tester);
    await composeValidBug(tester);
    expect(find.byType(FeedbackReviewScreen), findsOneWidget);

    await systemBack(tester);
    expect(find.byType(FeedbackReviewScreen), findsNothing);
    expect(
      find.byType(FeedbackFlowScreen),
      findsOneWidget,
      reason: 'review-phase back is a phase change, not a route pop',
    );
    expect(find.text('it broke'), findsOneWidget);

    await systemBack(tester);
    expect(find.byType(FeedbackFlowScreen), findsNothing);
    expect(find.text('launch'), findsOneWidget);
  });

  testWidgets('sending then closing the terminal outcome pops the route', (
    tester,
  ) async {
    await open(tester);
    await composeValidBug(tester);

    await tester.tap(find.byKey(FeedbackReviewScreen.sendButtonKey));
    await tester.pump();
    await tester.pump();
    expect(
      find.byKey(FeedbackReviewScreen.sentConfirmationKey),
      findsOneWidget,
    );

    await tester.tap(find.byKey(FeedbackReviewScreen.closeButtonKey));
    await tester.pumpAndSettle();

    expect(find.byType(FeedbackFlowScreen), findsNothing);
    expect(find.text('launch'), findsOneWidget);
    expect(service.submitted, hasLength(1));
  });
}

/// Records buildReport arguments and materializes a minimal report so the
/// review surface can render; submit always reports sent.
class _RecordingFeedbackService implements FeedbackService {
  final List<_BuildCall> buildCalls = [];
  final List<FeedbackReport> submitted = [];

  @override
  FeedbackReport buildReport({
    required FeedbackCategory category,
    FeedbackSeverity? severity,
    String? title,
    String? errorMessage,
    String? stackTrace,
    String? userComment,
    String? correlationKey,
  }) {
    buildCalls.add(
      _BuildCall(
        category: category,
        severity: severity,
        title: title,
        errorMessage: errorMessage,
        userComment: userComment,
      ),
    );
    return FeedbackReport(
      category: category,
      severity: severity,
      message: userComment ?? errorMessage ?? 'message',
      title: title,
      correlationKey: 'stub-${buildCalls.length}',
    );
  }

  @override
  Future<FeedbackSubmitResult> submit(FeedbackReport report) async {
    submitted.add(report);
    return FeedbackSubmitResult.sent;
  }

  @override
  Future<int> drainPending() async => 0;
}

class _BuildCall {
  const _BuildCall({
    required this.category,
    required this.severity,
    required this.title,
    required this.errorMessage,
    required this.userComment,
  });

  final FeedbackCategory category;
  final FeedbackSeverity? severity;
  final String? title;
  final String? errorMessage;
  final String? userComment;
}
