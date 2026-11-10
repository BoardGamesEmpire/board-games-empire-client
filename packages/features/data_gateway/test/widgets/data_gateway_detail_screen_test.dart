import 'dart:async';

import 'package:bge_test_support/access.dart';
import 'package:bge_test_support/widgets.dart';
import 'package:data_gateway/data_gateway.dart';
import 'package:data_gateway/l10n/data_gateway_localizations.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart' show ReadContext;
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/connectivity.dart';
import '../support/fake_data_gateway_remote.dart';
import '../support/screen_input.dart';

void main() {
  late FakeDataGatewayRemote remote;
  late FakeCallerAccessRepository access;

  /// A caller who may read DataGateways and not update them.
  final readOnly = FakeCallerAccessRepository.dataGateway(
    read: AccessExtent.all,
  );

  // Made from local times, so each reads the same on any machine, and held in
  // UTC, as the server sends them. In a year that has passed, so they read the
  // same next year too: only the tests of the year's rule work from today.
  final firstAt = DateTime(2025, 9, 1, 8, 30).toUtc();
  final lastAt = DateTime(2025, 10, 29, 12, 15).toUtc();
  final failedAt = DateTime(2025, 10, 30, 15, 4).toUtc();
  const first = 'Mon, Sep 1, 2025, 8:30 AM';
  const last = 'Wed, Oct 29, 2025, 12:15 PM';
  const failed = 'Thu, Oct 30, 2025, 3:04 PM';

  const search = DataGatewayCapabilities.search;
  const fetch = DataGatewayCapabilities.fetch;
  const languages = DataGatewayCapabilities.listLanguages;
  const platforms = DataGatewayCapabilities.listPlatforms;

  const writeOffSearch = 'setDisabledCapabilities(dg_1, [Search])';
  const interviewCall = 'interview(dg_1)';
  const refreshLabel = 'Read this data gateway again';

  final inUse = DataGatewayInterviewStatus(
    interviewed: true,
    firstInterviewedAt: firstAt,
    lastInterviewedAt: lastAt,
  );

  /// An enabled DataGateway in use that declares [search] and [languages],
  /// unless a test says otherwise.
  DataGateway row({
    String name = 'BGG',
    bool enabled = true,
    DataGatewayInterviewStatus? interview,
    List<String> capabilities = const [search, languages],
    List<String> disabled = const [],
    List<DataGatewaySection> sections = const [],
  }) => gateway('dg_1', name: name, enabled: enabled).copyWith(
    interview: interview ?? inUse,
    capabilities: capabilities,
    disabledCapabilities: disabled,
    sections: sections,
  );

  /// [inUse], with a later interview that failed with [code].
  DataGatewayInterviewStatus failing(DataGatewayInterviewFailureCode code) =>
      inUse.copyWith(
        failure: DataGatewayInterviewFailure(code: code, at: failedAt),
      );

  DataGatewayInterviewResult answered(DataGateway row, {bool ok = true}) =>
      DataGatewayInterviewResult(dataGateway: row, succeeded: ok);

  // Not skipping what is offstage, because to a finder a sliver scrolled out
  // of the viewport is, and the page is long.
  Finder capability(String name) => find.byKey(
    DataGatewayDetailScreen.capabilityKey(name),
    skipOffstage: false,
  );
  Finder section(String name) =>
      find.byKey(DataGatewayDetailScreen.sectionKey(name), skipOffstage: false);
  final statusLine = find.byKey(
    DataGatewayDetailScreen.statusKey,
    skipOffstage: false,
  );
  final interviewButton = find.byKey(
    DataGatewayDetailScreen.interviewKey,
    skipOffstage: false,
  );
  final refreshButton = find.byKey(DataGatewayDetailScreen.refreshKey);
  final banner = find.byKey(
    DataGatewayDetailScreen.outcomeKey,
    skipOffstage: false,
  );

  /// [text] in the app bar's title. The name heads the page too.
  Finder titled(String text) =>
      find.descendant(of: find.byType(AppBar), matching: find.text(text));

  SwitchListTile tile(WidgetTester tester, String name) =>
      tester.widget<SwitchListTile>(capability(name));

  Finder textIn(Finder parent, String text) => find.descendant(
    of: parent,
    matching: find.text(text, skipOffstage: false),
    skipOffstage: false,
  );

  setUp(() {
    remote = FakeDataGatewayRemote();
    // A caller who may read and update DataGateways: everything this screen
    // offers.
    access = FakeCallerAccessRepository(
      FakeCallerAccessRepository.dataGateway(
        read: AccessExtent.all,
        update: AccessExtent.all,
      ),
    );
    // The language worklist under the capabilities has its own tests. Here it
    // is empty, so it reads as the one line it is.
    remote.onFetchLanguageLinks = (_, _, _, _) async => linkPageOf(const []);
  });

  /// [textScaler] null leaves the view's own scale. The `MediaQuery` goes in
  /// only for what a test sets.
  Widget app(
    Widget home, {
    TextScaler? textScaler,
    bool alwaysUse24HourFormat = false,
    ValueListenable<bool>? offline,
    ThemeData? theme,
  }) {
    final TransitionBuilder? scaled =
        textScaler == null && !alwaysUse24HourFormat
        ? null
        : (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: textScaler,
              alwaysUse24HourFormat: alwaysUse24HourFormat,
            ),
            child: child!,
          );
    return MaterialApp(
      theme: theme ?? BgeTheme.light(),
      localizationsDelegates: DataGatewayLocalizations.localizationsDelegates,
      supportedLocales: DataGatewayLocalizations.supportedLocales,
      builder: offline == null
          ? scaled
          : connectivityBuilder(offline, inner: scaled),
      home: home,
    );
  }

  Future<void> pumpScreen(
    WidgetTester tester, {
    TextScaler? textScaler,
    bool alwaysUse24HourFormat = false,
    ValueListenable<bool>? offline,
  }) async {
    await tester.pumpWidget(
      app(
        DataGatewayDetailScreen(remote: remote, id: 'dg_1', access: access),
        textScaler: textScaler,
        alwaysUse24HourFormat: alwaysUse24HourFormat,
        offline: offline,
      ),
    );
    await tester.pumpAndSettle();
  }

  ScrollPosition page0(WidgetTester tester) =>
      tester.state<ScrollableState>(find.byType(Scrollable).first).position;

  Iterable<String> writes() =>
      remote.calls.where((call) => call.startsWith('setDisabledCapabilities'));
  Iterable<String> reads() =>
      remote.calls.where((call) => call.startsWith('fetchOne'));

  group('the status and the interview', () {
    testWidgets('shows the interview status and a current failure', (
      tester,
    ) async {
      remote.onFetchOne = (_) async =>
          row(interview: failing(DataGatewayInterviewFailureCode.pingFailed));

      await pumpScreen(tester);

      expect(titled('BGG'), findsOneWidget);
      expect(find.text('Enabled'), findsOneWidget);
      expect(
        textIn(statusLine, "Last interview failed: it didn't answer"),
        findsOneWidget,
      );
      expect(find.text('First interviewed $first'), findsOneWidget);
      expect(find.text('Last interviewed $last'), findsOneWidget);
      expect(
        find.text("Last failure $failed: it didn't answer"),
        findsOneWidget,
      );
      expect(find.text('Not interviewed yet'), findsNothing);
    });

    testWidgets('a failure is an icon and words, not color alone', (
      tester,
    ) async {
      remote.onFetchOne = (_) async => row(
        interview: failing(DataGatewayInterviewFailureCode.describeFailed),
      );

      await pumpScreen(tester);

      final line = find.ancestor(
        of: find.text("Last failure $failed: it couldn't describe itself"),
        matching: find.byType(Row),
      );
      expect(
        find.descendant(of: line, matching: find.byType(Icon)),
        findsOneWidget,
      );
    });

    for (final (state, interview, icon, colorOf)
        in <
          (
            String,
            DataGatewayInterviewStatus,
            IconData,
            Color Function(ColorScheme),
          )
        >[
          (
            'interviewed, so still in use',
            inUse.copyWith(
              failure: DataGatewayInterviewFailure(
                code: DataGatewayInterviewFailureCode.pingFailed,
                at: failedAt,
              ),
            ),
            Icons.warning_amber,
            (scheme) => scheme.tertiary,
          ),
          (
            'not interviewed, so not in use',
            DataGatewayInterviewStatus(
              failure: DataGatewayInterviewFailure(
                code: DataGatewayInterviewFailureCode.pingFailed,
                at: failedAt,
              ),
            ),
            Icons.error_outline,
            (scheme) => scheme.error,
          ),
        ]) {
      testWidgets("the failure line takes the status line's tone: $state", (
        tester,
      ) async {
        remote.onFetchOne = (_) async => row(interview: interview);

        await pumpScreen(tester);

        final words = find.text("Last failure $failed: it didn't answer");
        final line = find.ancestor(of: words, matching: find.byType(Row));
        final lineIcon = tester.widget<Icon>(
          find.descendant(of: line, matching: find.byType(Icon)),
        );
        final statusIcon = tester.widget<Icon>(
          find.descendant(of: statusLine, matching: find.byType(Icon)),
        );
        final color = colorOf(Theme.of(tester.element(statusLine)).colorScheme);

        expect(lineIcon.icon, icon);
        expect(lineIcon.color, color);
        expect(tester.widget<Text>(words).style?.color, color);
        // And the status line above it says the same.
        expect(statusIcon.icon, icon);
        expect(statusIcon.color, color);
      });
    }

    testWidgets('a DataGateway no interview has succeeded for says so, and '
        'shows the failure too', (tester) async {
      remote.onFetchOne = (_) async => row(
        interview: DataGatewayInterviewStatus(
          failure: DataGatewayInterviewFailure(
            code: DataGatewayInterviewFailureCode.pingFailed,
            at: failedAt,
          ),
        ),
      );

      await pumpScreen(tester);

      expect(find.text('Not interviewed yet'), findsOneWidget);
      expect(
        textIn(statusLine, "Not in use: it didn't answer"),
        findsOneWidget,
      );
      expect(
        find.text("Last failure $failed: it didn't answer"),
        findsOneWidget,
      );
      expect(find.textContaining('First interviewed'), findsNothing);
      expect(find.textContaining('Last interviewed'), findsNothing);
    });

    testWidgets('a date in the current year shows no year', (tester) async {
      final loaded = DateTime(DateTime.now().year, 3, 5, 15, 4).toUtc();
      remote.onFetchOne = (_) async => row(
        capabilities: const [languages],
        sections: [
          DataGatewaySection(capability: languages, lastLoadedAt: loaded),
        ],
      );

      await pumpScreen(tester);

      // The weekday moves with the year. Anchored, so a year anywhere fails it.
      expect(
        find.textContaining(RegExp(r'^Last loaded \w{3}, Mar 5, 3:04 PM$')),
        findsOneWidget,
      );
    });

    for (final (other, years) in [('last', -1), ('next', 1)]) {
      testWidgets('a date in another year shows it: $other year', (
        tester,
      ) async {
        final year = DateTime.now().year + years;
        remote.onFetchOne = (_) async => row(
          capabilities: const [languages],
          sections: [
            DataGatewaySection(
              capability: languages,
              lastLoadedAt: DateTime(year, 3, 5, 15, 4).toUtc(),
            ),
          ],
        );

        await pumpScreen(tester);

        expect(
          find.textContaining(
            RegExp('^Last loaded \\w{3}, Mar 5, $year, 3:04 PM\$'),
          ),
          findsOneWidget,
        );
      });
    }

    testWidgets('times follow the clock the user set', (tester) async {
      remote.onFetchOne = (_) async =>
          row(interview: failing(DataGatewayInterviewFailureCode.pingFailed));

      await pumpScreen(tester, alwaysUse24HourFormat: true);

      expect(
        find.text("Last failure Thu, Oct 30, 2025, 15:04: it didn't answer"),
        findsOneWidget,
      );
    });

    testWidgets('the badge heads the status, then the interview, the lists '
        'and the capabilities come in that order', (tester) async {
      tester.view
        ..devicePixelRatio = 1
        ..physicalSize = const Size(800, 2000);
      addTearDown(tester.view.reset);
      remote.onFetchOne = (_) async => row();

      await pumpScreen(tester);

      final tops = [
        find.text('Enabled'),
        statusLine,
        find.text('Interview'),
        interviewButton,
        find.text('Lists'),
        section(languages),
        find.text('Capabilities'),
        capability(search),
      ].map((finder) => tester.getTopLeft(finder).dy).toList();
      expect(tops, [...tops]..sort());
      expect(tops.toSet(), hasLength(tops.length));
    });

    testWidgets('each section heading is announced as a heading', (
      tester,
    ) async {
      remote.onFetchOne = (_) async => row();

      await pumpScreen(tester);

      for (final heading in ['Interview', 'Lists', 'Capabilities']) {
        await tester.ensureVisible(find.text(heading, skipOffstage: false));
        await tester.pump();
        expect(
          tester.getSemantics(find.text(heading)),
          isSemantics(isHeader: true, label: heading),
        );
      }
    });

    testWidgets('a disabled DataGateway says so, and offers no interview', (
      tester,
    ) async {
      remote.onFetchOne = (_) async => row(
        enabled: false,
        interview: failing(DataGatewayInterviewFailureCode.pingFailed),
      );

      await pumpScreen(tester);

      expect(find.text('Disabled'), findsOneWidget);
      expect(find.byIcon(Icons.do_not_disturb_on_outlined), findsOneWidget);
      expect(find.text('Interview again'), findsNothing);
      // The status line builds nothing here, and the badge says why.
      expect(statusLine, findsNothing);
      expect(find.textContaining('Last interview failed'), findsNothing);
      // The interview's history stays: it is still true.
      expect(find.text('First interviewed $first'), findsOneWidget);
      expect(
        find.text("Last failure $failed: it didn't answer"),
        findsOneWidget,
      );
    });

    testWidgets('interview again is hidden on a disabled DataGateway', (
      tester,
    ) async {
      var reads = 0;
      remote.onFetchOne = (_) async => row(enabled: ++reads > 1);

      await pumpScreen(tester);
      expect(interviewButton, findsNothing);

      await press(tester, refreshButton);
      await tester.pumpAndSettle();
      expect(interviewButton, findsOneWidget);
    });

    group(
      'when the focused interview button goes because the row is disabled',
      () {
        Future<void> focusTheButton(WidgetTester tester) async {
          await tester.ensureVisible(interviewButton);
          await tester.pumpAndSettle();
          await focusOn(tester, textIn(interviewButton, 'Interview again'));
          expect(focusIsIn(tester, interviewButton), isTrue);
        }

        testWidgets('after an interview it refused, focus goes to the '
            "banner's Dismiss", (tester) async {
          var reads = 0;
          remote.onFetchOne = (_) async => row(enabled: ++reads == 1);
          remote.onInterview = (_) async =>
              throw const DataGatewayConflictException(
                'disabled',
                statusCode: 409,
              );
          await pumpScreen(tester);
          await focusTheButton(tester);

          await tester.sendKeyEvent(LogicalKeyboardKey.space);
          await tester.pumpAndSettle();

          expect(interviewButton, findsNothing);
          expect(
            focusIsIn(
              tester,
              find.descendant(
                of: banner,
                matching: find.byType(TextButton),
                skipOffstage: false,
              ),
            ),
            isTrue,
          );
        });

        testWidgets('after a read, with no banner, focus goes to the first '
            'switch', (tester) async {
          var reads = 0;
          remote.onFetchOne = (_) async => row(enabled: ++reads == 1);
          await pumpScreen(tester);
          await focusTheButton(tester);

          // A click focuses nothing.
          await tester.tap(refreshButton);
          await tester.pumpAndSettle();

          expect(interviewButton, findsNothing);
          expect(focusIsIn(tester, capability(search)), isTrue);
        });

        testWidgets('with no switch either, focus goes to refresh', (
          tester,
        ) async {
          var reads = 0;
          remote.onFetchOne = (_) async =>
              row(enabled: ++reads == 1, capabilities: const []);
          await pumpScreen(tester);
          await focusTheButton(tester);

          await tester.tap(refreshButton);
          await tester.pumpAndSettle();

          expect(interviewButton, findsNothing);
          expect(focusIsIn(tester, refreshButton), isTrue);
        });

        testWidgets('with focus elsewhere, it stays there', (tester) async {
          var reads = 0;
          remote.onFetchOne = (_) async => row(enabled: ++reads == 1);
          await pumpScreen(tester);
          await tester.ensureVisible(capability(languages));
          await tester.pumpAndSettle();
          await focusOn(
            tester,
            textIn(capability(languages), 'List languages'),
          );

          await tester.tap(refreshButton);
          await tester.pumpAndSettle();

          expect(focusIsIn(tester, capability(languages)), isTrue);
        });
      },
    );

    testWidgets('a focused switch moves on when access falls, which stops '
        'it', (tester) async {
      remote.onFetchOne = (_) async => row();
      await pumpScreen(tester);
      await tester.ensureVisible(capability(search));
      await tester.pumpAndSettle();
      await focusOn(tester, textIn(capability(search), 'Search'));

      access.current = readOnly;
      await tester.pumpAndSettle();

      expect(tile(tester, search).onChanged, isNull);
      expect(focusIsIn(tester, refreshButton), isTrue);
    });

    for (final (control, label) in [
      ('switch', 'Search'),
      ('interview button', 'Interview again'),
    ]) {
      testWidgets('a focused $control keeps focus when update falls and comes '
          'back before the next frame', (tester) async {
        final mayUpdate = access.current;
        remote.onFetchOne = (_) async => row();
        await pumpScreen(tester);
        final (target, kept) = control == 'switch'
            ? (textIn(capability(search), label), capability(search))
            : (textIn(interviewButton, label), interviewButton);
        await tester.ensureVisible(target);
        await tester.pumpAndSettle();
        await focusOn(tester, target);

        // Each answer reaches the screen, but no frame is drawn between them.
        access.current = readOnly;
        await tester.binding.delayed(Duration.zero);
        access.current = mayUpdate;
        await tester.binding.delayed(Duration.zero);
        await tester.pumpAndSettle();

        expect(focusIsIn(tester, kept), isTrue);
      });
    }

    testWidgets('focus the user moves before the interview button goes stays '
        'where they put it', (tester) async {
      remote.onFetchOne = (_) async => row();
      remote.onInterview = (_) async => throw forbidden();
      await pumpScreen(tester);
      await focusOn(tester, textIn(interviewButton, 'Interview again'));
      // A refusal, so the hand-off would go to its banner's Dismiss.
      await pressKey(tester);
      await tester.pumpAndSettle();
      expect(banner, findsOneWidget);
      expect(focusIsIn(tester, interviewButton), isTrue);

      access.current = readOnly;
      // The answer reaches the screen, and the user moves on before the
      // frame that takes the button away.
      await tester.binding.delayed(Duration.zero);
      Focus.of(
        tester.element(
          find.descendant(of: refreshButton, matching: find.byType(Icon)),
        ),
      ).requestFocus();
      await tester.binding.delayed(Duration.zero);
      await tester.pumpAndSettle();

      expect(interviewButton, findsNothing);
      expect(focusIsIn(tester, refreshButton), isTrue);
    });

    testWidgets('with the outcome dismissed before the next frame, focus goes '
        'on past the Dismiss that frame takes away', (tester) async {
      remote.onFetchOne = (_) async => row();
      remote.onInterview = (_) async => throw forbidden();
      await pumpScreen(tester);
      await focusOn(tester, textIn(interviewButton, 'Interview again'));
      await pressKey(tester);
      await tester.pumpAndSettle();
      expect(banner, findsOneWidget);
      expect(focusIsIn(tester, interviewButton), isTrue);

      // The answer reaches the screen, and a click dismisses the banner
      // before the frame that takes the button away. A click focuses nothing.
      access.current = readOnly;
      await tester.binding.delayed(Duration.zero);
      tester
          .element(interviewButton)
          .read<DataGatewayDetailBloc>()
          .add(const DataGatewayDetailOutcomeDismissed());
      await tester.binding.delayed(Duration.zero);
      await tester.pumpAndSettle();

      expect(banner, findsNothing);
      expect(interviewButton, findsNothing);
      expect(focusIsIn(tester, refreshButton), isTrue);
    });

    testWidgets('a focused switch moves on when update falls and comes back '
        'before the next frame with an interview started, which stops it', (
      tester,
    ) async {
      final mayUpdate = access.current;
      final interview = Completer<DataGatewayInterviewResult>();
      remote.onFetchOne = (_) async => row();
      remote.onInterview = (_) => interview.future;
      await pumpScreen(tester);
      await tester.ensureVisible(capability(search));
      await tester.pumpAndSettle();
      await focusOn(tester, textIn(capability(search), 'Search'));

      // Each answer reaches the screen, and a click on Interview again
      // lands, but no frame is drawn between them. A click focuses nothing.
      final bloc = tester
          .element(interviewButton)
          .read<DataGatewayDetailBloc>();
      access.current = readOnly;
      await tester.binding.delayed(Duration.zero);
      access.current = mayUpdate;
      await tester.binding.delayed(Duration.zero);
      bloc.add(const DataGatewayDetailInterviewRequested());
      await tester.binding.delayed(Duration.zero);
      await tester.pumpAndSettle();

      expect(tile(tester, search).onChanged, isNull);
      expect(focusIsIn(tester, interviewButton), isTrue);

      interview.complete(answered(row()));
      await tester.pumpAndSettle();
    });

    testWidgets('interview again shows busy, then the banner', (tester) async {
      final interview = Completer<DataGatewayInterviewResult>();
      remote.onFetchOne = (_) async => row();
      remote.onInterview = (_) => interview.future;
      await pumpScreen(tester);

      expect(
        tester.getSemantics(find.text('Interview again')),
        isSemantics(
          isButton: true,
          isLiveRegion: false,
          label: 'Interview again',
        ),
      );

      await press(tester, interviewButton);

      expect(remote.calls, contains(interviewCall));
      expect(find.text('Interviewing…'), findsOneWidget);
      expect(find.text('Interview again'), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(banner, findsNothing);
      expect(
        tester.getSemantics(find.text('Interviewing…')),
        isSemantics(isButton: true, isLiveRegion: true, label: 'Interviewing…'),
      );

      interview.complete(answered(row()));
      await tester.pumpAndSettle();

      expect(find.text('Interview again'), findsOneWidget);
      expect(find.text('Interviewing…'), findsNothing);
      expect(
        find.text(
          'Interview finished. Its lists load over the next few minutes.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a focused interview button keeps focus while it runs, and a '
        'press sends nothing', (tester) async {
      final interview = Completer<DataGatewayInterviewResult>();
      remote.onFetchOne = (_) async => row();
      remote.onInterview = (_) => interview.future;
      await pumpScreen(tester);

      await focusOn(tester, textIn(interviewButton, 'Interview again'));
      expect(focusIsIn(tester, interviewButton), isTrue);

      await pressKey(tester);

      expect(find.text('Interviewing…'), findsOneWidget);
      expect(
        tester.widget<ButtonStyleButton>(interviewButton).onPressed,
        isNotNull,
      );
      expect(focusIsIn(tester, interviewButton), isTrue);

      await pressKey(tester);
      await press(tester, interviewButton);

      expect(remote.calls.where((c) => c == interviewCall), hasLength(1));
      expect(focusIsIn(tester, interviewButton), isTrue);

      // And through what the interview answers: the banner arrives in the
      // footer, and must not take the button's place in the tree.
      interview.complete(answered(row()));
      await tester.pumpAndSettle();

      expect(banner, findsOneWidget);
      expect(focusIsIn(tester, interviewButton), isTrue);
    });

    testWidgets('the switches stop taking presses during an interview, and '
        'take them again after it', (tester) async {
      final interview = Completer<DataGatewayInterviewResult>();
      remote.onFetchOne = (_) async => row();
      remote.onInterview = (_) => interview.future;
      await pumpScreen(tester);
      expect(tile(tester, search).onChanged, isNotNull);

      await press(tester, interviewButton);

      expect(tile(tester, search).onChanged, isNull);
      expect(tile(tester, languages).onChanged, isNull);

      interview.complete(answered(row()));
      await tester.pumpAndSettle();

      expect(tile(tester, search).onChanged, isNotNull);
      expect(tile(tester, languages).onChanged, isNotNull);
    });
  });

  group('the lists', () {
    testWidgets('a declared list with no section reads as not loaded yet, not '
        'as a failure', (tester) async {
      remote.onFetchOne = (_) async => row(capabilities: const [languages]);

      await pumpScreen(tester);

      expect(textIn(section(languages), 'List languages'), findsOneWidget);
      expect(textIn(section(languages), 'Not loaded yet'), findsOneWidget);
      expect(find.textContaining('Failed'), findsNothing);
      expect(
        find.descendant(of: section(languages), matching: find.byType(Icon)),
        findsNothing,
      );
    });

    testWidgets('a switched-off list keeps its row, which says so in place of '
        'how it last loaded', (tester) async {
      remote.onFetchOne = (_) async => row(
        capabilities: const [languages, platforms],
        disabled: const [platforms],
        sections: [
          DataGatewaySection(
            capability: platforms,
            lastLoadedAt: lastAt,
            failure: DataGatewaySectionFailure(
              code: DataGatewaySectionFailureCode.listFailed,
              at: failedAt,
            ),
          ),
        ],
      );

      await pumpScreen(tester);

      expect(textIn(section(languages), 'Not loaded yet'), findsOneWidget);
      expect(textIn(section(platforms), 'Switched off'), findsOneWidget);
      expect(textIn(section(platforms), 'Last loaded $last'), findsNothing);
      expect(find.textContaining('Failed'), findsNothing);
      expect(
        find.descendant(of: section(platforms), matching: find.byType(Icon)),
        findsNothing,
      );
      // Its switch stays, so it can be switched back on.
      expect(capability(platforms), findsOneWidget);
    });

    testWidgets('switching a list off or on moves no switch', (tester) async {
      // Long enough to scroll the switches to the middle of the view. At the
      // end of a short page the scroll offset clamps, and hides a shift.
      remote.onFetchLanguageLinks = (_, _, _, _) async => linkPageOf([
        for (var i = 0; i < 20; i++) languageLink('l$i', value: 'Value $i'),
      ]);
      const declared = [search, languages, platforms];
      remote.onFetchOne = (_) async => row(capabilities: declared);
      remote.onSetDisabledCapabilities = (_, disabled) async =>
          changed(row(capabilities: declared, disabled: disabled));
      await pumpScreen(tester);
      await Scrollable.ensureVisible(
        tester.element(capability(languages)),
        alignment: 0.5,
      );
      await tester.pumpAndSettle();
      List<double> tops() => [
        for (final name in declared) tester.getTopLeft(capability(name)).dy,
      ];
      final before = tops();

      await tester.tap(capability(languages));
      await tester.pumpAndSettle();

      expect(tile(tester, languages).value, isFalse);
      expect(tops(), before);

      await tester.tap(capability(languages));
      await tester.pumpAndSettle();

      expect(tile(tester, languages).value, isTrue);
      expect(tops(), before);
      expect(writes(), [
        'setDisabledCapabilities(dg_1, [$languages])',
        'setDisabledCapabilities(dg_1, [])',
      ]);
    });

    testWidgets('a loaded list says when', (tester) async {
      remote.onFetchOne = (_) async => row(
        capabilities: const [languages],
        sections: [
          DataGatewaySection(capability: languages, lastLoadedAt: lastAt),
        ],
      );

      await pumpScreen(tester);

      expect(textIn(section(languages), 'Last loaded $last'), findsOneWidget);
      expect(textIn(section(languages), 'Not loaded yet'), findsNothing);
      expect(
        find.descendant(of: section(languages), matching: find.byType(Icon)),
        findsNothing,
      );
    });

    for (final code in DataGatewaySectionFailureCode.values) {
      final reason = switch (code) {
        DataGatewaySectionFailureCode.listUnsupported =>
          "it doesn't offer this list",
        DataGatewaySectionFailureCode.listFailed => "it couldn't send the list",
        DataGatewaySectionFailureCode.linkFailed =>
          "the server couldn't save the list",
        DataGatewaySectionFailureCode.unknown => 'something went wrong',
      };

      testWidgets('a section that failed with ${code.name} says "$reason", '
          'with an icon', (tester) async {
        remote.onFetchOne = (_) async => row(
          capabilities: const [languages],
          sections: [
            DataGatewaySection(
              capability: languages,
              failure: DataGatewaySectionFailure(code: code, at: failedAt),
            ),
          ],
        );

        await pumpScreen(tester);

        expect(
          textIn(section(languages), 'Failed $failed: $reason'),
          findsOneWidget,
        );
        expect(textIn(section(languages), 'Not loaded yet'), findsNothing);
        expect(
          find.descendant(
            of: section(languages),
            matching: find.byIcon(Icons.error_outline),
          ),
          findsOneWidget,
        );
      });
    }

    testWidgets('a section with a load and a failure shows both lines', (
      tester,
    ) async {
      remote.onFetchOne = (_) async => row(
        capabilities: const [languages],
        sections: [
          DataGatewaySection(
            capability: languages,
            lastLoadedAt: lastAt,
            failure: DataGatewaySectionFailure(
              code: DataGatewaySectionFailureCode.listFailed,
              at: failedAt,
            ),
          ),
        ],
      );

      await pumpScreen(tester);

      expect(textIn(section(languages), 'Last loaded $last'), findsOneWidget);
      expect(
        textIn(section(languages), "Failed $failed: it couldn't send the list"),
        findsOneWidget,
      );
    });

    testWidgets('a section row is one stop for a screen reader', (
      tester,
    ) async {
      remote.onFetchOne = (_) async => row(
        capabilities: const [languages],
        sections: [
          DataGatewaySection(
            capability: languages,
            lastLoadedAt: lastAt,
            failure: DataGatewaySectionFailure(
              code: DataGatewaySectionFailureCode.listFailed,
              at: failedAt,
            ),
          ),
        ],
      );

      await pumpScreen(tester);
      await tester.ensureVisible(section(languages));
      await tester.pump();

      expect(
        tester.getSemantics(textIn(section(languages), 'List languages')),
        isSemantics(
          label:
              'List languages\nLast loaded $last\n'
              "Failed $failed: it couldn't send the list",
        ),
      );
    });

    testWidgets('a DataGateway with no list to load says so', (tester) async {
      remote.onFetchOne = (_) async => row(capabilities: const [search]);

      await pumpScreen(tester);

      expect(find.text("It doesn't list anything yet"), findsOneWidget);
    });
  });

  group('the capabilities', () {
    const labels = {
      DataGatewayCapabilities.search: 'Search',
      DataGatewayCapabilities.fetch: 'Fetch game details',
      DataGatewayCapabilities.fetchExpansions: 'Fetch expansions',
      DataGatewayCapabilities.listLanguages: 'List languages',
      DataGatewayCapabilities.listPlatforms: 'List platforms',
      DataGatewayCapabilities.listCategories: 'List categories',
      DataGatewayCapabilities.listMechanics: 'List mechanics',
    };

    testWidgets('each capability is a switch, on unless switched off', (
      tester,
    ) async {
      remote.onFetchOne = (_) async => row(
        capabilities: DataGatewayCapabilities.known,
        disabled: const [fetch],
      );

      await pumpScreen(tester);

      expect(labels.keys, DataGatewayCapabilities.known);
      for (final MapEntry(key: name, value: label) in labels.entries) {
        expect(textIn(capability(name), label), findsOneWidget);
        expect(tile(tester, name).value, name != fetch, reason: name);
        expect(tile(tester, name).onChanged, isNotNull, reason: name);
      }
    });

    testWidgets('a switch reads as a toggle named by its label', (
      tester,
    ) async {
      remote.onFetchOne = (_) async => row(disabled: const [languages]);

      await pumpScreen(tester);
      await tester.ensureVisible(capability(languages));
      await tester.pump();

      expect(
        tester.getSemantics(capability(search)),
        isSemantics(hasToggledState: true, isToggled: true, label: 'Search'),
      );
      expect(
        tester.getSemantics(capability(languages)),
        isSemantics(
          hasToggledState: true,
          isToggled: false,
          label: 'List languages',
        ),
      );
    });

    testWidgets('a switched-off name it cannot label still shows', (
      tester,
    ) async {
      final sent = <List<String>>[];
      remote.onFetchOne = (_) async =>
          row(capabilities: const [search], disabled: const ['FutureThing']);
      remote.onSetDisabledCapabilities = (_, disabled) async {
        sent.add(disabled);
        return changed(row(capabilities: const [search]));
      };

      await pumpScreen(tester);

      expect(
        textIn(capability('FutureThing'), 'Other: FutureThing'),
        findsOneWidget,
      );
      expect(tile(tester, 'FutureThing').value, isFalse);
      // The list goes back as it came, so switching it on can be asked for.
      await press(tester, capability('FutureThing'));
      await tester.pumpAndSettle();
      expect(sent, [<String>[]]);
    });

    testWidgets('a DataGateway that has declared nothing says so', (
      tester,
    ) async {
      remote.onFetchOne = (_) async => row(capabilities: const []);

      await pumpScreen(tester);

      expect(
        find.text(
          'Nothing yet. It says what it can do at its first interview.',
        ),
        findsOneWidget,
      );
      expect(find.byType(SwitchListTile), findsNothing);
    });

    testWidgets('a switch sends the event, and what is pressed during the '
        'write goes after it', (tester) async {
      final write = Completer<DataGatewayChangeResult>();
      remote.onFetchOne = (_) async => row();
      remote.onSetDisabledCapabilities = (_, disabled) => disabled.length == 1
          ? write.future
          : Future.value(changed(row(disabled: disabled)));
      remote.onInterview = (_) async =>
          answered(row(disabled: const [search, languages]));
      await pumpScreen(tester);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(find.bySemanticsLabel('Saving…'), findsNothing);

      await press(tester, capability(search));

      expect(writes(), [writeOffSearch]);
      // Every control keeps taking presses.
      expect(tile(tester, search).onChanged, isNotNull);
      expect(tile(tester, languages).onChanged, isNotNull);
      expect(
        tester.widget<ButtonStyleButton>(interviewButton).onPressed,
        isNotNull,
      );
      // The switch still says what the server last said.
      expect(tile(tester, search).value, isTrue);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(textIn(interviewButton, 'Interview again'), findsOneWidget);

      await press(tester, capability(search));
      await press(tester, capability(languages));
      await press(tester, interviewButton);

      // Nothing more is sent yet. The switch it waits with still says what the
      // server last said, and the button says what is coming.
      expect(writes(), [writeOffSearch]);
      expect(remote.calls, isNot(contains(interviewCall)));
      expect(tile(tester, languages).value, isTrue);
      expect(textIn(interviewButton, 'Interviewing…'), findsOneWidget);
      expect(tile(tester, search).onChanged, isNull);

      write.complete(changed(row(disabled: const [search])));
      await tester.pumpAndSettle();

      expect(writes(), [
        writeOffSearch,
        'setDisabledCapabilities(dg_1, [Search, ListLanguages])',
      ]);
      expect(remote.calls.last, interviewCall);
      expect(tile(tester, search).value, isFalse);
      expect(tile(tester, languages).value, isFalse);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      expect(textIn(interviewButton, 'Interview again'), findsOneWidget);
    });

    testWidgets('a write that works has nothing to report', (tester) async {
      remote.onFetchOne = (_) async => row();
      remote.onSetDisabledCapabilities = (_, disabled) async =>
          changed(row(disabled: disabled));
      await pumpScreen(tester);

      await press(tester, capability(search));
      await tester.pumpAndSettle();

      expect(tile(tester, search).value, isFalse);
      expect(banner, findsNothing);
    });

    testWidgets('the busy cue is announced, heads the capabilities and moves '
        'nothing', (tester) async {
      final write = Completer<DataGatewayChangeResult>();
      remote.onFetchOne = (_) async => row();
      remote.onSetDisabledCapabilities = (_, _) => write.future;
      await pumpScreen(tester);
      await tester.ensureVisible(capability(search));
      await tester.pump();
      final before = tester.getTopLeft(capability(search));

      await press(tester, capability(search));

      final cue = find.bySemanticsLabel('Saving…');
      expect(cue, findsOneWidget);
      expect(
        tester.getSemantics(cue),
        isSemantics(isLiveRegion: true, label: 'Saving…'),
      );
      final bar = find.byType(LinearProgressIndicator);
      expect(
        tester.getTopLeft(bar).dy,
        greaterThan(tester.getTopLeft(find.text('Capabilities')).dy),
      );
      expect(
        tester.getBottomLeft(bar).dy,
        lessThanOrEqualTo(tester.getTopLeft(capability(search)).dy),
      );
      expect(tester.getTopLeft(capability(search)), before);

      write.complete(changed(row()));
      await tester.pumpAndSettle();

      expect(cue, findsNothing);
      expect(tester.getTopLeft(capability(search)), before);
    });

    testWidgets('a focused switch keeps focus through a write', (tester) async {
      final write = Completer<DataGatewayChangeResult>();
      remote.onFetchOne = (_) async => row();
      remote.onSetDisabledCapabilities = (_, _) => write.future;
      await pumpScreen(tester);

      await focusOn(tester, textIn(capability(search), 'Search'));
      expect(focusIsIn(tester, capability(search)), isTrue);

      await pressKey(tester);

      expect(writes(), [writeOffSearch]);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(focusIsIn(tester, capability(search)), isTrue);

      write.complete(changed(row(disabled: const [search])));
      await tester.pumpAndSettle();

      expect(tile(tester, search).value, isFalse);
      expect(focusIsIn(tester, capability(search)), isTrue);
    });

    testWidgets('a focused switch keeps focus when the write fails and the '
        'banner arrives in the footer', (tester) async {
      remote.onFetchOne = (_) async => row();
      remote.onSetDisabledCapabilities = (_, _) async => throw unreachable();
      await pumpScreen(tester);

      await focusOn(tester, textIn(capability(search), 'Search'));
      await pressKey(tester);
      await tester.pumpAndSettle();

      expect(banner, findsOneWidget);
      expect(focusIsIn(tester, capability(search)), isTrue);
    });

    testWidgets('a focused switch keeps focus when a row above it leaves', (
      tester,
    ) async {
      var reads = 0;
      remote.onFetchOne = (_) async => row(
        capabilities: ++reads == 1
            ? const [search, languages]
            : const [languages],
      );
      await pumpScreen(tester);

      await focusOn(tester, textIn(capability(languages), 'List languages'));
      expect(focusIsIn(tester, capability(languages)), isTrue);

      await press(tester, refreshButton);
      await tester.pumpAndSettle();

      expect(capability(search), findsNothing);
      expect(focusIsIn(tester, capability(languages)), isTrue);
    });
  });

  testWidgets('tab goes refresh, interview, then each switch: a section row '
      'is content, not a stop', (tester) async {
    remote.onFetchOne = (_) async => row(
      sections: [
        DataGatewaySection(capability: languages, lastLoadedAt: lastAt),
      ],
    );
    await pumpScreen(tester);

    for (final control in [
      refreshButton,
      interviewButton,
      capability(search),
      capability(languages),
    ]) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();

      expect(focusIsIn(tester, control), isTrue, reason: '$control');
    }
  });

  group('access (#456)', () {
    testWidgets('a reader who may not update sees status, and no switch or '
        'button works', (tester) async {
      access.current = readOnly;
      remote.onFetchOne = (_) async => row();

      await pumpScreen(tester);

      expect(statusLine, findsOneWidget);
      expect(find.text('First interviewed $first'), findsOneWidget);
      expect(interviewButton, findsNothing);
      expect(tile(tester, search).onChanged, isNull);
      expect(tile(tester, languages).onChanged, isNull);

      await press(tester, capability(search));

      expect(writes(), isEmpty);
    });

    testWidgets('while access is unknown nothing works and nothing is said '
        'about the role, and the controls come when update arrives', (
      tester,
    ) async {
      access.current = const CallerAccess.unknown();
      remote.onFetchOne = (_) async => row();

      await pumpScreen(tester);

      expect(interviewButton, findsNothing);
      expect(tile(tester, search).onChanged, isNull);
      expect(find.textContaining('Your role'), findsNothing);

      access.current = FakeCallerAccessRepository.dataGateway(
        update: AccessExtent.some,
      );
      await tester.pumpAndSettle();

      expect(interviewButton, findsOneWidget);
      expect(tile(tester, search).onChanged, isNotNull);
      expect(reads(), hasLength(1));
    });

    testWidgets('a refused change says why and asks access again, and the '
        'button and switches go once it answers', (tester) async {
      remote.onFetchOne = (_) async => row();
      remote.onInterview = (_) async => throw forbidden();
      await pumpScreen(tester);

      await press(tester, interviewButton);
      await tester.pumpAndSettle();

      expect(
        find.text("Your role can't change data gateways."),
        findsOneWidget,
      );
      expect(access.refreshCount, 1);
      // The refusal alone takes nothing away: access does.
      expect(interviewButton, findsOneWidget);

      access.current = readOnly;
      await tester.pumpAndSettle();

      expect(interviewButton, findsNothing);
      expect(tile(tester, search).onChanged, isNull);
      expect(
        find.text("Your role can't change data gateways."),
        findsOneWidget,
      );
    });
  });

  group('the banner', () {
    for (final outcome in DataGatewayDetailOutcome.values) {
      final (tone, copy) = switch (outcome) {
        DataGatewayDetailOutcome.interviewDone => (
          BgeBannerTone.success,
          'Interview finished. Its lists load over the next few minutes.',
        ),
        DataGatewayDetailOutcome.interviewFailed => (
          BgeBannerTone.warning,
          'The interview failed.',
        ),
        DataGatewayDetailOutcome.interviewUnknown => (
          BgeBannerTone.info,
          'The interview is taking a while, and may still finish. Check back '
              'here shortly.',
        ),
        DataGatewayDetailOutcome.interviewDisabled => (
          BgeBannerTone.info,
          "This data gateway is disabled, so it can't be interviewed. Connect "
              'it first.',
        ),
        DataGatewayDetailOutcome.interviewNoAnswer => (
          BgeBannerTone.error,
          "Couldn't get an answer about the interview, and it may still "
              'finish. Check back here before trying again.',
        ),
        DataGatewayDetailOutcome.capabilityFailed => (
          BgeBannerTone.error,
          "Couldn't get an answer about that change. Check the switch before "
              'trying again.',
        ),
        DataGatewayDetailOutcome.refused => (
          BgeBannerTone.info,
          "Your role can't change data gateways.",
        ),
      };

      testWidgets('each outcome has its banner copy: ${outcome.name}', (
        tester,
      ) async {
        // The bloc reads again after an answer that was lost, and the banner
        // stays only if that read brings the row.
        remote.onFetchOne = (_) async => row();
        switch (outcome) {
          case DataGatewayDetailOutcome.interviewDone:
            remote.onInterview = (_) async => answered(row());
          case DataGatewayDetailOutcome.interviewFailed:
            remote.onInterview = (_) async => answered(row(), ok: false);
          case DataGatewayDetailOutcome.interviewUnknown:
            remote.onInterview = (_) async =>
                throw const DataGatewayTimedOutException('no answer in time');
          case DataGatewayDetailOutcome.interviewDisabled:
            remote.onInterview = (_) async =>
                throw const DataGatewayConflictException(
                  'disabled',
                  statusCode: 409,
                );
          case DataGatewayDetailOutcome.interviewNoAnswer:
            remote.onInterview = (_) async => throw unreachable();
          case DataGatewayDetailOutcome.capabilityFailed:
            remote.onSetDisabledCapabilities = (_, _) async =>
                throw unreachable();
          case DataGatewayDetailOutcome.refused:
            remote.onInterview = (_) async => throw forbidden();
        }
        await pumpScreen(tester);

        await press(
          tester,
          outcome == DataGatewayDetailOutcome.capabilityFailed
              ? capability(search)
              : interviewButton,
        );
        await tester.pumpAndSettle();

        final shown = tester.widget<BgeInlineBanner>(banner);
        expect(shown.message, copy);
        expect(shown.tone, tone);
        expect(textIn(banner, copy), findsOneWidget);
      });
    }

    testWidgets('a conflict reads again, and the row it brings says the '
        'DataGateway is disabled, under the banner', (tester) async {
      var read = 0;
      remote.onFetchOne = (_) async => row(enabled: ++read == 1);
      remote.onInterview = (_) async =>
          throw const DataGatewayConflictException('disabled', statusCode: 409);
      await pumpScreen(tester);

      await press(tester, interviewButton);
      await tester.pumpAndSettle();

      expect(banner, findsOneWidget);
      // The page stays where the press left it, with the badge above.
      expect(find.text('Disabled', skipOffstage: false), findsOneWidget);
      expect(interviewButton, findsNothing);
    });

    testWidgets('dismiss closes the banner', (tester) async {
      remote.onFetchOne = (_) async => row();
      remote.onInterview = (_) async => answered(row(), ok: false);
      await pumpScreen(tester);
      await press(tester, interviewButton);
      await tester.pumpAndSettle();
      expect(banner, findsOneWidget);

      await tester.tap(textIn(banner, 'Dismiss'));
      await tester.pumpAndSettle();

      expect(banner, findsNothing);
    });

    testWidgets('when the read after a lost answer fails, the failed surface '
        'shows, and the banner comes back with the row', (tester) async {
      var reads = 0;
      remote.onFetchOne = (_) async {
        if (++reads == 2) throw unreachable();
        return row();
      };
      remote.onSetDisabledCapabilities = (_, _) async => throw unreachable();
      await pumpScreen(tester);

      await press(tester, capability(search));
      await tester.pumpAndSettle();

      expect(find.byKey(DataGatewayDetailScreen.errorKey), findsOneWidget);
      expect(banner, findsNothing);

      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();

      expect(find.byKey(DataGatewayDetailScreen.errorKey), findsNothing);
      expect(banner, findsOneWidget);
      expect(capability(search), findsOneWidget);
    });
  });

  group('both banners in the footer, on a long page (#457)', () {
    const listMechanics = DataGatewayCapabilities.listMechanics;
    const failedCopy =
        "Couldn't get an answer about that change. Check the switch before "
        'trying again.';
    const refusedCopy = "Your role can't change data gateways.";
    final worklistBanner = find.byKey(
      LanguageLinkWorklist.outcomeKey,
      skipOffstage: false,
    );
    Finder dismissOf(Finder banner) => find.descendant(
      of: banner,
      matching: find.byType(TextButton, skipOffstage: false),
      skipOffstage: false,
    );

    /// Every capability, every list loaded, and a worklist of a full page with
    /// more behind it: the page is long, and the switches are in its middle.
    DataGateway full() => row(
      capabilities: DataGatewayCapabilities.known,
      sections: [
        for (final capability in DataGatewayCapabilities.lists)
          DataGatewaySection(capability: capability, lastLoadedAt: lastAt),
      ],
    );

    for (final (screen, size, scaler) in [
      (
        '320x568 at 200%',
        const Size(320, 568),
        const TextScaler.linear(BgeTextScale.maxScaleFactor),
      ),
      ('1280x800 at 100%', const Size(1280, 800), TextScaler.noScaling),
    ]) {
      Future<void> open(WidgetTester tester) async {
        tester.view
          ..devicePixelRatio = 1
          ..physicalSize = size;
        addTearDown(tester.view.reset);
        remote.onFetchOne = (_) async => full();
        remote.onFetchLanguageLinks = (_, _, _, _) async => linkPageOf([
          for (var n = 1; n <= 50; n++) languageLink('l$n'),
        ], hasMore: true);
        await pumpScreen(tester, textScaler: scaler);
      }

      ScrollPosition page(WidgetTester tester) =>
          tester.state<ScrollableState>(find.byType(Scrollable).first).position;

      /// The banner's head is in the window, and assistive tech has it as a
      /// live region, so it was said as it arrived.
      void expectAnnounced(WidgetTester tester, Finder banner, String copy) {
        final rect = tester.getRect(banner);
        expect(rect.top, greaterThanOrEqualTo(0));
        expect(rect.top, lessThan(size.height));
        expect(
          find.semantics.byLabel(copy).evaluate().single,
          isSemantics(isLiveRegion: true, label: copy),
        );
      }

      /// Where each switch built now is.
      Map<String, Rect> switches(WidgetTester tester) => {
        for (final name in DataGatewayCapabilities.known)
          if (capability(name).evaluate().isNotEmpty)
            name: tester.getRect(capability(name)),
      };

      for (final (outcome, Object error, copy) in [
        ('fails', unreachable(), failedCopy),
        ('is refused', forbidden(), refusedCopy),
      ]) {
        testWidgets('$screen: a capability write that $outcome leaves the '
            'page where it is, with its banner in the window', (tester) async {
          final handle = tester.ensureSemantics();
          remote.onSetDisabledCapabilities = (_, _) async => throw error;
          await open(tester);
          await tester.ensureVisible(capability(listMechanics));
          await tester.pumpAndSettle();
          final before = page(tester).pixels;

          await tester.tap(capability(listMechanics));
          await tester.pumpAndSettle();

          expect(page(tester).pixels, before);
          expectAnnounced(tester, banner, copy);
          handle.dispose();
        });
      }

      testWidgets('$screen: starting a write after an earlier outcome moves no '
          'switch', (tester) async {
        final write = Completer<DataGatewayChangeResult>();
        remote.onInterview = (_) async => answered(full());
        remote.onSetDisabledCapabilities = (_, _) => write.future;
        await open(tester);
        await press(tester, interviewButton);
        await tester.pumpAndSettle();
        expect(banner, findsOneWidget);
        await tester.ensureVisible(capability(search));
        await tester.pumpAndSettle();
        final before = switches(tester);

        await tester.tap(capability(search));
        await pumpEvent(tester);

        expect(banner, findsOneWidget);
        expect(switches(tester), before);

        write.complete(
          changed(full().copyWith(disabledCapabilities: [search])),
        );
        await tester.pumpAndSettle();
      });

      group('$screen: scrolled to the end of a page with no rows', () {
        /// The page at its end, with the outcome of an interview in the footer.
        Future<void> openAtEnd(WidgetTester tester) async {
          remote.onInterview = (_) async => answered(full());
          await open(tester);
          remote.onFetchLanguageLinks = (_, _, _, _) async =>
              linkPageOf(const []);
          tester
              .element(capability(search))
              .read<LanguageLinkListBloc>()
              .add(const LanguageLinkListLoadRequested());
          await tester.pumpAndSettle();
          await press(tester, interviewButton);
          await tester.pumpAndSettle();
          expect(banner, findsOneWidget);
          page(tester).jumpTo(page(tester).maxScrollExtent);
          await tester.pumpAndSettle();
          expect(page(tester).pixels, greaterThan(0));
        }

        /// As its button would: at 200% it may be below the footer's fold.
        void dismiss(WidgetTester tester) => tester
            .element(capability(search))
            .read<DataGatewayDetailBloc>()
            .add(const DataGatewayDetailOutcomeDismissed());

        testWidgets('a write that starts and works moves no switch', (
          tester,
        ) async {
          final write = Completer<DataGatewayChangeResult>();
          remote.onSetDisabledCapabilities = (_, _) => write.future;
          await openAtEnd(tester);
          final before = switches(tester);

          tester
              .element(capability(search))
              .read<DataGatewayDetailBloc>()
              .add(
                const DataGatewayDetailCapabilitySwitched(search, on: false),
              );
          await pumpEvent(tester);

          expect(banner, findsOneWidget);
          expect(switches(tester), before);

          write.complete(
            changed(full().copyWith(disabledCapabilities: [search])),
          );
          await tester.pumpAndSettle();

          // A write that works has nothing to report.
          expect(banner, findsNothing);
          expect(switches(tester), before);
        });

        testWidgets('dismissing the banner moves no switch', (tester) async {
          await openAtEnd(tester);
          final before = switches(tester);

          dismiss(tester);
          await tester.pumpAndSettle();

          expect(banner, findsNothing);
          expect(switches(tester), before);
        });

        testWidgets('the room goes back as the page is scrolled away', (
          tester,
        ) async {
          await openAtEnd(tester);
          final view = find.byType(Scrollable).first;
          final kept = tester.getSize(view).height;
          dismiss(tester);
          await tester.pumpAndSettle();
          expect(tester.getSize(view).height, kept);

          page(tester).jumpTo(0);
          await tester.pumpAndSettle();

          expect(tester.getSize(view).height, greaterThan(kept));
        });
      });

      testWidgets('$screen: the same outcome again is news: a new banner, '
          'which says so as it arrives', (tester) async {
        final handle = tester.ensureSemantics();
        remote.onInterview = (_) async => answered(full());
        await open(tester);
        await press(tester, interviewButton);
        await tester.pumpAndSettle();
        final firstCopy = find.descendant(
          of: banner,
          matching: find.byType(Text, skipOffstage: false),
          skipOffstage: false,
        );
        final first = tester.state(find.byType(BgeInlineBanner));
        final firstNode = tester.getSemantics(firstCopy.first).id;

        await press(tester, interviewButton);
        await tester.pumpAndSettle();

        expect(banner, findsOneWidget);
        expect(tester.state(find.byType(BgeInlineBanner)), isNot(first));
        // A new live region to assistive tech, not the one it has already read.
        expect(tester.getSemantics(firstCopy.first).id, isNot(firstNode));
        handle.dispose();
      });

      testWidgets('$screen: the same outcome on a language link again is news '
          'too, and a Dismiss with focus keeps it', (tester) async {
        remote.onIgnoreLanguageLink = (_, _) async => throw unreachable();
        await open(tester);
        final bloc = tester
            .element(capability(search))
            .read<LanguageLinkListBloc>();
        const ignore = LanguageLinkListActionRequested(
          LanguageLinkAction.ignore,
          'l1',
        );

        bloc.add(ignore);
        await tester.pumpAndSettle();
        final first = tester.state(find.byType(BgeInlineBanner));
        final dismiss = dismissOf(worklistBanner);
        Focus.of(
          tester.element(
            find.descendant(of: dismiss, matching: find.byType(Text)),
          ),
        ).requestFocus();
        await tester.pump();

        bloc.add(ignore);
        await tester.pumpAndSettle();

        expect(tester.state(find.byType(BgeInlineBanner)), isNot(first));
        expect(
          Focus.of(
            tester.element(
              find.descendant(of: dismiss, matching: find.byType(Text)),
            ),
          ).hasFocus,
          isTrue,
        );
      });

      testWidgets('$screen: starting a second interview after an earlier '
          'outcome moves no switch', (tester) async {
        final second = Completer<DataGatewayInterviewResult>();
        var interviews = 0;
        remote.onInterview = (_) =>
            ++interviews == 1 ? Future.value(answered(full())) : second.future;
        await open(tester);
        await press(tester, interviewButton);
        await tester.pumpAndSettle();
        expect(banner, findsOneWidget);
        await tester.ensureVisible(capability(search));
        await tester.pumpAndSettle();
        final before = switches(tester);

        // As the button would: it may be scrolled away, and pressing it there
        // would move the page.
        tester
            .element(capability(search))
            .read<DataGatewayDetailBloc>()
            .add(const DataGatewayDetailInterviewRequested());
        await pumpEvent(tester);

        expect(interviews, 2);
        expect(banner, findsOneWidget);
        expect(switches(tester), before);

        second.complete(answered(full()));
        await tester.pumpAndSettle();
      });

      for (final first in ['the DataGateway', 'the worklist']) {
        testWidgets("$screen: both outcomes show, the DataGateway's first, and "
            '$first'
            "'s Dismiss closes only its own", (tester) async {
          remote.onSetDisabledCapabilities = (_, _) async =>
              throw unreachable();
          remote.onIgnoreLanguageLink = (_, id) async =>
              languageLink(id, status: LanguageLinkStatus.ignored);
          await open(tester);
          await press(tester, capability(search));
          await tester.pumpAndSettle();
          final menu = find.byKey(
            LanguageLinkWorklist.menuKey('l3'),
            skipOffstage: false,
          );
          await tester.scrollUntilVisible(
            menu,
            200,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.ensureVisible(menu);
          await tester.pumpAndSettle();
          await tester.tap(menu);
          await tester.pumpAndSettle();
          await tester.tap(find.byKey(LanguageLinkWorklist.ignoreKey));
          await tester.pumpAndSettle();

          expect(banner, findsOneWidget);
          expect(worklistBanner, findsOneWidget);
          final view = tester.getRect(find.byType(Scrollable).first);
          final own = tester.getRect(banner);
          final theirs = tester.getRect(worklistBanner);
          // In order, below the page's view, in the footer.
          expect(own.bottom, lessThanOrEqualTo(theirs.top));
          expect(theirs.top, greaterThanOrEqualTo(view.bottom));
          // The one that arrived last is whole in the window. Both fit there
          // unless together they are taller than the footer's half of the
          // body, and then the footer scrolls to the other.
          expect(theirs.bottom, lessThanOrEqualTo(size.height));
          await tester.ensureVisible(banner);
          await tester.pumpAndSettle();
          expect(tester.getRect(banner).top, greaterThanOrEqualTo(view.bottom));

          final (closed, kept) = first == 'the DataGateway'
              ? (banner, worklistBanner)
              : (worklistBanner, banner);
          await tester.ensureVisible(dismissOf(closed));
          await tester.pumpAndSettle();
          await tester.tap(dismissOf(closed));
          await tester.pumpAndSettle();

          expect(closed, findsNothing);
          expect(kept, findsOneWidget);

          await tester.ensureVisible(dismissOf(kept));
          await tester.pumpAndSettle();
          await tester.tap(dismissOf(kept));
          await tester.pumpAndSettle();

          expect(kept, findsNothing);
        });
      }

      for (final (control, label) in [
        ('a switch', 'Search'),
        ('Interview again', 'Interview again'),
      ]) {
        testWidgets('$screen: focus leaves a control that access takes away: '
            "from $control to the refusal's Dismiss", (tester) async {
          remote.onSetDisabledCapabilities = (_, _) async => throw forbidden();
          remote.onInterview = (_) async => throw forbidden();
          await open(tester);
          final (target, taken) = control == 'a switch'
              ? (textIn(capability(search), label), capability(search))
              : (textIn(interviewButton, label), interviewButton);
          await tester.ensureVisible(target);
          await tester.pumpAndSettle();
          await focusOn(tester, target);

          await tester.sendKeyEvent(LogicalKeyboardKey.space);
          await tester.pumpAndSettle();

          // The refusal asks access again, and takes nothing away itself.
          expect(find.text(refusedCopy), findsOneWidget);
          expect(access.refreshCount, 1);
          expect(focusIsIn(tester, taken), isTrue);

          // What the ask found.
          access.current = readOnly;
          await tester.pumpAndSettle();

          // A switch stays, and stops; the button goes.
          expect(taken, control == 'a switch' ? findsOneWidget : findsNothing);
          expect(focusIsIn(tester, dismissOf(banner)), isTrue);
          final focused = FocusManager.instance.primaryFocus!.rect;
          expect(focused.top, greaterThanOrEqualTo(0));
          expect(focused.bottom, lessThanOrEqualTo(size.height));
        });
      }
    }

    testWidgets('a switch with keyboard focus that the banner covers is '
        'brought back into view', (tester) async {
      tester.view
        ..devicePixelRatio = 1
        ..physicalSize = const Size(320, 568);
      addTearDown(tester.view.reset);
      remote.onFetchOne = (_) async => full();
      remote.onSetDisabledCapabilities = (_, _) async => throw unreachable();
      await pumpScreen(
        tester,
        textScaler: const TextScaler.linear(BgeTextScale.maxScaleFactor),
      );
      final target = textIn(capability(listMechanics), 'List mechanics');
      await tester.ensureVisible(target);
      // At the foot of the view, where the banner arrives.
      await Scrollable.ensureVisible(
        tester.element(capability(listMechanics)),
        alignment: 1,
      );
      await tester.pumpAndSettle();
      await focusOn(tester, target);
      final before = page0(tester).pixels;

      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();

      expect(banner, findsOneWidget);
      expect(focusIsIn(tester, capability(listMechanics)), isTrue);
      final view = tester.getRect(find.byType(Scrollable).first);
      final focused = FocusManager.instance.primaryFocus!.rect;
      expect(focused.bottom, lessThanOrEqualTo(view.bottom));
      expect(focused.top, greaterThanOrEqualTo(view.top));
      // Only as far as that takes.
      expect(page0(tester).pixels, greaterThan(before));
    });

    testWidgets('a refusal leaves focus alone when no control of the '
        "DataGateway's had it", (tester) async {
      remote.onFetchOne = (_) async => full();
      remote.onInterview = (_) async => throw forbidden();
      await pumpScreen(tester);
      await focusOn(tester, find.byIcon(Icons.refresh));

      // A click focuses nothing.
      await tester.tap(interviewButton);
      await tester.pumpAndSettle();

      expect(
        find.text("Your role can't change data gateways."),
        findsOneWidget,
      );
      expect(focusIsIn(tester, refreshButton), isTrue);
    });

    testWidgets('a switch the banner covers stays put for a pointer', (
      tester,
    ) async {
      tester.view
        ..devicePixelRatio = 1
        ..physicalSize = const Size(320, 568);
      addTearDown(tester.view.reset);
      remote.onFetchOne = (_) async => full();
      remote.onSetDisabledCapabilities = (_, _) async => throw unreachable();
      await pumpScreen(
        tester,
        textScaler: const TextScaler.linear(BgeTextScale.maxScaleFactor),
      );
      await tester.ensureVisible(capability(listMechanics));
      await Scrollable.ensureVisible(
        tester.element(capability(listMechanics)),
        alignment: 1,
      );
      await tester.pumpAndSettle();
      // Focus on it, from an earlier Tab, before the click.
      await focusOn(
        tester,
        textIn(capability(listMechanics), 'List mechanics'),
      );
      final before = page0(tester).pixels;

      await tester.tap(capability(listMechanics));
      await tester.pumpAndSettle();

      expect(banner, findsOneWidget);
      expect(focusIsIn(tester, capability(listMechanics)), isTrue);
      expect(page0(tester).pixels, before);
    });
  });

  group('reading the row', () {
    testWidgets('announces the read, under the list title until there is a '
        'name', (tester) async {
      final read = Completer<DataGateway>();
      remote.onFetchOne = (_) => read.future;

      await tester.pumpWidget(
        app(
          DataGatewayDetailScreen(remote: remote, id: 'dg_1', access: access),
        ),
      );
      await pumpEvent(tester);

      expect(find.byKey(DataGatewayDetailScreen.loadingKey), findsOneWidget);
      expect(find.text('Data gateways'), findsOneWidget);
      expect(
        tester.getSemantics(
          find.bySemanticsLabel('Loading this data gateway…'),
        ),
        isSemantics(isLiveRegion: true, label: 'Loading this data gateway…'),
      );

      read.complete(row());
      await tester.pumpAndSettle();

      expect(find.byKey(DataGatewayDetailScreen.loadingKey), findsNothing);
      expect(find.text('Data gateways'), findsNothing);
      expect(titled('BGG'), findsOneWidget);
    });

    testWidgets('refresh reads the row again', (tester) async {
      final second = Completer<DataGateway>();
      var read = 0;
      remote.onFetchOne = (_) =>
          ++read == 1 ? Future.value(row()) : second.future;
      await pumpScreen(tester);

      await press(tester, refreshButton);

      expect(reads(), hasLength(2));
      // A read over a row on screen keeps it there.
      expect(find.byKey(DataGatewayDetailScreen.loadingKey), findsNothing);
      expect(titled('BGG'), findsOneWidget);

      second.complete(row(name: 'BGG renamed'));
      await tester.pumpAndSettle();

      expect(titled('BGG renamed'), findsOneWidget);
    });

    testWidgets('refresh is named for what it does', (tester) async {
      remote.onFetchOne = (_) async => row();
      await pumpScreen(tester);

      expect(find.byTooltip(refreshLabel), findsOneWidget);
      expect(
        tester.getSemantics(refreshButton),
        isSemantics(isButton: true, hasTapAction: true, tooltip: refreshLabel),
      );
    });

    testWidgets('a focused refresh keeps focus through a read, whatever it '
        'answers', (tester) async {
      // Each read after the first stays out until the test answers it, so
      // the spinner gets a frame.
      late Completer<DataGateway> pending;
      var read = 0;
      remote.onFetchOne = (_) {
        if (++read == 1) return Future.value(row());
        pending = Completer<DataGateway>();
        return pending.future;
      };
      await pumpScreen(tester);

      await focusOn(tester, find.byIcon(Icons.refresh));
      expect(focusIsIn(tester, refreshButton), isTrue);

      // Over the row, which stays, until the read fails and takes it down.
      await pressKey(tester);
      expect(find.byKey(DataGatewayDetailScreen.loadingKey), findsNothing);
      expect(focusIsIn(tester, refreshButton), isTrue);

      pending.completeError(unreachable());
      await tester.pumpAndSettle();
      expect(find.byKey(DataGatewayDetailScreen.errorKey), findsOneWidget);
      expect(focusIsIn(tester, refreshButton), isTrue);

      // From the failure, through the spinner, to gone.
      await pressKey(tester);
      expect(find.byKey(DataGatewayDetailScreen.loadingKey), findsOneWidget);
      expect(focusIsIn(tester, refreshButton), isTrue);

      pending.completeError(
        const DataGatewayNotFoundException('gone', statusCode: 404),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(DataGatewayDetailScreen.goneKey), findsOneWidget);
      expect(focusIsIn(tester, refreshButton), isTrue);

      // From gone, through the spinner, to the row.
      await pressKey(tester);
      expect(find.byKey(DataGatewayDetailScreen.loadingKey), findsOneWidget);
      expect(focusIsIn(tester, refreshButton), isTrue);

      pending.complete(row());
      await tester.pumpAndSettle();
      expect(interviewButton, findsOneWidget);
      expect(focusIsIn(tester, refreshButton), isTrue);
    });

    testWidgets('denied, gone and failed each show their surface', (
      tester,
    ) async {
      var answer = 0;
      remote.onFetchOne = (_) async {
        answer++;
        if (answer == 1) throw unreachable();
        if (answer == 2) {
          throw const DataGatewayNotFoundException('gone', statusCode: 404);
        }
        throw forbidden();
      };

      await pumpScreen(tester);

      expect(find.byKey(DataGatewayDetailScreen.errorKey), findsOneWidget);
      expect(find.text("We couldn't load this data gateway"), findsOneWidget);
      expect(
        find.text('Check your connection, then try again.'),
        findsOneWidget,
      );
      expect(find.text('Data gateways'), findsOneWidget);

      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();

      expect(find.byKey(DataGatewayDetailScreen.errorKey), findsNothing);
      expect(find.byKey(DataGatewayDetailScreen.goneKey), findsOneWidget);
      expect(find.text('Data gateway not found'), findsOneWidget);
      expect(find.text('It may have been deleted.'), findsOneWidget);
      expect(find.text('Data gateways'), findsOneWidget);

      // A user who may not read is refused the worklist too.
      remote.onFetchLanguageLinks = (_, _, _, _) async => throw forbidden();
      await tester.tap(refreshButton);
      await tester.pumpAndSettle();

      expect(find.byKey(DataGatewayDetailScreen.goneKey), findsNothing);
      expect(find.byKey(DataGatewayDetailScreen.deniedKey), findsOneWidget);
      expect(
        find.text("You don't have access to data gateways"),
        findsOneWidget,
      );
      expect(
        find.text('Ask an admin of this server if you need to manage them.'),
        findsOneWidget,
      );
      expect(find.text('Data gateways'), findsOneWidget);
      // The row's read and the worklist's each ask access again.
      expect(access.refreshCount, 2);
      // Nothing to act on, as on the list.
      expect(refreshButton, findsNothing);
    });

    testWidgets('a retry from the failed surface reads again', (tester) async {
      var answer = 0;
      remote.onFetchOne = (_) async {
        if (++answer == 1) throw unreachable();
        return row();
      };
      await pumpScreen(tester);

      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();

      expect(titled('BGG'), findsOneWidget);
      expect(reads(), hasLength(2));
    });

    testWidgets('reads again when uncovered', (tester) async {
      var read = 0;
      remote.onFetchOne = (_) async =>
          row(name: ++read == 1 ? 'BGG' : 'BGG renamed');
      await pumpScreen(tester);
      expect(reads(), hasLength(1));

      unawaited(
        tester
            .state<NavigatorState>(find.byType(Navigator))
            .push(
              MaterialPageRoute<void>(
                builder: (_) => const Scaffold(body: Text('a page on top')),
              ),
            ),
      );
      await tester.pumpAndSettle();
      expect(find.text('a page on top'), findsOneWidget);
      expect(reads(), hasLength(1));

      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pumpAndSettle();

      expect(reads(), hasLength(2));
      expect(titled('BGG renamed'), findsOneWidget);
    });

    testWidgets('a new id in place starts over with that row', (tester) async {
      // go_router keys a page by its path pattern, so going from one location
      // straight to another rebuilds the screen in place.
      final id = ValueNotifier('dg_1');
      addTearDown(id.dispose);
      remote.onFetchOne = (id) async => gateway(id, name: 'Named $id');

      await tester.pumpWidget(
        app(
          ValueListenableBuilder<String>(
            valueListenable: id,
            builder: (_, id, _) =>
                DataGatewayDetailScreen(remote: remote, id: id, access: access),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(titled('Named dg_1'), findsOneWidget);

      id.value = 'dg_2';
      await tester.pumpAndSettle();

      expect(titled('Named dg_2'), findsOneWidget);
      expect(titled('Named dg_1'), findsNothing);
    });
  });

  group('the layout', () {
    void narrow(WidgetTester tester) {
      tester.view
        ..devicePixelRatio = 1
        ..physicalSize = const Size(320, 568);
      addTearDown(tester.view.reset);
    }

    const large = TextScaler.linear(BgeTextScale.maxScaleFactor);

    testWidgets('no overflow at 200% text on 320 wide', (tester) async {
      narrow(tester);
      final interview = Completer<DataGatewayInterviewResult>();
      final long = row(
        name: 'The Board Game Geek bridge, with a long name',
        interview: failing(DataGatewayInterviewFailureCode.describeUnsupported),
        capabilities: [
          ...DataGatewayCapabilities.known,
          'ACapabilityFromAServerNewerThanThisClient',
        ],
        disabled: const [fetch],
        sections: [
          for (final capability in DataGatewayCapabilities.lists)
            DataGatewaySection(
              capability: capability,
              lastLoadedAt: lastAt,
              failure: DataGatewaySectionFailure(
                code: DataGatewaySectionFailureCode.linkFailed,
                at: failedAt,
              ),
            ),
        ],
      );
      remote.onFetchOne = (_) async => long;
      remote.onInterview = (_) => interview.future;

      await pumpScreen(tester, textScaler: large);

      expect(tester.takeException(), isNull);
      for (final name in DataGatewayCapabilities.lists) {
        expect(section(name), findsOneWidget);
      }
      expect(
        capability('ACapabilityFromAServerNewerThanThisClient'),
        findsOneWidget,
      );

      await press(tester, interviewButton);

      expect(tester.takeException(), isNull);
      expect(find.text('Interviewing…'), findsOneWidget);

      interview.completeError(
        const DataGatewayTimedOutException('no answer in time'),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(banner, findsOneWidget);
    });

    testWidgets('the name heads the page whole, as a heading, at 200% text '
        'on 320 wide', (tester) async {
      narrow(tester);
      final handle = tester.ensureSemantics();
      const name = 'Board Game Geek staging, the copy we try changes on';
      remote.onFetchOne = (_) async => row(name: name);

      await pumpScreen(tester, textScaler: large);

      expect(tester.takeException(), isNull);
      final heading = find.byKey(DataGatewayDetailScreen.nameKey);
      // First on the page, at the head of its content, and above the status.
      final view = tester.getRect(find.byType(Scrollable).first);
      final inset = BgeTokens.of(tester.element(heading)).spaceLg;
      expect(tester.getRect(heading).top, view.top + inset);
      expect(
        tester.getRect(heading).top,
        lessThan(tester.getRect(find.text('Enabled', skipOffstage: false)).top),
      );
      // Whole: wrapped over lines, with nothing cut and nothing past the edge.
      final paragraph = tester.renderObject<RenderParagraph>(heading);
      expect(paragraph.didExceedMaxLines, isFalse);
      final lines = {
        for (final box in paragraph.getBoxesForSelection(
          const TextSelection(baseOffset: 0, extentOffset: name.length),
        ))
          box.top,
      };
      expect(lines.length, greaterThan(1));
      expect(tester.getRect(heading).right, lessThanOrEqualTo(320));
      // A heading, and said once in the page: the other node with the name
      // is the app bar's title, which names the screen.
      final nodes = find.semantics.byLabel(name).evaluate();
      expect(nodes, hasLength(2));
      for (final node in nodes) {
        expect(node, isSemantics(isHeader: true));
      }
      handle.dispose();
    });

    testWidgets('no overflow with the busy cue showing', (tester) async {
      narrow(tester);
      final write = Completer<DataGatewayChangeResult>();
      remote.onFetchOne = (_) async => row();
      remote.onSetDisabledCapabilities = (_, _) => write.future;

      await pumpScreen(tester, textScaler: large);
      await press(tester, capability(search));

      expect(tester.takeException(), isNull);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);

      write.complete(changed(row()));
      await tester.pumpAndSettle();
    });

    for (final (name, surface, Object error) in [
      ('failed', DataGatewayDetailScreen.errorKey, unreachable()),
      (
        'gone',
        DataGatewayDetailScreen.goneKey,
        const DataGatewayNotFoundException('gone', statusCode: 404),
      ),
      ('denied', DataGatewayDetailScreen.deniedKey, forbidden()),
    ]) {
      testWidgets('no overflow on the $name surface', (tester) async {
        narrow(tester);
        remote.onFetchOne = (_) async => throw error;

        await pumpScreen(tester, textScaler: large);

        expect(tester.takeException(), isNull);
        expect(find.byKey(surface), findsOneWidget);
      });
    }
  });

  group('offline (#49)', () {
    late ValueNotifier<bool> offline;

    setUp(() => offline = ValueNotifier(true));
    tearDown(() => offline.dispose());

    Finder reason() => find.text(onlineOnlyCopy, skipOffstage: false);

    testWidgets('the interview and the switches are disabled and say why', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      remote.onFetchOne = (_) async => row();
      await pumpScreen(tester, offline: offline);

      await tester.ensureVisible(interviewButton);
      await tester.pump();
      expect(
        tester.widget<ButtonStyleButton>(interviewButton).onPressed,
        isNull,
      );
      expect(
        tester.getSemantics(interviewButton),
        matchesSemantics(
          label: 'Interview again',
          hint: onlineOnlyCopy,
          isButton: true,
          hasEnabledState: true,
        ),
      );
      for (final (name, label) in [
        (search, 'Search'),
        (languages, 'List languages'),
      ]) {
        await tester.ensureVisible(capability(name));
        await tester.pump();
        expect(tile(tester, name).onChanged, isNull, reason: label);
        expect(
          tester.getSemantics(capability(name)),
          matchesSemantics(
            label: '$label\n$onlineOnlyCopy',
            hasSelectedState: true,
            hasEnabledState: true,
            hasToggledState: true,
            isToggled: true,
          ),
          reason: label,
        );
      }
      // The button's note, and one line in each of the two switches.
      expect(reason(), findsNWidgets(3));

      offline.value = false;
      await tester.pump();

      expect(reason(), findsNothing);
      expect(
        tester.widget<ButtonStyleButton>(interviewButton).onPressed,
        isNotNull,
      );
      expect(tile(tester, search).onChanged, isNotNull);
      expect(tile(tester, languages).onChanged, isNotNull);
      handle.dispose();
    });

    testWidgets('a press while offline sends nothing', (tester) async {
      remote.onFetchOne = (_) async => row();
      await pumpScreen(tester, offline: offline);

      await tester.ensureVisible(interviewButton);
      await tester.pump();
      await tester.tap(interviewButton, warnIfMissed: false);
      await tester.tap(capability(search), warnIfMissed: false);
      await pumpEvent(tester);

      expect(remote.calls.where((c) => c == interviewCall), isEmpty);
      expect(writes(), isEmpty);
    });

    testWidgets('an online scope lays the section out as no scope does', (
      tester,
    ) async {
      remote.onFetchOne = (_) async => row();
      await pumpScreen(tester);
      await tester.ensureVisible(capability(languages));
      await tester.pump();
      final before = [
        tester.getRect(interviewButton),
        tester.getRect(capability(search)),
        tester.getRect(capability(languages)),
      ];

      final flipping = ValueNotifier(true);
      addTearDown(flipping.dispose);
      await pumpScreen(tester, offline: flipping);
      flipping.value = false;
      await tester.pump();
      await tester.ensureVisible(capability(languages));
      await tester.pump();

      expect([
        tester.getRect(interviewButton),
        tester.getRect(capability(search)),
        tester.getRect(capability(languages)),
      ], before);
    });

    testWidgets('going offline in an interview does not take focus to the '
        'banner when it ends', (tester) async {
      offline.value = false;
      final interview = Completer<DataGatewayInterviewResult>();
      remote.onFetchOne = (_) async => row();
      remote.onInterview = (_) => interview.future;
      await pumpScreen(tester, offline: offline);
      await focusOn(tester, textIn(interviewButton, 'Interview again'));
      await pressKey(tester);
      expect(focusIsIn(tester, interviewButton), isTrue);

      // The button goes disabled under focus, which is accepted; the app must
      // not throw, and a disabled button is not a finished action.
      offline.value = true;
      await pumpEvent(tester);
      expect(tester.takeException(), isNull);
      expect(focusIsIn(tester, interviewButton), isFalse);

      interview.complete(answered(row()));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(banner, findsOneWidget);
      expect(focusIsIn(tester, banner), isFalse);
    });
  });

  group('accessibility audit', () {
    const listMechanics = DataGatewayCapabilities.listMechanics;

    /// Something on every line the page can show: in use with a later
    /// interview that failed, every capability with two switched off, and a
    /// list of each kind: loaded, failed, not loaded yet and switched off.
    DataGateway full() => row(
      interview: failing(DataGatewayInterviewFailureCode.pingFailed),
      capabilities: DataGatewayCapabilities.known,
      disabled: const [fetch, listMechanics],
      sections: [
        DataGatewaySection(capability: languages, lastLoadedAt: lastAt),
        DataGatewaySection(
          capability: platforms,
          failure: DataGatewaySectionFailure(
            code: DataGatewaySectionFailureCode.listFailed,
            at: failedAt,
          ),
        ),
      ],
    );

    /// One of each row the waiting filter lists: pending, with what the
    /// DataGateway supplied beside it, and unresolved, in a format this
    /// client names and in one it doesn't.
    final links = [
      languageLink(
        'l1',
        value: 'ces',
        format: LanguageCodeFormat.iso6393,
        status: LanguageLinkStatus.pending,
        suppliedName: 'Czech',
        suppliedNativeName: 'Cestina',
        suppliedIetfTag: 'cs',
      ),
      languageLink(
        'l2',
        value: 'Brazilian',
        format: LanguageCodeFormat.languageName,
      ),
      languageLink('l3', value: 'Klingon'),
    ];

    /// The worklist's one page: [links], and nothing more.
    final linkPage = linkPageOf(links);

    /// A first page with more behind it, which is a full one: the next page
    /// asked for is the one after the rows read so far.
    final fullPage = linkPageOf([
      for (
        var n = 1;
        n <= DataGatewayRemoteDataSource.languageLinkPageSize;
        n++
      )
        languageLink('r$n'),
    ], hasMore: true);

    final tags = [
      languageTag('t1', name: 'Czech', tag: 'cs'),
      languageTag('t2', name: 'Slovak', tag: 'sk'),
      languageTag('t3', name: 'Polish', tag: 'pl'),
    ];

    Finder linkRow(String id) => find.byKey(LanguageLinkWorklist.rowKey(id));
    Finder linkMenu(String id) => find.byKey(LanguageLinkWorklist.menuKey(id));
    final moreButton = find.byKey(LanguageLinkWorklist.moreKey);
    final worklistBanner = find.byKey(
      LanguageLinkWorklist.outcomeKey,
      skipOffstage: false,
    );
    final picker = find.byType(LanguageTagPickerDialog);

    /// The DataGateway is [full], with its worklist of [links].
    void listed() {
      remote.onFetchOne = (_) async => full();
      remote.onFetchLanguageLinks = (_, _, _, _) async => linkPage;
    }

    /// The worklist answers its first read with [answer]: a page, a future
    /// to wait on, or anything else to throw. Under the file's usual row,
    /// which has less to say than [full], so the worklist sits higher on the
    /// page.
    void worklist(Object answer) {
      remote.onFetchOne = (_) async => row();
      remote.onFetchLanguageLinks = (_, _, _, _) => switch (answer) {
        final PaginatedResult<LanguageLink> page => Future.value(page),
        final Future<PaginatedResult<LanguageLink>> pending => pending,
        _ => Future.error(answer),
      };
    }

    /// The worklist of [links], and a picker that finds [tags] with more
    /// behind them.
    void pickable() {
      worklist(linkPage);
      remote.onFetchLanguageTags = (_, _, _) async =>
          tagPageOf(tags, hasMore: true);
    }

    /// The screen in [theme], as the shell routes to it. [seed] scripts the
    /// fakes first, [listed] unless it says otherwise: the screen sends its
    /// reads as it is built. `auditScreen` builds once per cell, so the seed
    /// runs once per cell too. [offline] holds the connection down through a
    /// notifier of the cell's own, which goes with it.
    Widget Function(ThemeData) screen({
      void Function()? seed,
      bool offline = false,
    }) => (theme) {
      (seed ?? listed)();
      final notifier = offline ? ValueNotifier(true) : null;
      if (notifier != null) addTearDown(notifier.dispose);
      return app(
        DataGatewayDetailScreen(remote: remote, id: 'dg_1', access: access),
        theme: theme,
        offline: notifier,
      );
    };

    /// Pumps through a menu's or a dialog's way in or out. Not a settle: a
    /// busy cue never stops.
    Future<void> pumpThrough(WidgetTester tester) async {
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
    }

    /// Scrolls the page down to [target], as a user would, and up to the
    /// head of the view where the page goes that far.
    Future<void> scrollTo(
      WidgetTester tester,
      Finder target, {
      bool settle = true,
    }) async {
      await tester.scrollUntilVisible(
        target,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      // Built in the cache counts as found, so into view for certain.
      await tester.ensureVisible(target);
      settle ? await tester.pumpAndSettle() : await pumpThrough(tester);
    }

    /// Chooses [item] from the menu on [id]'s row, and lets the menu close.
    /// Pumps rather than settles, so that it works beside a row that spins.
    Future<void> chooseOn(WidgetTester tester, String id, Key item) async {
      await scrollTo(tester, linkMenu(id), settle: false);
      await tester.tap(linkMenu(id));
      await pumpThrough(tester);
      await tester.tap(find.byKey(item));
      // A popup item hands its choice over once its menu has gone.
      await pumpThrough(tester);
    }

    /// Opens the language picker from [id]'s row, and lets it read its first
    /// page.
    Future<void> openPicker(WidgetTester tester, String id) async {
      await chooseOn(tester, id, LanguageLinkWorklist.linkKey);
      await pumpThrough(tester);
      expect(picker, findsOneWidget);
    }

    /// A switch's write that fails, and an ignore that works: an outcome for
    /// each banner.
    void bothAnswer() {
      remote.onSetDisabledCapabilities = (_, _) async => throw unreachable();
      remote.onIgnoreLanguageLink = (_, id) async =>
          languageLink(id, status: LanguageLinkStatus.ignored);
    }

    /// Switches Search off, which fails, then ignores the first row: both
    /// banners show, the DataGateway's first.
    Future<void> showBoth(WidgetTester tester) async {
      await tester.pumpAndSettle();
      await press(tester, capability(search));
      await tester.pumpAndSettle();
      await chooseOn(tester, 'l1', LanguageLinkWorklist.ignoreKey);
      await tester.pumpAndSettle();
      expect(
        textIn(
          banner,
          "Couldn't get an answer about that change. Check the switch before "
          'trying again.',
        ),
        findsOneWidget,
      );
      expect(
        textIn(worklistBanner, 'Ignored ces (ISO 639-3 code).'),
        findsOneWidget,
      );
    }

    void holdIgnores() =>
        remote.onIgnoreLanguageLink = (_, _) =>
            Completer<LanguageLink>().future;

    /// The spinner standing in for [id]'s menu while its action runs.
    Finder busyOn(String id) => find.descendant(
      of: find.byKey(LanguageLinkWorklist.rowKey(id), skipOffstage: false),
      matching: find.byType(CircularProgressIndicator, skipOffstage: false),
      skipOffstage: false,
    );

    auditScreen(
      'loading',
      build: screen(
        seed: () => remote.onFetchOne = (_) => Completer<DataGateway>().future,
      ),
      settle: false,
      arrange: (tester) async {
        await tester.pump();
        expect(find.byKey(DataGatewayDetailScreen.loadingKey), findsOneWidget);
      },
    );

    auditScreen(
      'access denied',
      build: screen(
        seed: () {
          // A caller who may not read is refused the worklist too.
          remote.onFetchOne = (_) async => throw forbidden();
          remote.onFetchLanguageLinks = (_, _, _, _) async => throw forbidden();
        },
      ),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        expect(find.byKey(DataGatewayDetailScreen.deniedKey), findsOneWidget);
      },
    );

    auditScreen(
      'gone',
      build: screen(
        seed: () => remote.onFetchOne = (_) async =>
            throw const DataGatewayNotFoundException('gone', statusCode: 404),
      ),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        expect(find.byKey(DataGatewayDetailScreen.goneKey), findsOneWidget);
      },
    );

    auditScreen(
      'failed, with retry',
      build: screen(
        seed: () => remote.onFetchOne = (_) async => throw unreachable(),
      ),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        expect(find.byKey(DataGatewayDetailScreen.errorKey), findsOneWidget);
        expect(find.text('Try again'), findsOneWidget);
      },
    );

    auditScreen(
      'ready, may update',
      build: screen(),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        expect(find.byKey(DataGatewayDetailScreen.nameKey), findsOneWidget);
        // Built, if below the fold at 320dp × 2.0.
        expect(interviewButton, findsOneWidget);
        expect(tile(tester, search).onChanged, isNotNull);
      },
    );

    // The worklist's rows are built only as the page reaches them (#50).
    auditScreen(
      'ready, scrolled to the end',
      build: screen(),
      arrange: (tester) async {
        await scrollListToEnd(tester, linkRow('l3'));
        expect(linkMenu('l3'), findsOneWidget);
      },
    );

    // At 320dp × 2.0 the page runs about seven views long: the top holds
    // the name and the status, and the end the worklist's rows, so the
    // interview button, the lists, the switches and the worklist's head are
    // on screen in neither. This audits them in a view tall enough to hold
    // the page whole (#50).
    auditScreen(
      'ready, whole page',
      build: screen(),
      arrange: (tester) async {
        await useWholePage(tester);
        expect(interviewButton, findsOneWidget);
        for (final name in DataGatewayCapabilities.known) {
          expect(tile(tester, name).onChanged, isNotNull, reason: name);
        }
        for (final link in links) {
          expect(linkMenu(link.id), findsOneWidget, reason: link.id);
        }
        expectWholePage(tester);
      },
    );

    // Whole, for the same reason: the switches, which are what read-only
    // changes, are below the fold at the top, all of them at 320dp × 2.0
    // and all but the first at 390dp × 1.0.
    auditScreen(
      'ready, read-only, whole page',
      build: screen(
        seed: () {
          access.current = readOnly;
          listed();
        },
      ),
      arrange: (tester) async {
        await useWholePage(tester);
        expect(interviewButton, findsNothing);
        expect(tile(tester, search).onChanged, isNull);
        expect(linkRow('l1'), findsOneWidget);
        expect(linkMenu('l1'), findsNothing);
        expectWholePage(tester);
      },
    );

    // The interview never answers. Its button says so, and the switches stop.
    auditScreen(
      'interview in flight',
      build: screen(
        seed: () {
          listed();
          remote.onInterview = (_) =>
              Completer<DataGatewayInterviewResult>().future;
        },
      ),
      settle: false,
      arrange: (tester) async {
        await tester.pumpAndSettle();
        await press(tester, interviewButton);
        expect(textIn(interviewButton, 'Interviewing…'), findsOneWidget);
        expect(tile(tester, search).onChanged, isNull);
      },
    );

    // The write never answers, so the bar at the head of the switches runs.
    auditScreen(
      'capability write in flight',
      build: screen(
        seed: () {
          listed();
          remote.onSetDisabledCapabilities = (_, _) =>
              Completer<DataGatewayChangeResult>().future;
        },
      ),
      settle: false,
      arrange: (tester) async {
        await tester.pumpAndSettle();
        await press(tester, capability(search));
        expect(find.byType(LinearProgressIndicator), findsOneWidget);
        expect(tile(tester, search).onChanged, isNotNull);
      },
    );

    auditScreen(
      'outcome banner',
      build: screen(
        seed: () {
          listed();
          remote.onInterview = (_) async => answered(full(), ok: false);
        },
      ),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        await press(tester, interviewButton);
        await tester.pumpAndSettle();
        expect(textIn(banner, 'The interview failed.'), findsOneWidget);
      },
    );

    // The footer at its fullest: the DataGateway's banner, then the
    // worklist's.
    auditScreen(
      'both outcome banners',
      build: screen(
        seed: () {
          listed();
          bothAnswer();
        },
      ),
      arrange: showBoth,
    );

    // At 320dp × 2.0 the two banners are taller than the footer's half of
    // the view, which scrolls to the worklist's, the last to arrive, and
    // leaves the DataGateway's above its edge, Dismiss and all. This audits
    // both in a view tall enough to hold them, under the file's usual row,
    // so that the page fits it too (#50).
    auditScreen(
      'both outcome banners, whole page',
      build: screen(
        seed: () {
          worklist(linkPage);
          bothAnswer();
        },
      ),
      arrange: (tester) async {
        await useWholePage(tester);
        await showBoth(tester);
        expectWholePage(tester);
        // The footer the banners sit in, which scrolls apart from the page.
        expectWholePage(
          tester,
          within: find.ancestor(of: banner, matching: find.byType(Scrollable)),
        );
      },
    );

    // Whole, as the ready state is: offline changes the interview button
    // and the switches, which are below the fold at the top (at 390dp × 1.0
    // the button isn't). The worklist is left empty, as the file's setUp has
    // it: offline changes none of its rows until a menu opens, and with them
    // the page is taller at 320dp × 2.0 than the whole-page view.
    auditScreen(
      'offline, whole page',
      build: screen(
        seed: () => remote.onFetchOne = (_) async => full(),
        offline: true,
      ),
      arrange: (tester) async {
        await useWholePage(tester);
        expect(
          tester.widget<ButtonStyleButton>(interviewButton).onPressed,
          isNull,
        );
        expect(tile(tester, search).onChanged, isNull);
        // The button's note, and a line in each switch.
        expect(
          find.text(onlineOnlyCopy),
          findsNWidgets(1 + DataGatewayCapabilities.known.length),
        );
        expectWholePage(tester);
      },
    );

    // The worklist's own surfaces, under a DataGateway that reads. Its rows
    // are drawn in the ready calls above.
    auditScreen(
      'worklist, loading',
      build: screen(
        seed: () => worklist(Completer<PaginatedResult<LanguageLink>>().future),
      ),
      settle: false,
      arrange: (tester) async {
        await pumpEvent(tester);
        final loading = find.bySemanticsLabel('Loading language names…');
        await scrollTo(tester, loading, settle: false);
        expect(loading.hitTestable(), findsOneWidget);
      },
    );

    auditScreen(
      'worklist, failed',
      build: screen(seed: () => worklist(unreachable())),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        final failed = find.byKey(LanguageLinkWorklist.errorKey);
        await scrollTo(tester, failed);
        expect(
          find.text("Couldn't load the language names.").hitTestable(),
          findsOneWidget,
        );
        expect(
          find
              .descendant(of: failed, matching: find.text('Try again'))
              .hitTestable(),
          findsOneWidget,
        );
      },
    );

    auditScreen(
      'worklist, access denied',
      build: screen(seed: () => worklist(forbidden())),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        // Its first line, so the whole notice is under it.
        final denied = find.text("You don't have access to data gateways");
        await scrollTo(tester, denied);
        expect(denied.hitTestable(), findsOneWidget);
        expect(
          find
              .text('Ask an admin of this server if you need to manage them.')
              .hitTestable(),
          findsOneWidget,
        );
      },
    );

    auditScreen(
      'worklist, empty',
      build: screen(seed: () => worklist(linkPageOf(const []))),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        await scrollTo(tester, find.byKey(LanguageLinkWorklist.emptyKey));
        expect(find.text('Nothing to review').hitTestable(), findsOneWidget);
      },
    );

    // The first row is pending, which offers every action.
    auditScreen(
      'worklist, row menu open',
      build: screen(seed: () => worklist(linkPage)),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        await scrollTo(tester, linkMenu('l1'));
        await tester.tap(linkMenu('l1'));
        await tester.pumpAndSettle();
        for (final key in [
          LanguageLinkWorklist.acceptKey,
          LanguageLinkWorklist.linkKey,
          LanguageLinkWorklist.ignoreKey,
        ]) {
          expect(find.byKey(key).hitTestable(), findsOneWidget, reason: '$key');
        }
      },
    );

    // The ignore never answers, so the row keeps spinning.
    auditScreen(
      'worklist, an action in flight',
      build: screen(
        seed: () {
          worklist(linkPage);
          holdIgnores();
        },
      ),
      settle: false,
      arrange: (tester) async {
        await tester.pumpAndSettle();
        await chooseOn(tester, 'l1', LanguageLinkWorklist.ignoreKey);
        expect(busyOn('l1'), findsOneWidget);
      },
    );

    auditScreen(
      'worklist, more footer',
      build: screen(seed: () => worklist(fullPage)),
      arrange: (tester) async {
        await scrollListToEnd(tester, moreButton);
        expect(textIn(moreButton, 'Show more'), findsOneWidget);
      },
    );

    auditScreen(
      'worklist, more failed',
      build: screen(
        seed: () {
          remote.onFetchOne = (_) async => row();
          remote.onFetchLanguageLinks = (_, _, page, _) async =>
              page == 1 ? fullPage : throw unreachable();
        },
      ),
      arrange: (tester) async {
        await scrollListToEnd(tester, moreButton);
        await tester.tap(moreButton);
        await tester.pumpAndSettle();
        // The notice goes in above the button, which it pushes down.
        await scrollListToEnd(tester, moreButton);
        expect(
          find.text("Couldn't load more language names.").hitTestable(),
          findsOneWidget,
        );
        expect(textIn(moreButton, 'Try again'), findsOneWidget);
      },
    );

    auditScreen(
      'language tag picker open',
      build: screen(seed: pickable),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        await openPicker(tester, 'l1');
        await tester.pumpAndSettle();
        expect(
          find.text('Link "ces (ISO 639-3 code)" to a language'),
          findsOneWidget,
        );
        expect(find.byKey(LanguageTagPickerDialog.searchKey), findsOneWidget);
      },
    );

    // At 320dp × 2.0 the title, the field and its helper fill the dialog,
    // and its rows and Show more scroll below them. This audits them in a
    // view tall enough to hold the dialog whole (#50).
    auditScreen(
      'language tag picker open, whole page',
      build: screen(seed: pickable),
      arrange: (tester) async {
        await useWholePage(tester);
        await openPicker(tester, 'l1');
        await tester.pumpAndSettle();
        // Its title, field and rows scroll, and Cancel stays put under them.
        expectWholePage(tester, within: picker);
        for (final tag in tags) {
          expect(
            find.byKey(LanguageTagPickerDialog.rowKey(tag.id)).hitTestable(),
            findsOneWidget,
            reason: tag.id,
          );
        }
        expect(
          find.byKey(LanguageTagPickerDialog.moreKey).hitTestable(),
          findsOneWidget,
        );
      },
    );

    auditScreen(
      'language tag picker, failed',
      build: screen(
        seed: () {
          worklist(linkPage);
          remote.onFetchLanguageTags = (_, _, _) async => throw unreachable();
        },
      ),
      arrange: (tester) async {
        await tester.pumpAndSettle();
        await openPicker(tester, 'l1');
        final retry = find.byKey(LanguageTagPickerDialog.retryKey);
        // Into the dialog's view: at 320dp × 2.0 it is below its fold.
        await tester.ensureVisible(retry);
        await tester.pumpAndSettle();
        expect(
          find.text("Couldn't load languages.").hitTestable(),
          findsOneWidget,
        );
        expect(retry.hitTestable(), findsOneWidget);
      },
    );

    // A dialog over a busy worklist: the second row's picker while the
    // first row's ignore runs.
    auditScreen(
      'language tag picker, over an action in flight',
      build: screen(
        seed: () {
          pickable();
          holdIgnores();
        },
      ),
      settle: false,
      arrange: (tester) async {
        await tester.pumpAndSettle();
        await chooseOn(tester, 'l1', LanguageLinkWorklist.ignoreKey);
        expect(busyOn('l1'), findsOneWidget);
        await openPicker(tester, 'l2');
        expect(busyOn('l1'), findsOneWidget);
      },
    );
  });
}
