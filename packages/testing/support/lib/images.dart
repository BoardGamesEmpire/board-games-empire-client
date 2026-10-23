/// Network image helpers for widget tests: a PNG served to every image
/// request, and a pump that waits for it to decode (#42).
///
/// Needs `dart:io`, for the `HttpClient` Flutter's image loading takes, which
/// is why it is a separate library from `widgets.dart`: a browser suite can
/// still import that one.
library;

export 'src/images/image_host.dart';
