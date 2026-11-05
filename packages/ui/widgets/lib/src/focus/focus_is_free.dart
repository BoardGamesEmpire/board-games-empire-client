import 'package:flutter/widgets.dart';

/// Whether keyboard focus is on no control: on nothing, on the page holding
/// [context], or on a scope that page sits inside. A scope anywhere else
/// belongs to another route, such as a menu or a dialog that has just opened,
/// and isn't this page's to take focus from.
///
/// Focus still on [untouched] counts as free too. A hand-off passes the node
/// that had focus when it was set off, so that only focus moved since keeps
/// it from taking over: a control that goes leaves focus on nothing after
/// the frame that takes it away, but on itself while an exit animation still
/// shows it, as a floating action button's does.
bool focusIsFree(BuildContext context, {FocusNode? untouched}) {
  final focused = FocusManager.instance.primaryFocus;
  if (focused == null || focused == untouched) return true;
  if (focused is! FocusScopeNode) return false;
  final page = FocusScope.of(context, createDependency: false);
  return focused == page || page.ancestors.contains(focused);
}
