import 'package:interfaces/orchestration.dart';
import 'package:models/domain.dart';

import 'session_rehydrator_impl.dart';

/// Installs the session's [SessionRehydrator] (#302 D2).
///
/// Must run **first** in the user-scope installer list: the hydrating
/// installers after it resolve this to register themselves, and installers
/// run in list order.
///
/// Pure composition — no storage, network or platform dependency — so it
/// lives in `di` beside the registry rather than in a platform package.
/// The platform bootstraps compose it into their own installer lists; a
/// composition that omits it simply has no re-hydrate seam, and the
/// hydrating installers treat its absence as "nothing to register with".
///
/// The registry is closed through the registration's `dispose:` callback,
/// which is what the user-session scope teardown drives on sign-out. That
/// is the whole implementation of #302's "no re-run when there is no
/// active user session": after teardown there is no registry to call.
class SessionRehydratorInstaller implements UserScopeInstaller {
  const SessionRehydratorInstaller();

  @override
  Future<void> install(
    DependencyContainer container,
    ScopedServer server,
    String userId,
  ) async {
    final rehydrator = SessionRehydratorImpl();
    container.registerSingleton<SessionRehydrator>(
      rehydrator,
      dispose: (_) => rehydrator.close(),
    );
  }
}
