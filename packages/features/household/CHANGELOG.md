## 0.0.1

* Initial release (#27 / #40): create a household you own — optimistic local
  write plus a queued `CreateHouseholdOperation`, best-effort inline server
  sync with id reconciliation, `reactive_forms` UI, full l10n, and
  accessibility. Offline / server-failure leaves the household queued
  (`pendingSync`); the sync-drain worker and permanent-failure handling are
  tracked in #121.
