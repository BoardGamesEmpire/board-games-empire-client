/// The two composition scopes a [SettingsSection] can belong to (#120),
/// mirroring the app's DI topology (app-level vs. per-server).
///
/// The distinction is behavioural, not cosmetic: [appLevel] sections are
/// always visible; [perServer] sections are shown only while a server is
/// active and are rendered under a header naming that server's alias.
enum SettingsScope {
  /// Always visible — backed by app-level state (theme, language).
  appLevel,

  /// Visible only with an active server scope — backed by per-server
  /// state (e.g. analytics opt-in #17, per-server notification prefs).
  perServer,
}
