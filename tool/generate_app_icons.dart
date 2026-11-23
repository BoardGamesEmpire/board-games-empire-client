// Generates every app's launcher icon from one square source image.
//
// Usage, from anywhere in the checkout:
//   dart run tool/generate_app_icons.dart
//
// It reads assets/images/app_icon.png and overwrites the icons in place;
// review the result with `git diff` and by eye. It takes no source
// argument: to change the icon, replace assets/images/app_icon.png and run
// this, so the committed source and the generated icons stay in step.
//
// The source must be square and opaque, and should be at least 1024 px:
// iOS and macOS both ship a 1024 px icon, and a smaller source is scaled
// up for those, with a warning.
//
// ── What each platform gets ────────────────────────────────────────
//
// Web: Icon-192/512 full-bleed, Icon-maskable-192/512 with the artwork
//   shrunk into the maskable safe zone (a centre circle of 80% diameter),
//   and a 64 px favicon.
// iOS: every size AppIcon.appiconset's Contents.json names, full-bleed
//   and opaque. iOS rounds the corners itself, and App Store Connect
//   rejects an icon with an alpha channel.
// Android: legacy ic_launcher squares, plus an ic_launcher_foreground per
//   density for the adaptive icon in mipmap-anydpi-v26. Without an
//   adaptive icon, Android 8+ shrinks a square icon onto a white tile.
// macOS: the Big Sur shape, an 824/1024 rounded square with a soft shadow
//   on a clear margin. Linux installs app_icon_256.png from this set.
// Windows: app_icon.ico, 16 to 256 px.
//
// Maskable and adaptive icons are cropped to a circle, so their artwork
// is shrunk until the emblem fits inside it. The margin that leaves is
// filled by extending the artwork's own edge pixels outward and blurring
// them, which continues the source's gradient without a visible seam.

import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as img;

import 'src/workspace_root.dart';

const _source = 'assets/images/app_icon.png';

