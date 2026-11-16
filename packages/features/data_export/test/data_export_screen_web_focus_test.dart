@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';

import 'support/web_focus_cases.dart';

/// Focus after a run with the web engine's semantics tree on, the state a
/// screen-reader user is in (#93). The control, with it off, is
/// `data_export_screen_web_focus_control_test.dart`: the engine keeps the
/// tree on for the rest of the page once it is on, so the two can't share a
/// file.
void main() => webFocusCases(semantics: true);
