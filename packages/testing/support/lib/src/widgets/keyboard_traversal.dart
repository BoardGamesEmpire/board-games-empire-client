import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Tabs from the current focus until focus wraps to where it started, or until
/// [maxSteps] (#50). Returns one name per stop, the one a screen reader reads
/// for it. That is the label of the semantics node at or above the focused
/// element (`tester.getSemantics`), with whatever is merged into it from below,
/// else that node's tooltip. Without either, the stop is named by its
/// `FocusNode`'s `debugLabel`, else `<unnamed>`, so `<unnamed>` means a screen
/// reader has no name to read for it.
///
/// Needs `tester.ensureSemantics()` held by the caller, or no label can be
/// read. [reverse] walks with Shift held, i.e. Shift+Tab.
///
/// A focused control is the walk's first stop; with nothing focused, the first
/// Tab lands on the first stop. Either way the walk ends when focus returns to
/// that first stop, or when it leaves the page's controls: to nothing, or to a
/// scope, which Tab lands on only when nothing inside it can take focus.
Future<List<String>> tabOrder(
  WidgetTester tester, {
  int maxSteps = 60,
  bool reverse = false,
}) async => (await _walk(tester, maxSteps, reverse)).names;

/// One Tab walk: the stops by name, the same stops by `FocusNode`, whether
/// focus wrapped back to the first stop, the node that repeated, if any, and
/// whether focus left the page's controls instead.
class _Walk {
  final names = <String>[];
  final nodes = <FocusNode>[];
  bool wrapped = false;
  FocusNode? repeated;

  /// Focus went to nothing, or to a scope: off the page's controls, not
  /// round them.
  bool escaped = false;

  /// The scope focus went to when it [escaped], or null for nothing.
  FocusScopeNode? escapedTo;
}

Future<_Walk> _walk(WidgetTester tester, int maxSteps, bool reverse) async {
  final walk = _Walk();
  final initial = FocusManager.instance.primaryFocus;
  if (initial != null &&
      initial is! FocusScopeNode &&
      initial.context != null) {
    walk.nodes.add(initial);
    walk.names.add(_nameOf(tester, initial));
  }

  for (var i = 0; i < maxSteps; i++) {
    await _tab(tester, reverse: reverse);
    final focus = FocusManager.instance.primaryFocus;
    if (focus == null || focus is FocusScopeNode) {
      walk
        ..escaped = true
        ..escapedTo = focus is FocusScopeNode ? focus : null;
      break;
    }
    if (walk.nodes.isNotEmpty && focus == walk.nodes.first) {
      walk.wrapped = true;
      break;
    }
    if (walk.nodes.contains(focus)) {
      walk.repeated = focus;
      break;
    }
    walk.nodes.add(focus);
    walk.names.add(_nameOf(tester, focus));
  }

  return walk;
}

/// Fails if a stop repeats before the walk wraps (a trap), if focus leaves the
/// page's controls rather than wrapping (to nothing, or to a scope), if
/// [maxSteps] is hit without wrapping, or if `tabOrder(reverse: true)` is not
/// `tabOrder()` reversed (#50). With [expectedOrder], the forward walk must
/// equal it.
///
/// Both walks start from the page with no control focused, so the first Tab
/// lands on the page's first stop and the first Shift+Tab on its last. A
/// control that had focus is unfocused first; a route's scope that had it
/// keeps it.
///
/// A repeat is the same `FocusNode` coming round twice, not the same label:
/// several rows may each carry a "Delete" button.
Future<void> expectTraversable(
  WidgetTester tester, {
  List<String>? expectedOrder,
  int maxSteps = 60,
}) async {
  await _focusPage(tester);
  final forward = await _walk(tester, maxSteps, false);

  final repeated = forward.repeated;
  if (repeated != null) {
    final name = forward.names[forward.nodes.indexOf(repeated)];
    fail(
      'Keyboard trap: "$name" repeats before focus wraps. '
      'Order: ${forward.names}',
    );
  }
  if (forward.escaped) {
    final to = forward.escapedTo;
    final from = forward.names.isEmpty
        ? 'the start'
        : '"${forward.names.last}"';
    final onto = to == null ? 'nothing' : 'the scope ${to.debugLabel ?? to}';
    fail(
      'Focus left the page instead of wrapping: Tab after $from put it on '
      '$onto. Order: ${forward.names}',
    );
  }
  if (!forward.wrapped) {
    fail(
      'Focus never wrapped within $maxSteps Tab presses. '
      'Order so far: ${forward.names}',
    );
  }
  if (expectedOrder != null) {
    expect(forward.names, expectedOrder, reason: 'Tab order');
  }

  await _focusPage(tester);
  final backward = await tabOrder(tester, maxSteps: maxSteps, reverse: true);
  expect(
    backward,
    forward.names.reversed.toList(),
    reason: 'Shift+Tab must walk Tab order backwards',
  );
}

