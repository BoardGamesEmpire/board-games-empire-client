import 'package:flutter/material.dart';
import 'package:interfaces/repositories.dart'
    show
        ProviderSignInAddressMismatch,
        ProviderSignInAvailability,
        ProviderSignInAvailable,
        ProviderSignInFailureReason,
        ProviderSignInUnsupportedDevice;
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:models/domain.dart' hide ConnectionState;

import '../../l10n/auth_localizations.dart';
import '../bloc/auth_bloc.dart';
import '../bloc/auth_event.dart';
import '../bloc/auth_bloc_state.dart';
import '../widgets/login_form.dart';
import '../widgets/register_form.dart';
import '../widgets/oidc_strategy_button.dart';

/// Top-level authentication screen.
///
/// Strategy-aware: renders exactly the forms and buttons that the server
/// advertises via [identity]. If the server disables registration,
/// the registration form and toggle link are suppressed, and the same goes
/// once the server refuses a registration while the screen is up (#443).
///
/// Accessibility:
/// - Operation failures surface in a banner directly above the submit that
///   produced them, through the form's [BgeFormActions] (#211). It announces
///   itself on appearance. The screen stays put through a failure, so the
///   message belongs on it rather than in a SnackBar (#191).
/// - A provider sign-in's failure has its own banner, directly above the
///   provider buttons, so a server that offers only providers still has a
///   surface for it, and the email form never shows it (#583).
/// - While a provider sign-in is open in the browser, the provider buttons
///   stay focusable and ignore presses, so a screen-reader user coming back
///   lands on the button they pressed (#583). Where this device or this
///   server can't offer provider sign-in, they are disabled, and say why.
/// - Focus is managed between sign-in/register mode switches
/// - Server name displayed so screen readers can identify which server
///   the user is authenticating against
/// - The unsent-changes notice (#142) sits above the forms in reading order
///   and announces itself once when it appears, without taking focus.
///
/// i18n (#37): all copy comes from [AuthLocalizations]; the bloc emits
/// semantic failure kinds ([AuthOperationFailure]) which
/// [_localizedFailure] maps to localized messages here — never in the
/// bloc.
///
/// Callers are responsible for navigating away when the bloc emits
/// [AuthAuthenticated] — typically via a [BlocListener] in the router.
class AuthScreen extends StatefulWidget {
  const AuthScreen({
    super.key,
    required this.identity,
    required this.serverDisplayName,
    this.unsentChangesCount,
    this.splash,
  });

  /// Key on the operation-failure banner, for tests.
  static const Key failureBannerKey = Key('auth_failure_banner');

  /// Key on the provider sign-in failure banner, for tests (#583).
  static const Key providerFailureBannerKey = Key(
    'auth_provider_failure_banner',
  );

  /// Key on the unsent-changes notice, for tests.
  static const Key unsentChangesNoticeKey = Key('auth_unsent_changes_notice');

  /// The server identity for this auth context. Drives which strategies
  /// are shown and which endpoints are used.
  final ServerIdentity identity;

  /// Human-readable server name shown above the form for context.
  final String serverDisplayName;

  /// How many changes made on this device haven't reached the server, for a
  /// session that ended without the user signing out (#142). Read once when
  /// the screen appears; above zero, a notice says so above the forms.
  ///
  /// Null where nothing can count them: compositions without the per-server
  /// count. Native and web both register one. The screen never learns whose
  /// changes they are.
  final Future<int> Function()? unsentChangesCount;

  /// Shown in place of the page while [unsentChangesCount] is read, so the
  /// notice arrives with the forms rather than pushing them down after they
  /// have painted (#142). Blank where none is given.
  ///
  /// [AuthGate] passes its own splash, so a cold start reads as one
  /// continuous splash. The caller bounds the read; this screen waits for
  /// it.
  final Widget? splash;

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  /// Whether the user is in sign-in or register mode.
  /// Only relevant while registration is offered: when
  /// [EmailAndPasswordStrategy.signUpDisabled] is false and
  /// [_registrationClosed] is not set.
  bool _isSignIn = true;

