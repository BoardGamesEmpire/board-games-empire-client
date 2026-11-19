import 'package:auth/l10n/auth_localizations.dart';
import 'package:flutter/material.dart';

/// **Manage servers**: the way to the device's list of servers from a
/// screen that belongs to one server (#134), so someone who can't get into
/// this one, a wrong server or one that can't be reached, isn't stuck on it.
///
/// One widget for every screen that offers it, so it reads and behaves the
/// same on each. A secondary action, never disabled: whatever the screen is
/// waiting on, its server may be the one the person wants to leave.
class ManageServersButton extends StatelessWidget {
  const ManageServersButton({required this.onPressed, super.key});

  /// Opens the list. The shell supplies it where there is one.
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: onPressed,
    child: Text(AuthLocalizations.of(context).authManageServers),
  );
}
