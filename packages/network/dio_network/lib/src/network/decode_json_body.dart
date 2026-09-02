import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Decodes a response body the transport was told not to touch.
///
/// Data sources that must classify a failure by HTTP status ask Dio for
/// `Response<String>`, because that is the only type argument which keeps Dio
/// out of the body: `DioMixin.fetch` forces `responseType` from `T` — `String`
/// gives `plain`, and **anything else, `Object?` included, gives `json`**
/// (`dio-5.11.0/lib/src/dio_mixin.dart:417-427`).
///
/// Either half of Dio's own handling destroys the status. Asking for
/// `Response<Map<String, dynamic>>` makes Dio cast the decoded body; asking for
/// anything non-`String` makes it `jsonDecode` a body whose *content type*
/// claims JSON. A cast failure or a `FormatException` both escape as
/// `DioException(type: unknown)` with **no response attached**, so a
/// status-based classifier sees null and calls a permanent failure transient —
/// which the drain then retries forever (#265, #182).
///
/// Shared rather than copied so the threshold below lives in one place; a third
/// caller is expected on #351.
///
/// ## Threshold
///
/// Reproduces the rule dio's own `BackgroundTransformer` applies
/// (`background_transformer.dart:15-25`), which taking the body as a `String`
/// otherwise loses: below 50 KB decode inline, above it hand the work to
/// another isolate so a large page does not janks the frame it lands on.
///
/// ## Failures
///
/// Throws [FormatException] when the body is not JSON — that is a statement
/// *about the response*, and callers should treat it as permanent.
///
/// Anything else means decoding itself could not be performed — in practice a
/// failure to spawn the offload isolate under resource pressure. That says
/// nothing about the response and callers must **not** treat it as permanent:
/// discarding queued work over a local, momentary fault is the data-loss shape
/// #297 exists to prevent. It is left to propagate as itself rather than
/// disguised as a `FormatException`, so callers can tell the two apart.
Future<Object?> decodeJsonBody(String text) async =>
    text.codeUnits.length < _isolateThresholdBytes
    ? jsonDecode(text)
    : await compute(jsonDecode, text);

const int _isolateThresholdBytes = 50 * 1024;
