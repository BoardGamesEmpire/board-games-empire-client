import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Answers every network image request with [png], for as long as [body]
/// runs, through Flutter's `debugNetworkImageHttpClientProvider` (#42).
///
/// The test binding answers every HTTP request with a 400, so a test that
/// needs a network image to load has to serve it. The hook is set back to
/// null, and the image cache cleared, before this returns: the binding
/// fails a test that leaves the hook set, and a cached image would answer
/// the next test's request.
Future<T> servingImages<T>(Uint8List png, Future<T> Function() body) async {
  debugNetworkImageHttpClientProvider = () => _ImageHost(png);
  try {
    return await body();
  } finally {
    debugNetworkImageHttpClientProvider = null;
    imageCache.clear();
  }
}

/// A solid [width] x [height] PNG, in `Paint`'s default black. It encodes
/// for real, so the call needs real async work:
/// `tester.runAsync(() => solidPng(...))`.
Future<Uint8List> solidPng(int width, int height) async {
  final recorder = ui.PictureRecorder();
  Canvas(recorder).drawRect(
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Paint(),
  );
  final image = await recorder.endRecording().toImage(width, height);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

/// Pumps until [finder] finds a [RawImage], which an `Image` builds once its
/// first frame has decoded, and returns that image's decoded size.
///
/// The load and the decode run outside fake time, so each attempt lets real
/// time pass before it pumps. Fails when no image has decoded after
/// [attempts] of them.
Future<Size> pumpUntilDecoded(
  WidgetTester tester,
  Finder finder, {
  int attempts = 20,
}) async {
  final raw = find.descendant(of: finder, matching: find.byType(RawImage));
  for (var i = 0; i < attempts && raw.evaluate().isEmpty; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
  expect(raw, findsOneWidget, reason: 'no image decoded');
  final image = tester.widget<RawImage>(raw).image!;
  return Size(image.width.toDouble(), image.height.toDouble());
}

class _ImageHost extends Fake implements HttpClient {
  _ImageHost(this._png);

  final Uint8List _png;

  @override
  bool autoUncompress = false;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async => _Request(_png);
}

class _Request extends Fake implements HttpClientRequest {
  _Request(this._png);

  final Uint8List _png;

  @override
  Future<HttpClientResponse> close() async => _Response(_png);
}

class _Response extends Fake implements HttpClientResponse {
  _Response(this._png);

  final Uint8List _png;

  @override
  int get statusCode => HttpStatus.ok;

  @override
  int get contentLength => _png.length;

  @override
  HttpClientResponseCompressionState get compressionState =>
      HttpClientResponseCompressionState.notCompressed;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(_png).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
}
