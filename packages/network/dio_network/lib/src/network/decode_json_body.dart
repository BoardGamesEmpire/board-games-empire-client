import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Decodes a response body the transport was told not to touch.
///
/// Data sources that must classify a failure by HTTP status ask Dio for
/// `Response<String>` **and pin `responseType` per request** — together, not
/// either alone, keeps Dio out of the body. `DioMixin.fetch` forces
/// `responseType` from `T` — `String` gives `plain`, and **anything else,
/// `Object?` included, gives `json`**
/// (`dio-5.11.0/lib/src/dio_mixin.dart:419-427`) — but it skips that forcing
/// entirely for an instance already set to `bytes` or `stream` (`:419-421`),
/// so a caller that takes an arbitrary injected `Dio` has to pin it itself
/// rather than rely on the type argument alone.
///
/// Each way Dio can handle the body itself destroys the status. Unpinned on a
/// `bytes` or `stream` instance, `assureResponse` casts the bytes or the
/// stream to `String`, and the cast throws. Asking for
/// `Response<Map<String, dynamic>>` makes Dio cast the decoded body; asking
/// for anything non-`String` makes it `jsonDecode` a body whose *content type*
/// claims JSON. A cast failure or a `FormatException` each escape as
/// `DioException(type: unknown)` with **no response attached**, so a
/// status-based classifier sees null and calls a permanent failure transient —
/// which the drain then retries forever (#265, #182).
///
/// This is the canonical statement of that rule: every permissive `Dio` points
/// here from its `validateStatus` line, in both factories and in
/// `WellKnownClientImpl` (#276). The function is shared rather than copied so
/// the threshold below lives in one place.
///
/// ## Threshold
///
/// Reproduces the offload dio's default transformer applies, which taking
/// the body as a `String` otherwise loses. That transformer is
/// `FusedTransformer(contentLengthIsolateThreshold: 50 * 1024)`
/// (`dio_mixin.dart:50`): at 50 KB and above it decodes on another isolate
/// (`fused_transformer.dart:146-147`), so a large page does not jank the frame
/// it lands on. This function keeps the same 50 KB line and the same `>=`.
///
/// It measures differently, on purpose. dio counts **bytes**: the
/// `content-length` header, or the consolidated byte count when there is none
/// (`fused_transformer.dart:133-147`). This counts `codeUnits.length`, because
/// the bytes describe work that has **already happened**: for a `String` body
/// the transformer ran `utf8.decode` at `fused_transformer.dart:105` before
/// this function was handed the string, so they govern nothing here. What
/// remains is parse cost, which tracks the string being parsed. Measured on a
/// ~60 KB UTF-8 payload: 20k CJK code units parse in ~38us against ~69us for
/// 60k ASCII code units, so counting bytes would offload the *cheaper* body.
///
/// ## Failures
///
/// Throws [FormatException] when the body is not JSON — that is a statement
/// *about the response*: the same request will get the same unparseable body.
///
/// What that statement is worth is the caller's call, not this function's,
/// because it depends on what the caller loses by treating it as final
/// (#362). The callers in tree reach different answers, each for a stated
/// reason: `sendForJson` files it as permanent for every data source, since
/// the payload the source needed will not change; the well-known client reads
/// it as "this is not a BGE server"; the auth repositories file it as a
/// server fault that leaves the session undecided, since an unreadable body
/// is not proof the session is gone; and the feedback transport reports the
/// delivery as unconfirmed, so a captive portal does not cost the user their
/// words.
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
