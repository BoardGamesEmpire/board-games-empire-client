import 'package:data_gateway/l10n/data_gateway_localizations.dart';
import 'package:data_gateway/src/widgets/data_gateway_status.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:models/domain.dart';
import 'package:ui_tokens/ui_tokens.dart';

import '../support/fake_data_gateway_remote.dart';

void main() {
  /// Why a DataGateway is not in use, for each code, as the status line and
  /// the detail screen's failure line both say it (#457).
  const reasons = {
    DataGatewayInterviewFailureCode.pingFailed: "it didn't answer",
    DataGatewayInterviewFailureCode.describeUnsupported:
        "it can't describe itself, so it may need updating",
    DataGatewayInterviewFailureCode.describeFailed:
        "it couldn't describe itself",
    DataGatewayInterviewFailureCode.unknown: 'something went wrong',
  };

  /// An enabled row that has never been interviewed and has no failure,
  /// unless it says otherwise.
  DataGateway row({
    bool enabled = true,
    bool interviewed = false,
    DataGatewayInterviewFailureCode? failure,
  }) => gateway('dg_1', enabled: enabled).copyWith(
    interview: DataGatewayInterviewStatus(
      interviewed: interviewed,
      failure: failure == null
          ? null
          : DataGatewayInterviewFailure(
              code: failure,
              at: DateTime.utc(2026, 10, 30),
            ),
    ),
  );

  Future<void> pumpBody(WidgetTester tester, Widget body) => tester.pumpWidget(
    MaterialApp(
      theme: BgeTheme.light(),
      localizationsDelegates: DataGatewayLocalizations.localizationsDelegates,
      supportedLocales: DataGatewayLocalizations.supportedLocales,
      home: Scaffold(body: body),
    ),
  );

  group('DataGatewayStatusLine', () {
    for (final (state, dataGateway, words, icon) in [
      (
        'never interviewed and no failure',
        row(),
        'Not in use yet: waiting for its first interview',
        Icons.hourglass_empty,
      ),
      (
        'never interviewed and failed',
        row(failure: DataGatewayInterviewFailureCode.pingFailed),
        "Not in use: it didn't answer",
        Icons.error_outline,
      ),
      (
        'interviewed once and failed since',
        row(
          interviewed: true,
          failure: DataGatewayInterviewFailureCode.pingFailed,
        ),
        "Last interview failed: it didn't answer",
        Icons.warning_amber,
      ),
      (
        'interviewed and no failure',
        row(interviewed: true),
        'In use',
        Icons.check_circle_outline,
      ),
    ]) {
      testWidgets('$state says "$words", with its icon', (tester) async {
        await pumpBody(tester, DataGatewayStatusLine(gateway: dataGateway));

        expect(find.text(words), findsOneWidget);
        expect(find.byIcon(icon), findsOneWidget);
        // The icon and the words, nothing else: status is never color alone.
        expect(find.byType(Icon), findsOneWidget);
      });
    }

    for (final MapEntry(key: code, value: reason) in reasons.entries) {
      testWidgets('names the reason for ${code.name} after the colon', (
        tester,
      ) async {
        await pumpBody(
          tester,
          Column(
            children: [
              DataGatewayStatusLine(gateway: row(failure: code)),
              DataGatewayStatusLine(
                gateway: row(interviewed: true, failure: code),
              ),
            ],
          ),
        );

        expect(find.text('Not in use: $reason'), findsOneWidget);
        expect(find.text('Last interview failed: $reason'), findsOneWidget);
      });
    }

    testWidgets('a disabled DataGateway builds nothing, whatever its '
        'interview says', (tester) async {
      await pumpBody(
        tester,
        DataGatewayStatusLine(
          gateway: row(
            enabled: false,
            failure: DataGatewayInterviewFailureCode.pingFailed,
          ),
        ),
      );

      expect(find.byType(Icon), findsNothing);
      expect(find.byType(Text), findsNothing);
      expect(tester.getSize(find.byType(DataGatewayStatusLine)), Size.zero);
    });
  });

  group('dataGatewayInterviewFailureLabel', () {
    late DataGatewayLocalizations l10n;

    setUpAll(() async {
      l10n = await DataGatewayLocalizations.delegate.load(const Locale('en'));
    });

    for (final MapEntry(key: code, value: reason) in reasons.entries) {
      test('${code.name} reads "$reason"', () {
        expect(dataGatewayInterviewFailureLabel(l10n, code), reason);
      });
    }
  });

  group('DataGatewayEnabledBadge', () {
    testWidgets('says enabled or disabled in an icon and words, not color '
        'alone', (tester) async {
      await pumpBody(tester, const DataGatewayEnabledBadge(enabled: true));

      expect(find.text('Enabled'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);

      await pumpBody(tester, const DataGatewayEnabledBadge(enabled: false));

      expect(find.text('Disabled'), findsOneWidget);
      expect(find.byIcon(Icons.do_not_disturb_on_outlined), findsOneWidget);
    });
  });
}