/// Presses Tab until [control]'s focus node has primary focus, then presses
/// Enter and settles (#50). Fails if Tab doesn't reach it within [maxSteps].
///
/// [control] may find the control itself, such as `find.byType(FilledButton)`,
/// whose node sits below it in its `InkWell`, or something inside it, such as
/// its label: see [_focusNodeOf].
///
/// A focused control is its own first stop: with [control] already focused,
/// no Tab is pressed.
Future<void> activateByKeyboard(
  WidgetTester tester,
  Finder control, {
  int maxSteps = 60,
}) async {
  final target = _focusNodeOf(tester, control);
  for (var i = 0; i < maxSteps && !target.hasPrimaryFocus; i++) {
    await _tab(tester);
  }
  if (!target.hasPrimaryFocus) {
    fail('Tab never reached $control within $maxSteps presses.');
  }

  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.pumpAndSettle();
}

/// Activates [opener] by keyboard ([activateByKeyboard]), runs [dismiss],
/// settles, and expects the primary focus to be [opener]'s node again (#50).
Future<void> expectFocusReturnsAfterDialog(
  WidgetTester tester, {
  required Finder opener,
  required Future<void> Function() dismiss,
  int maxSteps = 60,
}) async {
  final target = _focusNodeOf(tester, opener);

  await activateByKeyboard(tester, opener, maxSteps: maxSteps);

  await dismiss();
  await tester.pumpAndSettle();

  expect(
    FocusManager.instance.primaryFocus,
    same(target),
    reason: 'Focus must return to the opener once the dialog closes',
  );
}

/// The focus node of the control [control] finds (#50).
///
/// The first Tab stop at or below the found element, in tree order: a button
/// widget builds its `Focus` below itself, in its `InkWell`, so
/// `find.byType(FilledButton)` or a key on one finds an element above its own
/// node. A stop is a node that can take focus and that Tab doesn't skip, so a
/// `FocusTraversalGroup`'s node or a scope inside the control is passed over.
/// With none below, as for a finder on a button's label, it is the nearest
/// node above the element, the label's button's.
FocusNode _focusNodeOf(WidgetTester tester, Finder control) {
  final element = tester.element(control);
  final byContext = <BuildContext?, FocusNode>{
    for (final node in FocusManager.instance.rootScope.descendants)
      node.context: node,
  };
  FocusNode? found;
  void visit(Element e) {
    if (found != null) return;
    final node = byContext[e];
    if (node != null &&
        node is! FocusScopeNode &&
        node.canRequestFocus &&
        !node.skipTraversal) {
      found = node;
      return;
    }
    e.visitChildren(visit);
  }

  visit(element);
  return found ?? Focus.of(element);
}

Future<void> _tab(WidgetTester tester, {bool reverse = false}) async {
  if (reverse) await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
  await tester.sendKeyEvent(LogicalKeyboardKey.tab);
  if (reverse) await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
  await tester.pump();
}

/// Leaves focus on the page with no control focused, so the next Tab lands on
/// the page's first stop (#50).
///
/// A focused control is unfocused, which hands focus to its scope, the route,
/// and makes the scope forget it. A focused scope is left as it is: it already
/// has no control focused. Unfocusing it would hand focus to the scope above
/// it. Under `MaterialApp(home:)` that is the "Navigator Scope", but a router
/// app (`MaterialApp.router`, as `BgeApp` is) has none, so focus would land on
/// the View's own scope, above the app's keyboard shortcuts, where Tab does
/// nothing.
Future<void> _focusPage(WidgetTester tester) async {
  final focus = FocusManager.instance.primaryFocus;
  if (focus != null && focus is! FocusScopeNode) focus.unfocus();
  await tester.pump();
}

/// What a screen reader reads for [focus]'s stop: see [tabOrder].
///
/// `getSemanticsData`, not the node's own `label`: a node that merges its
/// children, as a floating action button or a segmented button's segment
/// does, has an empty label of its own. The tooltip, because an icon button
/// is named by it, and every platform reads it as the name: iOS and web join
/// it to the label, and Android hands it to TalkBack as the tooltip text.
String _nameOf(WidgetTester tester, FocusNode focus) {
  final context = focus.context;
  if (context != null) {
    final data = tester
        .getSemantics(find.byElementPredicate((e) => e == context))
        .getSemanticsData();
    if (data.label.isNotEmpty) return data.label;
    if (data.tooltip.isNotEmpty) return data.tooltip;
  }
  return focus.debugLabel ?? '<unnamed>';
}