  /// Whether the server has refused a registration on this screen.
  ///
  /// Discovery was read before the form was shown, and a server can close
  /// registration after that (#443). Once it refuses, the register form
  /// stays up to show the refusal, and its submit still works: another try
  /// gets the same refusal. Once the user switches to sign-in, the screen
  /// no longer offers registration. Set once and never cleared, so it lasts
  /// only as long as the screen. A newly built one reads the cached identity
  /// again and offers registration until #87 refreshes it.
  bool _registrationClosed = false;

  /// Whether provider sign-in can run here (#583). It follows from the device
  /// and the server's discovery, so it is read when the screen appears and
  /// again whenever the gate rebuilds it, which it does for a new
  /// [AuthScreen.identity] as well as on every auth state. The provider
  /// buttons come from the identity as it is now, so their availability has
  /// to as well.
  late ProviderSignInAvailability _providerAvailability;

  /// How many provider sign-ins this screen has started. The provider banner
  /// is keyed by it, so each attempt's failure is a banner of its own (#583).
  ///
  /// An attempt can fail before the next frame: web offline, or a platform
  /// channel that fails at once. The clear and the attempt's progress then
  /// never reach the screen, and a repeat of the same failure would rebuild
  /// the old banner with the same copy. It would be neither announced nor
  /// revealed, and the press would seem to have done nothing.
  int _providerAttempt = 0;

  /// Read when the screen appears rather than in build: the page rebuilds on
  /// every failure, and the count only changes when a session starts. That
  /// normally takes the user off this screen, and the one that comes back
  /// reads afresh. A session that starts and ends before the next frame
  /// never shows the gate's splash, so this screen stays up and reads again
  /// itself (#142).
  Future<int>? _unsentChangesCount;

  @override
  void initState() {
    super.initState();
    _readProviderAvailability();
    _readUnsentChangesCount();
  }

  @override
  void didUpdateWidget(AuthScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    _readProviderAvailability();
  }

  void _readProviderAvailability() {
    _providerAvailability = context.read<AuthBloc>().providerSignInAvailability;
  }

  // A block body: as an arrow, it would hand setState the future.
  void _readUnsentChangesCount() {
    _unsentChangesCount = widget.unsentChangesCount?.call();
  }

  @override
  Widget build(BuildContext context) {
    return MultiBlocListener(
      listeners: [
        BlocListener<AuthBloc, AuthBlocState>(
          listenWhen: (previous, current) =>
              previous is AuthAuthenticated && current is! AuthAuthenticated,
          listener: (_, _) => setState(_readUnsentChangesCount),
        ),
        BlocListener<AuthBloc, AuthBlocState>(
          listenWhen: (_, current) =>
              current is AuthFailureRegistrationDisabled,
          listener: (_, _) => setState(() => _registrationClosed = true),
        ),
      ],
      child: _buildCounted(context),
    );
  }

  Widget _buildCounted(BuildContext context) {
    final count = _unsentChangesCount;
    if (count == null) return _buildPage(context, unsentChanges: 0);
    return FutureBuilder<int>(
      future: count,
      builder: (context, snapshot) =>
          snapshot.connectionState == ConnectionState.done
          // A count that can't be read shows no notice rather than an error:
          // the user came here to sign in, and the shell logs the failure.
          ? _buildPage(context, unsentChanges: snapshot.data ?? 0)
          : widget.splash ?? const SizedBox.shrink(),
    );
  }

