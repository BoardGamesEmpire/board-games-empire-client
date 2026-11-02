import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Lets a bloc event reach the screen, without waiting for anything to
/// settle: a busy cue never does.
Future<void> pumpEvent(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

/// Taps [control] once it is in view, and lets what it asked for reach the
/// screen.
Future<void> press(WidgetTester tester, Finder control) async {
  await tester.ensureVisible(control);
  await tester.pump();
  await tester.tap(control);
  await pumpEvent(tester);
}

/// Puts keyboard focus on the control around its [label], as Tab would.
Future<void> focusOn(WidgetTester tester, Finder label) async {
  Focus.of(tester.element(label)).requestFocus();
  await tester.pump();
}

/// Presses the focused control from the keyboard.
Future<void> pressKey(WidgetTester tester) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.space);
  await pumpEvent(tester);
}

/// Whether keyboard focus is on [control], or inside it.
bool focusIsIn(WidgetTester tester, Finder control) {
  final focused = FocusManager.instance.primaryFocus?.context;
  if (focused == null) return false;
  final target = tester.element(control);
  if (identical(focused, target)) return true;
  var inside = false;
  focused.visitAncestorElements((ancestor) {
    inside = identical(ancestor, target);
    return !inside;
  });
  return inside;
}
