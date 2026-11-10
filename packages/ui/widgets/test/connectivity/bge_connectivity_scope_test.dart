import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/ui.dart';

const _reason = "Available when you're online";

Widget _probe({
  required void Function((bool offline, bool showing, String? reason) read)
  onRead,
}) => Builder(
  builder: (context) {
    onRead((
      BgeConnectivityScope.offlineOf(context),
      BgeConnectivityScope.noticeShowingOf(context),
      BgeConnectivityScope.onlineOnlyReasonOf(context),
    ));
    return const SizedBox.shrink();
  },
);

void main() {
  group('BgeConnectivityScope', () {
    testWidgets('defaults to online with no scope', (tester) async {
      late (bool, bool, String?) read;
      await tester.pumpWidget(_probe(onRead: (value) => read = value));

      expect(read, (false, false, null));
    });

    testWidgets('reason is null while online', (tester) async {
      late (bool, bool, String?) read;
      await tester.pumpWidget(
        BgeConnectivityScope(
          offline: false,
          noticeShowing: true,
          onlineOnlyReason: _reason,
          child: _probe(onRead: (value) => read = value),
        ),
      );

      expect(read, (false, true, null));
    });

    testWidgets('reason is the localized text while offline', (tester) async {
      late (bool, bool, String?) read;
      await tester.pumpWidget(
        BgeConnectivityScope(
          offline: true,
          noticeShowing: true,
          onlineOnlyReason: _reason,
          child: _probe(onRead: (value) => read = value),
        ),
      );

      expect(read, (true, true, _reason));
    });

    testWidgets('a change rebuilds its readers', (tester) async {
      final reads = <bool>[];
      Widget scope({required bool offline}) => BgeConnectivityScope(
        offline: offline,
        noticeShowing: offline,
        onlineOnlyReason: _reason,
        child: _probe(onRead: (read) => reads.add(read.$1)),
      );

      await tester.pumpWidget(scope(offline: false));
      await tester.pumpWidget(scope(offline: true));

      expect(reads, [false, true]);
    });

    group('a reader rebuilds only for the part it reads', () {
      late List<String> builds;
      late Widget readers;

      setUp(() {
        builds = [];
        Widget reader(String name, void Function(BuildContext) read) => Builder(
          builder: (context) {
            read(context);
            builds.add(name);
            return const SizedBox.shrink();
          },
        );
        // One instance for every pump, so only the scope rebuilds a reader.
        readers = Column(
          children: [
            reader('offline', BgeConnectivityScope.offlineOf),
            reader('reason', BgeConnectivityScope.onlineOnlyReasonOf),
            reader('notice', BgeConnectivityScope.noticeShowingOf),
          ],
        );
      });

      Widget scope({
        required bool offline,
        required bool showing,
        String reason = _reason,
      }) => Directionality(
        textDirection: TextDirection.ltr,
        child: BgeConnectivityScope(
          offline: offline,
          noticeShowing: showing,
          onlineOnlyReason: reason,
          child: readers,
        ),
      );

      testWidgets('the end of the "Back online" hold rebuilds only the '
          'notice reader', (tester) async {
        await tester.pumpWidget(scope(offline: false, showing: true));
        builds.clear();

        await tester.pumpWidget(scope(offline: false, showing: false));

        expect(builds, ['notice']);
      });

      testWidgets('going offline rebuilds the controls', (tester) async {
        await tester.pumpWidget(scope(offline: false, showing: false));
        builds.clear();

        await tester.pumpWidget(scope(offline: true, showing: false));

        expect(builds, unorderedEquals(['offline', 'reason']));
      });

      testWidgets('a new reason rebuilds the controls', (tester) async {
        await tester.pumpWidget(scope(offline: true, showing: true));
        builds.clear();

        await tester.pumpWidget(
          scope(offline: true, showing: true, reason: 'Nur online'),
        );

        expect(builds, unorderedEquals(['offline', 'reason']));
      });
    });
  });
}
