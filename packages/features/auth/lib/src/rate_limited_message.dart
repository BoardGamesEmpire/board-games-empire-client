import 'package:auth/l10n/auth_localizations.dart';

/// The rate-limit copy for a sign-in, a sign-up or a provider sign-in
/// (#559), and for a link or an unlink of a sign-in provider (#582). A wait
/// under a second would read "in 0 seconds", which is no advice, so it reads
/// as no wait.
String rateLimitedMessage(AuthLocalizations l10n, Duration? retryAfter) =>
    retryAfter == null || retryAfter < const Duration(seconds: 1)
    ? l10n.authErrorRateLimitedNoWait
    : l10n.authErrorRateLimited(retryAfter.inSeconds);
