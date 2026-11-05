import 'dart:ui' show Tristate;
import 'dart:async';

import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/ui.dart';

Widget _toggle({bool thumbnails = false, ValueChanged<bool>? onChanged}) =>
    Scaffold(
      body: BgeLayoutToggle(
        thumbnails: thumbnails,
        onChanged: onChanged ?? (_) {},
        listLabel: 'List',
        thumbnailsLabel: 'Thumbnails',
      ),
    );

void main() {
  group('BgeLayoutToggle', () {
    testWidgets('the selected segment is announced as selected', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(hostAtSize(tester, _toggle(thumbnails: true)));

      final thumbs = tester.getSemantics(find.bySemanticsLabel('Thumbnails'));
      final list = tester.getSemantics(find.bySemanticsLabel('List'));
      expect(thumbs.flagsCollection.isSelected, Tristate.isTrue);
      expect(list.flagsCollection.isSelected, isNot(Tristate.isTrue));
      handle.dispose();
    });

    testWidgets('each segment is named', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(hostAtSize(tester, _toggle()));

      expect(find.bySemanticsLabel('List'), findsOneWidget);
      expect(find.bySemanticsLabel('Thumbnails'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('tapping the other segment reports it', (tester) async {
      bool? seen;
      await tester.pumpWidget(
        hostAtSize(tester, _toggle(onChanged: (value) => seen = value)),
      );

      await tester.tap(find.byIcon(Icons.grid_view_outlined));
      await tester.pump();

      expect(seen, isTrue);
    });
  });

  group('BgeRememberedLayout', () {
    Widget host({
      required Future<bool?> Function()? read,
      required Future<void> Function(bool)? write,
      required List<bool?> seen,
      void Function(ValueChanged<bool>)? onBuilt,
    }) => BgeRememberedLayout(
      read: read,
      write: write,
      builder: (context, thumbnails, onChanged) {
        seen.add(thumbnails);
        onBuilt?.call(onChanged);
        return const SizedBox();
      },
    );

    testWidgets('remembered: null while reading, then the stored value', (
      tester,
    ) async {
      final completer = Completer<bool?>();
      final seen = <bool?>[];
      await tester.pumpWidget(
        host(read: () => completer.future, write: null, seen: seen),
      );
      expect(seen.last, isNull);

      completer.complete(true);
      await tester.pump();
      await tester.pump();

      expect(seen.last, isTrue);
    });

    testWidgets('remembered: a failed read shows the list, and is reported', (
      tester,
    ) async {
      final seen = <bool?>[];
      final reported = <FlutterErrorDetails>[];
      final previous = FlutterError.onError;
      FlutterError.onError = reported.add;
      addTearDown(() => FlutterError.onError = previous);
      await tester.pumpWidget(
        host(
          read: () async => throw StateError('no store'),
          write: null,
          seen: seen,
        ),
      );
      await tester.pump();

      expect(seen.last, isFalse);
      expect(reported.single.exception, isA<StateError>());
    });

    testWidgets('remembered: no read shows the list', (tester) async {
      final seen = <bool?>[];
      await tester.pumpWidget(host(read: null, write: null, seen: seen));
      await tester.pump();

      expect(seen.last, isFalse);
    });

    testWidgets('remembered: an empty read shows the list', (tester) async {
      final seen = <bool?>[];
      await tester.pumpWidget(
        host(read: () async => null, write: null, seen: seen),
      );
      await tester.pump();

      expect(seen.last, isFalse);
    });

    testWidgets('remembered: a change shows at once and is written', (
      tester,
    ) async {
      final seen = <bool?>[];
      final written = <bool>[];
      late ValueChanged<bool> change;
      await tester.pumpWidget(
        host(
          read: () async => false,
          write: (value) async => written.add(value),
          seen: seen,
          onBuilt: (onChanged) => change = onChanged,
        ),
      );
      await tester.pump();

      change(true);
      await tester.pump();

      expect(seen.last, isTrue);
      expect(written, [true]);
    });

    testWidgets('remembered: a change before the read answers is kept', (
      tester,
    ) async {
      final completer = Completer<bool?>();
      final seen = <bool?>[];
      final written = <bool>[];
      late ValueChanged<bool> change;
      await tester.pumpWidget(
        host(
          read: () => completer.future,
          write: (value) async => written.add(value),
          seen: seen,
          onBuilt: (onChanged) => change = onChanged,
        ),
      );

      change(true);
      await tester.pump();
      completer.complete(false);
      await tester.pump();
      await tester.pump();

      expect(seen.last, isTrue);
      expect(written, [true]);
    });

    testWidgets('remembered: a failed write is not shown', (tester) async {
      final seen = <bool?>[];
      late ValueChanged<bool> change;
      final reported = <FlutterErrorDetails>[];
      final previous = FlutterError.onError;
      FlutterError.onError = reported.add;
      addTearDown(() => FlutterError.onError = previous);
      await tester.pumpWidget(
        host(
          read: () async => false,
          write: (_) async => throw StateError('disk full'),
          seen: seen,
          onBuilt: (onChanged) => change = onChanged,
        ),
      );
      await tester.pump();

      change(true);
      await tester.pump();

      expect(seen.last, isTrue);
      expect(reported, hasLength(1));
    });

    testWidgets('remembered: a read that answers after dispose is ignored', (
      tester,
    ) async {
      final completer = Completer<bool?>();
      await tester.pumpWidget(
        host(read: () => completer.future, write: null, seen: []),
      );
      await tester.pumpWidget(const SizedBox());

      completer.complete(true);
      await tester.pump();

      expect(tester.takeException(), isNull);
    });
  });
}
