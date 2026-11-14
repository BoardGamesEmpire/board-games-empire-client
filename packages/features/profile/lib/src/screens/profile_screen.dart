import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:models/domain.dart';
import 'package:network_interface/network_interface.dart';
import 'package:profile/l10n/profile_localizations.dart';
import 'package:profile/src/bloc/profile_bloc.dart';
import 'package:profile/src/bloc/profile_event.dart';
import 'package:profile/src/bloc/profile_state.dart';
import 'package:profile/src/form/profile_form.dart';
import 'package:ui/ui.dart';
import 'package:ui_tokens/ui_tokens.dart';

/// The signed-in user's own profile (#547): their avatar, name and username
/// at the top, read-only, then the form that edits the rest.
///
/// Nothing is cached: the profile is read when the screen opens, and a save
/// goes straight to the server. A save's response becomes the form's new
/// values, so it shows what the server stored.
///
/// ## States
///
/// Loading; a failed read, with Try again; a server that has no profile for
/// the user yet, as a brand-new account can meet, which is an answer and so
/// an empty state rather than a failure, with Try again too; and the form.
/// The bloc polls nothing, so it is closed with the screen.
///
/// ## Keeping keyboard focus
///
/// Try again goes as the read starts, and would take focus with it, so it
/// hands focus to the page's title, which is no Tab stop but is always
/// there. A save the server answers with no profile, or with a success
/// that can't be read, takes the form away, and the focus in it, so that
/// focus goes to the title too.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({required this.remote, this.confirmSession, super.key});

  static const Key loadingKey = Key('profile.loading');
  static const Key errorKey = Key('profile.error');
  static const Key notReadyKey = Key('profile.not_ready');

  final UserProfileRemoteDataSource remote;

  /// Whether the session is still the signed-in user's, asked before each
  /// save (#432). Null where nothing can move the session, as on native.
  final Future<bool> Function()? confirmSession;

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  late final ProfileBloc _bloc;

  /// On the page's title, which takes focus only when sent there: it is no
  /// Tab stop.
  final FocusNode _heading = FocusNode(
    debugLabel: 'profile heading',
    skipTraversal: true,
  );

  @override
  void initState() {
    super.initState();
    _bloc = ProfileBloc(
      remote: widget.remote,
      confirmSession: widget.confirmSession,
    )..add(const ProfileStarted());
  }

  @override
  void dispose() {
    unawaited(_bloc.close());
    _heading.dispose();
    super.dispose();
  }

  void _retry() {
    _heading.requestFocus();
    _bloc.add(const ProfileRetried());
  }

  /// Hands the focus a keyboard user had in the form to the title, once a
  /// save has taken the form away: answered with no profile, or with a
  /// success that couldn't be read.
  ///
  /// The focus is parked on the page's scope at once, so the framework's
  /// fallback doesn't put it on another control as the form goes, and
  /// handed on after the frame that takes the form away. Focus outside the
  /// form, or moved since, is left where it is.
  void _onProfileGone() {
    final focused = FocusManager.instance.primaryFocus;
    final inForm =
        focused?.context?.findAncestorWidgetOfExactType<ProfileForm>() != null;
    if (!inForm && !focusIsFree(context)) return;
    FocusScope.of(context, createDependency: false).requestScopeFocus();
    WidgetsBinding.instance
      ..addPostFrameCallback((_) {
        if (!mounted || !focusIsFree(context)) return;
        _heading.requestFocus();
      })
      ..ensureVisualUpdate();
  }

  @override
  Widget build(BuildContext context) => BlocProvider<ProfileBloc>.value(
    value: _bloc,
    child: BlocListener<ProfileBloc, ProfileState>(
      listenWhen: (previous, current) =>
          previous.status == ProfileLoadStatus.loaded &&
          current.status != ProfileLoadStatus.loaded,
      listener: (_, _) => _onProfileGone(),
      child: BlocBuilder<ProfileBloc, ProfileState>(builder: _buildState),
    ),
  );

  Widget _buildState(BuildContext context, ProfileState state) {
    final l10n = ProfileLocalizations.of(context);
    final title = Focus(focusNode: _heading, child: Text(l10n.profileTitle));
    final profile = state.profile;

    if (state.status == ProfileLoadStatus.loaded && profile != null) {
      return BgePage(
        title: title,
        child: _Loaded(profile: profile, state: state),
      );
    }

    return BgePage(
      title: title,
      centerVertically: true,
      child: switch (state.status) {
        ProfileLoadStatus.notReady => BgeEmptyState(
          key: ProfileScreen.notReadyKey,
          icon: Icons.hourglass_empty,
          title: l10n.profileNotReady,
          body: l10n.profileNotReadyBody,
          action: FilledButton(
            onPressed: _retry,
            child: Text(l10n.profileRetry),
          ),
        ),
        ProfileLoadStatus.failed => BgeErrorState(
          key: ProfileScreen.errorKey,
          icon: Icons.cloud_off_outlined,
          title: l10n.profileLoadFailed,
          body: l10n.profileLoadFailedBody,
          retryLabel: l10n.profileRetry,
          onRetry: _retry,
        ),
        _ => Center(
          child: BgeLoadingState(
            key: ProfileScreen.loadingKey,
            label: l10n.profileLoading,
          ),
        ),
      },
    );
  }
}

class _Loaded extends StatelessWidget {
  const _Loaded({required this.profile, required this.state});

  final UserProfile profile;
  final ProfileState state;

  @override
  Widget build(BuildContext context) {
    final bloc = context.read<ProfileBloc>();

    // Not keyed on the profile: the form refills itself from a new one, and
    // a new key would take the focus and the saved notice with the old form.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _Header(profile: profile),
        const BgeGap.xl(),
        ProfileForm(
          initial: profile,
          saving: state.saving,
          saved: state.saved,
          failure: state.saveFailure,
          onSave: (patch) => bloc.add(ProfileSaveRequested(patch)),
          onEdited: () => bloc.add(const ProfileEdited()),
        ),
      ],
    );
  }
}

/// The avatar, name and username, read-only: changing the picture is
/// backend #829.
///
/// Without a display name the name is the username, so the username isn't
/// shown again under it.
class _Header extends StatelessWidget {
  const _Header({required this.profile});

  /// The avatar's diameter: the page's one picture of the user, so larger
  /// than a list row's.
  static const double _avatarSize = 64;

  final UserProfile profile;

  @override
  Widget build(BuildContext context) {
    final l10n = ProfileLocalizations.of(context);
    final theme = Theme.of(context);
    final displayName = personName(displayName: profile.displayName);
    final name = displayName ?? personName(username: profile.username);

    return Row(
      spacing: BgeTokens.of(context).spaceMd,
      children: [
        BgeAvatar(
          initials: personInitials(name),
          imageUrl: profile.avatarUrl,
          size: _avatarSize,
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (name != null) Text(name, style: theme.textTheme.titleLarge),
              if (displayName != null)
                Text(
                  l10n.profileUsername(profile.username),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
