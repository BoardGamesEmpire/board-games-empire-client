import 'package:bge_test_support/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const left = Rect.fromLTWH(0, 0, 10, 10);

  /// The picture with the right half's pixels read where the left half's are.
  Pixels mirror(Pixels pixels) =>
      (point) => pixels(point + const Offset(10, 0));

  Future<Pixels> pump(WidgetTester tester) async {
    final boundary = GlobalKey();
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: RepaintBoundary(
            key: boundary,
            child: const SizedBox(
              width: 20,
              height: 10,
              child: Row(
                children: [
                  SizedBox(
                    width: 10,
                    height: 10,
                    child: ColoredBox(color: Color(0xFF000000)),
                  ),
                  SizedBox(
                    width: 10,
                    height: 10,
                    child: ColoredBox(color: Color(0xFFFFFFFF)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    return capturePixels(tester, boundary);
  }

  testWidgets("capturePixels reads each half's colour", (tester) async {
    final pixels = await pump(tester);

    expect(pixels(const Offset(2.5, 5.5)), const Color(0xFF000000));
    expect(pixels(const Offset(15.5, 5.5)), const Color(0xFFFFFFFF));
  });

  testWidgets('strongestContrast is 1 between two captures of one picture', (
    tester,
  ) async {
    final a = await pump(tester);
    final b = await pump(tester);

    expect(strongestContrast(const Rect.fromLTWH(0, 0, 20, 10), a, b), 1);
  });

  testWidgets('strongestContrast between the halves is 21', (tester) async {
    final pixels = await pump(tester);
    final mirrored = mirror(pixels);

    expect(strongestContrast(left, pixels, mirrored), closeTo(21, 0.001));
  });

  testWidgets('skip leaves points out', (tester) async {
    final pixels = await pump(tester);
    final mirrored = mirror(pixels);

    expect(
      strongestContrast(left, pixels, mirrored, skip: (_) => true),
      1,
    );
  });

  test('pixelCentres yields each whole pixel of a rect at its centre', () {
    final points = pixelCentres(const Rect.fromLTRB(1, 2, 4, 4)).toList();

    expect(points, hasLength(6));
    expect(points.first, const Offset(1.5, 2.5));
    expect(points.last, const Offset(3.5, 3.5));
  });

  test('pixelCentres leaves out pixels a rect only part covers', () {
    final points = pixelCentres(const Rect.fromLTRB(0.5, 0.5, 2.5, 2.5));

    expect(points.toList(), [const Offset(1.5, 1.5)]);
  });
}