  Widget _buildPage(BuildContext context, {required int unsentChanges}) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    // Scoped to the failure surface: the OIDC section and both forms hold
    // their own narrower builders, and an unscoped rebuild here would make
    // those pointless by rebuilding the whole page on every tick. An email
    // failure is rendered by the form, above its submit; this screen owns the
    // copy, the title and the key, and hands them down. A provider failure is
    // the provider section's, which its own builder rebuilds for (#583).
    return BlocBuilder<AuthBloc, AuthBlocState>(
      buildWhen: (previous, current) =>
          previous is AuthOperationFailure || current is AuthOperationFailure,
      builder: (context, state) => BgePage(
        centerVertically: true,
        // Wider vertical breathing room than the default: this is the first
        // screen after server-add and carries no app bar, so the form would
        // otherwise sit hard against the status bar.
        padding: EdgeInsets.symmetric(
          horizontal: BgeTokens.of(context).spaceLg,
          vertical: BgeTokens.of(context).spaceXl,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeader(context, colorScheme),
            const BgeGap.xl(),
            if (unsentChanges > 0) ...[
              _buildUnsentChangesNotice(context, unsentChanges),
              const BgeGap.lg(),
            ],
            if (widget.identity.hasEmailAndPassword)
              _buildEmailPasswordSection(context, state),
            if (widget.identity.hasEmailAndPassword &&
                widget.identity.hasOidc) ...[
              const BgeGap.lg(),
              _buildDivider(context),
              const BgeGap.lg(),
            ],
            if (widget.identity.hasOidc) _buildOidcSection(context),
            if (!widget.identity.hasEmailAndPassword &&
                !widget.identity.hasOidc) ...[
              // A web page back from a provider the server has since dropped,
              // on a server with nothing else left, still says why (#583).
              if (state case final AuthFailureProviderSignIn failure)
                ..._buildProviderFailure(context, failure),
              _buildNoStrategiesMessage(context),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, ColorScheme colorScheme) {
    final l10n = AuthLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Server attribution — important when user manages multiple servers
        Semantics(
          label: '${l10n.authServerLabel}: ${widget.serverDisplayName}',
          // The label carries the name; the visible text would repeat it (#50).
          excludeSemantics: true,
          child: Row(
            children: [
              Icon(
                Icons.dns_outlined,
                size: 16,
                color: colorScheme.onSurfaceVariant,
              ),
              const BgeGap.xs(axis: Axis.horizontal),
              Flexible(
                child: Text(
                  widget.serverDisplayName,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: colorScheme.onSurfaceVariant),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        const BgeGap.sm(),
        // A live region rather than a `SemanticsService` announcement: this
        // heading IS the thing that changes when the user switches modes, so
        // the change announces itself. Android deprecated announcement events
        // because they clear TalkBack's speech queue mid-utterance — the
        // style guide's standing rule, which the old `_switchMode` call
        // predated.
        Semantics(
          liveRegion: true,
          header: true,
          child: Text(
            _isSignIn ? l10n.authSignInTitle : l10n.authRegisterTitle,
            style: Theme.of(context).textTheme.headlineMedium
                ?.copyWith(fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }

  /// The #142 notice. Says how many changes are waiting and that signing in
  /// with the same account sends them; never whose they are, nor that
  /// anything failed or was lost.
  ///
  /// [BgeBannerTone.warning]: it needs the user's attention, and nothing has
  /// failed.
  Widget _buildUnsentChangesNotice(BuildContext context, int waiting) =>
      BgeInlineBanner(
        key: AuthScreen.unsentChangesNoticeKey,
        tone: BgeBannerTone.warning,
        // Furniture for as long as the screen stays up, already near its
        // top: announced on arrival, but not an outcome to scroll to.
        reveal: false,
        message: AuthLocalizations.of(context).authUnsentChangesNotice(waiting),
      );

  Widget _buildEmailPasswordSection(BuildContext context, AuthBlocState state) {
    final strategy = widget.identity.emailAndPasswordStrategy!;
    final canRegister = !strategy.signUpDisabled && !_registrationClosed;
    final l10n = AuthLocalizations.of(context);

    // Apart from a provider sign-in's, every operation failure answers
    // sign-in or register, so the form that is showing is the one whose
    // submit it answers. A provider sign-in's failure is the provider
    // section's: exactly one surface shows a given failure (#583). Where the
    // server lists no providers there is no such section, so the form shows
    // it. A web page that comes back with a refusal from a provider the
    // server has since dropped still says why.
    BgeFormFailure? failureTitled(String title) => switch (state) {
      AuthFailureProviderSignIn() when widget.identity.hasOidc => null,
      final AuthOperationFailure kind => BgeFormFailure(
        key: AuthScreen.failureBannerKey,
        // Titled because some of the messages give only a cause: "Could not
        // reach the server" never says that signing in failed (#211).
        title: title,
        message: _localizedFailure(l10n, kind),
      ),
      _ => null,
    };

    if (_isSignIn) {
      return LoginForm(
        failure: failureTitled(l10n.authSignInErrorTitle),
        onSwitchToRegister: canRegister
            ? () => _switchMode(signIn: false)
            : null,
      );
    } else {
      return RegisterForm(
        failure: failureTitled(l10n.authRegisterErrorTitle),
        onSwitchToSignIn: () => _switchMode(signIn: true),
      );
    }
  }

  /// The provider buttons, with a provider sign-in's failure above them and,
  /// where the server's address doesn't match, a note below (#583).
  Widget _buildOidcSection(BuildContext context) {
    final availability = _providerAvailability;
    final available = availability is ProviderSignInAvailable;
    final unavailableOnDevice = availability is ProviderSignInUnsupportedDevice;

    return BlocBuilder<AuthBloc, AuthBlocState>(
      // What this section shows: which sign-in is open, and a provider
      // failure. Every other change leaves it as it was.
      buildWhen: (previous, current) =>
          previous is AuthLoading ||
          current is AuthLoading ||
          previous is AuthFailureProviderSignIn ||
          current is AuthFailureProviderSignIn,
      builder: (context, state) {
        final l10n = AuthLocalizations.of(context);
        // While a provider's sign-in is open, its button is busy and the
        // others are inert with it. None drops the focus of a user on it, so
        // one back from the browser lands where they were.
        final openProvider = state is AuthLoading ? state.providerId : null;
        // An email sign-in or a sign-out is in flight. The buttons are
        // unavailable for a press that isn't theirs, so they have no focus
        // to keep, and are disabled (STYLE_GUIDE §5).
        final otherInFlight = state is AuthLoading && openProvider == null;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (state case final AuthFailureProviderSignIn failure)
              ..._buildProviderFailure(context, failure),
            for (final oidcStrategy in widget.identity.oidcStrategies) ...[
              OidcStrategyButton(
                // Keyed, so a banner arriving above keeps each button, and
                // the focus on it.
                key: ValueKey(oidcStrategy.providerId),
                strategy: oidcStrategy,
                busy: openProvider == oidcStrategy.providerId,
                inert: openProvider != null,
                unavailableOnDevice: unavailableOnDevice,
                onPressed: available && !otherInFlight
                    ? () => _signInWithProvider(oidcStrategy)
                    : null,
              ),
              const BgeGap.sm(),
            ],
            // Built only in this state: a note always in the tree would
            // leave its gap everywhere else.
            if (availability case ProviderSignInAddressMismatch(
              :final configuredAddress,
            ))
              Semantics(
                container: true,
                child: Text(
                  // A URL, inserted as the server reports it.
                  l10n.authProviderAddressMismatch(configuredAddress),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  /// A provider sign-in's failure, and the gap below it (#583).
  List<Widget> _buildProviderFailure(
    BuildContext context,
    AuthFailureProviderSignIn failure,
  ) {
    final l10n = AuthLocalizations.of(context);
    return [
      // A new banner for each attempt, so a repeated failure is announced and
      // revealed again. See [_providerAttempt].
      KeyedSubtree(
        key: ValueKey(_providerAttempt),
        child: BgeInlineBanner(
          key: AuthScreen.providerFailureBannerKey,
          tone: BgeBannerTone.error,
          // Titled because some of the messages give only a cause: "Could not
          // reach the server" never says that signing in failed (#211).
          title: l10n.authSignInErrorTitle,
          message: _localizedFailure(l10n, failure),
        ),
      ),
      // The gap `BgeFormActions` puts between a banner and its submit.
      const BgeGap.md(),
    ];
  }

  Widget _buildDivider(BuildContext context) {
    return Row(
      children: [
        const Expanded(child: Divider()),
        Padding(
          padding: EdgeInsets.symmetric(
            horizontal: BgeTokens.of(context).spaceMd,
          ),
          child: Text(
            AuthLocalizations.of(context).authOrDivider,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const Expanded(child: Divider()),
      ],
    );
  }

  Widget _buildNoStrategiesMessage(BuildContext context) {
    return BgeEmptyState(
      title: AuthLocalizations.of(context).authNoStrategiesMessage,
    );
  }

  /// The single place the sealed failure kinds become user-facing copy.
  /// Exhaustive: a new kind fails compilation here until it gets a
  /// localized message.
  String _localizedFailure(
    AuthLocalizations l10n,
    AuthOperationFailure f,
  ) => switch (f) {
    AuthFailureInvalidCredentials() => l10n.authErrorInvalidCredentials,
    AuthFailureEmailAlreadyExists() => l10n.authErrorEmailExists,
    AuthFailureRegistrationDisabled() => l10n.authRegistrationDisabled,
    AuthFailureNetwork() => l10n.authErrorNetwork,
    AuthFailureLocalDecode() => l10n.authErrorLocalDecode,
    AuthFailureSessionNotGranted() => l10n.authErrorSessionNotGranted,
    AuthFailureEmailNotVerified() => l10n.authErrorEmailNotVerified,
    AuthFailureServer() => l10n.authErrorServer,
    AuthFailureRateLimited(:final retryAfter) => _rateLimited(l10n, retryAfter),
    AuthFailureProviderSignIn(:final reason, :final retryAfter) =>
      switch (reason) {
        ProviderSignInFailureReason.registrationDisabled =>
          l10n.authProviderErrorRegistrationDisabled,
        ProviderSignInFailureReason.emailUnverified =>
          l10n.authProviderErrorEmailUnverified,
        // #582 adds the next step, linking the provider to the account.
        ProviderSignInFailureReason.accountNotLinked =>
          l10n.authProviderErrorAccountNotLinked,
        ProviderSignInFailureReason.accessDenied =>
          l10n.authProviderErrorAccessDenied,
        ProviderSignInFailureReason.providerUnavailable =>
          l10n.authProviderErrorUnavailable,
        ProviderSignInFailureReason.startAgain =>
          l10n.authProviderErrorStartAgain,
        ProviderSignInFailureReason.rateLimited => _rateLimited(
          l10n,
          retryAfter,
        ),
        ProviderSignInFailureReason.network => l10n.authErrorNetwork,
        ProviderSignInFailureReason.generic => l10n.authProviderErrorGeneric,
      },
  };

  /// The rate-limit copy for a sign-in, a sign-up or a provider sign-in
  /// (#559). A wait under a second would read "in 0 seconds", which is no
  /// advice, so it reads as no wait.
  String _rateLimited(AuthLocalizations l10n, Duration? retryAfter) =>
      retryAfter == null || retryAfter < const Duration(seconds: 1)
      ? l10n.authErrorRateLimitedNoWait
      : l10n.authErrorRateLimited(retryAfter.inSeconds);

  void _switchMode({required bool signIn}) {
    // Retire any failure first: it describes a submission to the form the
    // user is leaving, so carrying it over would pin a credentials
    // complaint above the registration form. The banner is bound to bloc
    // state and does not fade the way the SnackBar it replaced did (#191).
    //
    // The clear lands before the next frame, which is what keeps the
    // incoming form from mounting with the outgoing form's failure — each
    // form holds its own banner, so a stale one would render under the
    // wrong title and announce itself as new. The screen suite pins this
    // against a real bloc.
    context.read<AuthBloc>().add(const AuthFailureCleared());
    // The heading is a live region, so changing it announces the new mode.
    setState(() => _isSignIn = signIn);
  }

  void _signInWithProvider(OidcStrategy strategy) {
    setState(() => _providerAttempt++);
    final bloc = context.read<AuthBloc>();
    // Retire a standing failure first, the provider banner's or the form's:
    // it answers an attempt the user is starting over (#583). The banner is
    // bound to bloc state and does not fade on its own (#191).
    if (bloc.state is AuthOperationFailure) {
      bloc.add(const AuthFailureCleared());
    }
    bloc.add(AuthProviderSignInRequested(strategy));
  }
}
