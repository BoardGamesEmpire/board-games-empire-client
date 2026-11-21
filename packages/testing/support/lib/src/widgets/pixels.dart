import 'dart:ui' show Color, Offset, Rect;

import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/widgets.dart' show GlobalKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:ui_tokens/ui_tokens.dart' show Wcag;

/// What a capture drew, as the colour at a point of the captured area.
typedef Pixels = Color Function(Offset point);

/// Captures what [boundary] draws now, for a focus check to compare (#913).
///
/// [boundary] keys a `RepaintBoundary`. The image is read inside
/// `tester.runAsync`, because reading it needs real time that a widget test's
/// fake clock never gives.
Future<Pixels> capturePixels(WidgetTester tester, GlobalKey boundary) async {
  final render =
      boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  final (width, bytes) = (await tester.runAsync(() async {
    final image = await render.toImage();
    final bytes = (await image.toByteData())!;
    final width = image.width;
    image.dispose();
    return (width, bytes);
  }))!;

  Color colourAt(Offset point) {
    final at = (point.dy.floor() * width + point.dx.floor()) * 4;
    return Color.fromARGB(
      bytes.getUint8(at + 3),
      bytes.getUint8(at),
      bytes.getUint8(at + 1),
      bytes.getUint8(at + 2),
    );
  }

  return colourAt;
}

/// The points of [rect], one per pixel, each at the pixel's centre.
Iterable<Offset> pixelCentres(Rect rect) sync* {
  for (var y = rect.top.ceil(); y < rect.bottom.floor(); y++) {
    for (var x = rect.left.ceil(); x < rect.right.floor(); x++) {
      yield Offset(x + 0.5, y + 0.5);
    }
  }
}

/// The most any pixel of [rect] stands out between [a] and [b], as a contrast
/// ratio: 1 where the two draw it alike.
///
/// Points [skip] accepts are left out, so a check can look around an icon
/// without the icon's own colour standing in for the fill.
double strongestContrast(
  Rect rect,
  Pixels a,
  Pixels b, {
  bool Function(Offset point)? skip,
}) {
  var strongest = 1.0;
  for (final point in pixelCentres(rect)) {
    if (skip != null && skip(point)) continue;
    final ratio = Wcag.contrastRatio(a(point), b(point));
    if (ratio > strongest) strongest = ratio;
  }
  return strongest;
}
