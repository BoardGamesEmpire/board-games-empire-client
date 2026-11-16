@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';

import 'support/web_focus_cases.dart';

/// The control for `data_export_screen_web_focus_test.dart`: the same
/// steps with the web engine's semantics tree off, as it is until assistive
/// technology asks for it (#93).
void main() => webFocusCases(semantics: false);
