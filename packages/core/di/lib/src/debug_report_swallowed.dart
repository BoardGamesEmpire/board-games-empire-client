import 'package:flutter/foundation.dart';
import 'package:observability/observability.dart';

/// Debug-only console line for an error `di` swallows on purpose, as `what:
/// error`. Release builds print nothing.
///
/// It prints directly, past the log sinks, so it removes a database error's
/// bound values itself (#463). Every direct print of an error in `di` comes
/// through here so that none of them misses it.
void debugReportSwallowed(String what, Object error) {
  assert(() {
    debugPrint('$what: ${Redaction.stripBoundValues(error.toString())}');
    return true;
  }());
}
