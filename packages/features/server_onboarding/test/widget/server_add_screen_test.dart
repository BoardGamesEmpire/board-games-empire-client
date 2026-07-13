import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:server_onboarding/server_onboarding.dart';

class _MockServerOnboardingBloc
    extends MockBloc<ServerOnboardingEvent, ServerOnboardingState>
    implements ServerOnboardingBloc {}

Widget _harness(ServerOnboardingBloc bloc) => MaterialApp(
  localizationsDelegates: ServerOnboardingLocalizations.localizationsDelegates,
  supportedLocales: ServerOnboardingLocalizations.supportedLocales,
  home: BlocProvider<ServerOnboardingBloc>.value(
    value: bloc,
    child: const ServerAddScreen(),
  ),
);

void main() {
  late _MockServerOnboardingBloc bloc;

  setUpAll(() {
    registerFallbackValue(const ServerOnboardingSubmitted(url: ''));
  });

  setUp(() {
    bloc = _MockServerOnboardingBloc();
    whenListen(
      bloc,
      const Stream<ServerOnboardingState>.empty(),
      initialState: const ServerOnboardingIdle(),
    );
  });

  group('ServerAddScreen', () {
    testWidgets('renders labeled URL and alias fields and a submit button '
        '(labels, never hint-only)', (tester) async {
      await tester.pumpWidget(_harness(bloc));

      expect(find.text('Server address'), findsOneWidget);
      expect(find.text('Nickname (optional)'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Connect'), findsOneWidget);
      // The screen title is a semantic header.
      expect(find.text('Add a Server'), findsOneWidget);
    });

    testWidgets('submit dispatches the raw field values', (tester) async {
      await tester.pumpWidget(_harness(bloc));

      await tester.enterText(find.byType(TextField).first, 'bge.example.com');
      await tester.enterText(find.byType(TextField).last, 'Home');
      await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
      await tester.pump();

      verify(
        () => bloc.add(
          const ServerOnboardingSubmitted(
            url: 'bge.example.com',
            alias: 'Home',
          ),
        ),
      ).called(1);
    });

    testWidgets('pressing done on the alias field submits from the '
        'keyboard', (tester) async {
      await tester.pumpWidget(_harness(bloc));

      await tester.enterText(find.byType(TextField).first, 'bge.example.com');
      await tester.enterText(find.byType(TextField).last, 'Home');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();

      verify(() => bloc.add(any<ServerOnboardingSubmitted>())).called(1);
    });

    testWidgets('disables (not hides) the submit control while in flight '
        'and shows progress', (tester) async {
      whenListen(
        bloc,
        const Stream<ServerOnboardingState>.empty(),
        initialState: const ServerOnboardingInProgress(),
      );
      await tester.pumpWidget(_harness(bloc));

      final button = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(button.onPressed, isNull);
      expect(find.text('Contacting server…'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('renders a localized failure message in a live region', (
      tester,
    ) async {
      whenListen(
        bloc,
        const Stream<ServerOnboardingState>.empty(),
        initialState: const ServerOnboardingOffline(),
      );
      await tester.pumpWidget(_harness(bloc));

      expect(find.text("Couldn't add server"), findsOneWidget);
      expect(
        find.text("You're offline. Connect to a network and try again."),
        findsOneWidget,
      );

      // The banner is announced: it sits under a Semantics widget with
      // liveRegion enabled. Asserted at the widget-tree level to stay
      // independent of SemanticsNode flag-API changes across Flutter
      // versions.
      expect(
        find.ancestor(
          of: find.text("Couldn't add server"),
          matching: find.byWidgetPredicate(
            (w) => w is Semantics && (w.properties.liveRegion ?? false),
          ),
        ),
        findsOneWidget,
      );
    });

    testWidgets('interpolates version-negotiation payloads', (tester) async {
      whenListen(
        bloc,
        const Stream<ServerOnboardingState>.empty(),
        initialState: const ServerOnboardingClientTooOld(
          clientVersion: '1.0.0',
          requiredMinimum: '2.0.0',
        ),
      );
      await tester.pumpWidget(_harness(bloc));

      expect(find.textContaining('2.0.0'), findsOneWidget);
      expect(find.textContaining('1.0.0'), findsOneWidget);
    });
  });
}
