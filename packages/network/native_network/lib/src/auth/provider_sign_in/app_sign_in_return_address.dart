/// The URL scheme a native provider sign-in comes back to the app under
/// (#583). The browser seam is handed it, so no adapter spells it again.
const String appSignInCallbackScheme = 'bge';

/// The host of [appSignInReturnAddress], beside `server` for deep links.
const String appSignInReturnHost = 'oauth';

/// The address the server sends the in-app browser tab back to at the end of
/// a native provider sign-in (#583), sent as `redirect_uri`.
///
/// The one place the client spells it. The Android callback filter and the
/// `bge` URL types on iOS and macOS register the same scheme and host, so a
/// change here is a change there too.
const String appSignInReturnAddress =
    '$appSignInCallbackScheme://$appSignInReturnHost';
