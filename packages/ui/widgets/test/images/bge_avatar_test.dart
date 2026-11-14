import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

Widget _host(Widget avatar, {double scale = 1}) => MaterialApp(
  theme: BgeTheme.light(),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: Scaffold(body: Center(child: avatar)),
);

void main() {
  group('BgeAvatar', () {
    testWidgets("initials show when there's no image", (tester) async {
      await tester.pumpWidget(_host(const BgeAvatar(initials: 'AB')));

      expect(find.text('AB'), findsOneWidget);
      expect(find.byIcon(Icons.person_outline), findsNothing);
      expect(find.byKey(BgeAvatar.imageKey), findsNothing);
      expect(
        tester.getSize(find.byType(BgeAvatar)),
        const Size.square(BgeAvatar.defaultSize),
      );
    });

    testWidgets('size sets the diameter', (tester) async {
      await tester.pumpWidget(_host(const BgeAvatar(initials: 'AB', size: 64)));

      expect(tester.getSize(find.byType(BgeAvatar)), const Size.square(64));
    });

    testWidgets('the icon shows when there are no initials', (tester) async {
      await tester.pumpWidget(_host(const BgeAvatar(initials: null)));

      expect(find.byIcon(Icons.person_outline), findsOneWidget);
    });

    testWidgets('an image url builds the network image, decoded to twice '
        'its drawn size', (tester) async {
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        _host(
          const BgeAvatar(
            initials: 'AB',
            imageUrl: 'https://example.com/me.png',
          ),
        ),
      );

      final image = tester.widget<Image>(find.byKey(BgeAvatar.imageKey));
      final resize = image.image as ResizeImage;
      // 40dp at 3x, with BgeThumbnail's headroom of 2.
      expect(resize.width, 240);
      expect(resize.height, 240);
      expect(resize.policy, ResizeImagePolicy.fit);
      final provider = resize.imageProvider as NetworkImage;
      expect(provider.url, 'https://example.com/me.png');
      expect(
        provider.webHtmlElementStrategy,
        WebHtmlElementStrategy.fallback,
      );
    });

    testWidgets('a failed image falls back to initials', (tester) async {
      // The test binding answers every image request with an error.
      await tester.pumpWidget(
        _host(
          const BgeAvatar(
            initials: 'AB',
            imageUrl: 'https://example.com/missing.png',
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The binding answers the request with an error, and an Image with no
      // errorBuilder reports that to FlutterError, which takeException would
      // return. Null therefore means errorBuilder ran and drew the initials.
      expect(tester.takeException(), isNull);
      expect(find.byKey(BgeAvatar.imageKey), findsOneWidget);
      expect(find.text('AB'), findsOneWidget);
    });

    testWidgets('a failed image with no initials falls back to the icon', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const BgeAvatar(
            initials: null,
            imageUrl: 'https://example.com/missing.png',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.person_outline), findsOneWidget);
    });

    testWidgets('initials fit at 2.0 text scale', (tester) async {
      await tester.pumpWidget(
        _host(const BgeAvatar(initials: 'WW'), scale: 2),
      );

      expect(tester.takeException(), isNull);
      // Corners, not getSize: the text's own size is before FittedBox
      // scales it, and the corners are after.
      final text = Rect.fromPoints(
        tester.getTopLeft(find.text('WW')),
        tester.getBottomRight(find.text('WW')),
      );
      final avatar = tester.getRect(find.byType(BgeAvatar));
      expect(avatar.contains(text.topLeft), isTrue);
      expect(avatar.contains(text.bottomRight), isTrue);
    });

    testWidgets('initials keep their natural size and follow the text scale', (
      tester,
    ) async {
      Future<Size> drawn(double scale) async {
        await tester.pumpWidget(
          _host(const BgeAvatar(initials: 'A'), scale: scale),
        );
        // getRect maps the corners through the paint transforms, so it
        // includes FittedBox's scale; getSize would not.
        final rect = tester.getRect(find.text('A'));
        return rect.size;
      }

      // 40 * 0.4 = 16 logical px at 1.0. Under BoxFit.contain the letter
      // would be scaled up to fill the 28px box.
      final one = await drawn(1);
      expect(one.height, lessThan(BgeAvatar.defaultSize * 0.7));
      final onePointFive = await drawn(1.5);
      expect(onePointFive.width, greaterThan(one.width));
    });

    testWidgets('adds nothing to semantics', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_host(const BgeAvatar(initials: 'AB')));

      expect(find.bySemanticsLabel('AB'), findsNothing);
      expect(
        find.descendant(
          of: find.byType(BgeAvatar),
          matching: find.byType(ExcludeSemantics),
        ),
        findsWidgets,
      );
      handle.dispose();
    });
  });
}