void main(List<String> args) {
  final Directory root;
  try {
    root = workspaceRoot();
  } on WorkspaceRootNotFound catch (e) {
    stderr.writeln(e.message);
    exit(1);
  }

  if (args.isNotEmpty) {
    stderr.writeln(
      'usage: dart run tool/generate_app_icons.dart\n'
      'It takes no arguments; replace $_source to change the icon.',
    );
    exit(1);
  }

  final sourcePath = '${root.path}/$_source';
  final sourceFile = File(sourcePath);
  if (!sourceFile.existsSync()) {
    stderr.writeln('No source icon at $sourcePath.');
    exit(1);
  }
  final decoded = img.decodeImage(sourceFile.readAsBytesSync());
  if (decoded == null) {
    stderr.writeln('Could not decode $sourcePath as an image.');
    exit(1);
  }
  if (decoded.width != decoded.height) {
    stderr.writeln(
      'The source must be square; $sourcePath is '
      '${decoded.width}x${decoded.height}.',
    );
    exit(1);
  }
  final source = decoded.convert(numChannels: 4);
  // iOS and the legacy Android icons drop the alpha channel without
  // compositing, so a transparent pixel would show whatever colour sits
  // under it.
  if (source.any((p) => p.a < 255)) {
    stderr.writeln(
      'The source must be opaque; $sourcePath has transparent pixels.',
    );
    exit(1);
  }
  if (source.width < 1024) {
    stderr.writeln(
      'warning: the source is ${source.width} px; the 1024 px iOS and '
      'macOS icons are scaled up from it.',
    );
  }

  final written = _Writer(root);

  // Web / PWA.
  const web = 'apps/browser/web';
  final maskable = _padded(source, 0.78);
  written
    ..png('$web/icons/Icon-192.png', _sized(source, 192))
    ..png('$web/icons/Icon-512.png', _sized(source, 512))
    ..png('$web/icons/Icon-maskable-192.png', _sized(maskable, 192))
    ..png('$web/icons/Icon-maskable-512.png', _sized(maskable, 512))
    ..png('$web/favicon.png', _sized(source, 64));

  // iOS: sizes come from the asset catalogue, so a new slot there is
  // picked up without editing this script.
  const ios = 'apps/mobile/ios/Runner/Assets.xcassets/AppIcon.appiconset';
  final contents = jsonDecode(
    File('${root.path}/$ios/Contents.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  for (final entry in contents['images'] as List<dynamic>) {
    final image = entry as Map<String, dynamic>;
    final filename = image['filename'] as String?;
    if (filename == null) continue;
    final points = double.parse((image['size'] as String).split('x').first);
    final scale = int.parse((image['scale'] as String).replaceAll('x', ''));
    final px = (points * scale).round();
    written.png('$ios/$filename', _opaque(_sized(source, px)));
  }

  // Android: 48 dp legacy icons, 108 dp adaptive foregrounds. The
  // adaptive safe zone is a 66 dp circle, so the artwork is shrunk to 0.6
  // of the canvas, under 66/108: the emblem's furthest point, the tip of
  // its lower-left arm, then sits about 32 dp from the centre.
  const res = 'apps/mobile/android/app/src/main/res';
  final adaptive = _padded(source, 0.6);
  const densities = {
    'mdpi': 48,
    'hdpi': 72,
    'xhdpi': 96,
    'xxhdpi': 144,
    'xxxhdpi': 192,
  };
  for (final MapEntry(key: density, value: px) in densities.entries) {
    written
      ..png('$res/mipmap-$density/ic_launcher.png', _opaque(_sized(source, px)))
      ..png(
        '$res/mipmap-$density/ic_launcher_foreground.png',
        _opaque(_sized(adaptive, px * 108 ~/ 48)),
      );
  }

  // macOS; Linux reuses app_icon_256.png.
  const mac = 'apps/desktop/macos/Runner/Assets.xcassets/AppIcon.appiconset';
  final tile = _macosTile(source);
  for (final px in const [16, 32, 64, 128, 256, 512, 1024]) {
    written.png('$mac/app_icon_$px.png', _sized(tile, px));
  }

  // Windows.
  written.bytes(
    'apps/desktop/windows/runner/resources/app_icon.ico',
    img.IcoEncoder().encodeImages([
      for (final px in const [16, 24, 32, 48, 64, 128, 256]) _sized(source, px),
    ]),
  );

  stdout.writeln('Wrote ${written.count} files from $sourcePath.');
}

/// [src] scaled to [px] square: box-averaged down, cubic up.
img.Image _sized(img.Image src, int px) => img.copyResize(
  src,
  width: px,
  height: px,
  interpolation: px < src.width
      ? img.Interpolation.average
      : img.Interpolation.cubic,
);

img.Image _opaque(img.Image src) => src.convert(numChannels: 3);

/// [src] shrunk to [scale] of a 1024 px canvas, its edge pixels extended
/// outward and blurred to fill the margin.
img.Image _padded(img.Image src, double scale) {
  const n = 1024;
  final inner = (n * scale).round();
  final art = _sized(src, inner);
  final offset = (n - inner) ~/ 2;
  final canvas = img.Image(width: n, height: n, numChannels: 4);
  for (var y = 0; y < n; y++) {
    final ay = (y - offset).clamp(0, inner - 1);
    for (var x = 0; x < n; x++) {
      final ax = (x - offset).clamp(0, inner - 1);
      canvas.setPixel(x, y, art.getPixel(ax, ay));
    }
  }
  img.gaussianBlur(canvas, radius: (n * 0.03).round());
  return img.compositeImage(canvas, art, dstX: offset, dstY: offset);
}

/// The macOS Big Sur icon shape: an 824/1024 rounded square, corner
/// radius 22.5% of its side, over a soft drop shadow.
img.Image _macosTile(img.Image src) {
  const n = 1024;
  const side = 824;
  const offset = (n - side) ~/ 2;
  const radius = side * 0.225;
  const drop = 12;

  final canvas = img.Image(width: n, height: n, numChannels: 4);
  img.fillRect(
    canvas,
    x1: offset,
    y1: offset + drop,
    x2: offset + side,
    y2: offset + side + drop,
    color: img.ColorRgba8(0, 0, 0, 90),
    radius: radius,
  );
  img.gaussianBlur(canvas, radius: drop);

  final art = _sized(src, side);
  final rounded = img.copyCrop(
    art,
    x: 0,
    y: 0,
    width: side,
    height: side,
    radius: radius,
  );
  return img.compositeImage(canvas, rounded, dstX: offset, dstY: offset);
}

class _Writer {
  _Writer(this.root);

  final Directory root;
  int count = 0;

  void png(String path, img.Image image) => bytes(path, img.encodePng(image));

  void bytes(String path, List<int> data) {
    File('${root.path}/$path')
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(data);
    count++;
  }
}
