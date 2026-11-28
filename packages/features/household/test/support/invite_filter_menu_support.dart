import 'dart:io';

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Whether keyboard focus is on [target] or inside it.
bool focusIn(Finder target) {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context is! Element) return false;
  final targets = target.evaluate().toSet();
  if (targets.contains(context)) return true;
  var found = false;
  context.visitAncestorElements((element) {
    found = targets.contains(element);
    return !found;
  });
  return found;
}

/// Presses Tab until focus reaches [target], as a keyboard user would.
Future<void> tabTo(WidgetTester tester, Finder target) async {
  for (var i = 0; i < 20 && !focusIn(target); i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
  }
  expect(focusIn(target), isTrue, reason: 'Tab never reached $target');
}

/// Presses [key] and lets what it starts finish. One more frame after a
/// settle, because a menu item acts after a frame.
Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
  await tester.pump();
}

/// Checks that [finder]'s text wraps between words, never inside one: each
/// word's glyphs sit on a single line. A label that breaks mid-word neither
/// overflows nor exceeds its lines, so nothing else sees it.
void expectWholeWords(WidgetTester tester, Finder finder) {
  final paragraph = tester.renderObject<RenderParagraph>(finder);
  final text = paragraph.text.toPlainText();
  for (final word in RegExp(r'\S+').allMatches(text)) {
    final lines = paragraph
        .getBoxesForSelection(
          TextSelection(baseOffset: word.start, extentOffset: word.end),
        )
        .map((box) => box.top.round())
        .toSet();
    expect(
      lines,
      hasLength(1),
      reason: '"${word.group(0)}" in "$text" breaks across lines',
    );
  }
}

/// Loads Roboto, the face Android draws the filter's label role in, from
/// the Flutter SDK's own Material fonts, so a test measures the words at
/// the width a phone gives them (#475). The test font's glyphs are each an
/// em wide, which breaks words a phone keeps whole.
///
/// Fails rather than skips without the fonts: every `flutter test` run
/// fetches them into the SDK's cache. A loaded font stays for the rest of
/// the file, so keep such tests in a file of their own.
Future<void> loadPlatformLabelFont() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  final root = Platform.environment['FLUTTER_ROOT'];
  expect(root, isNotNull, reason: 'flutter test sets FLUTTER_ROOT');
  final fonts = '$root/bin/cache/artifacts/material_fonts';
  Future<ByteData> font(String name) async {
    final file = File('$fonts/$name');
    expect(file.existsSync(), isTrue, reason: '${file.path} is missing');
    return ByteData.sublistView(file.readAsBytesSync());
  }

  await (FontLoader('Roboto')
        ..addFont(font('Roboto-Regular.ttf'))
        ..addFont(font('Roboto-Medium.ttf')))
      .load();
}
