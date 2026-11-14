/// Reusable, presentation-only widgets.
///
/// Convention for this package: widgets receive localized strings and state as
/// parameters — no localization delegates, no blocs, no repository types.
/// Wiring those is the consuming layer's job (`app_shell` for shell chrome,
/// feature packages for their screens).
///
/// Everything here is justified by duplication that already existed, and the
/// migration is complete rather than aspirational — `BgePage` is used by all
/// 12 page-shaped screens, `BgeSubmitButton` by all 6 submit controls,
/// `BgeTextField` by every form field in 5 files (#165), `BgeDropdownField`
/// by all 4 form menus (#649), `BgeErrorState` by
/// both whole-surface retry views (#102), `BgeFormActions` by all 4 forms
/// that show a submit's failure (#211), `rejectSubmit` by all 5 forms
/// (#230), `ReadAgainWhenUncovered` by all 3 screens that read the
/// server again when uncovered (#41, #455), `BgeKeyedSliverList` by the
/// nine row lists #549 covers, `BgeShelf` by the home page's game sections and
/// its events (#615, #669), `BgeFocusRing` by the game covers and the event
/// cards on them (#669), `BgePointerFocus` by those covers and Collection's
/// stack rows, which take focus from a tap (#707, #709), `BgeCoverTile` by
/// the home shelves' covers and the Games and Collection grids' tiles (#707,
/// #710), `BgeKeyedSliverGrid`,
/// `bgeCoverGridDelegate`, `BgeLayoutToggle` and `BgeRememberedLayout` by
/// those two grids and their list or thumbnails choice (#710),
/// `BgeUnfoldingCoverGrid` by the same two grids, which open a base game's
/// expansions under its row (#711),
/// `BgeFocusHandoffScope` and `BgeFocusHandoff` by the Games and Collection
/// lists and grids, whose games change form (#769, #711),
/// `BgeRefreshBanner` by the 7 stale-data banners, on 3 lists, 2 detail
/// screens, the home events section and the catalog's from-cache screens and
/// quick look (#573, #607), `BgeInertButton` by buttons that keep focus
/// while they can do nothing, at 16 call sites in `lib/` (#607, #807),
/// `BgeFabLabel` by the 5 extended floating buttons, which it keeps on screen
/// at large text (#50), `replaceSnackBar` by every SnackBar, at 4 uses in
/// `lib/` (#343), `closeWhenSettled` by the 8 screens that save and then
/// leave, at 8 call sites in `lib/`, all outside this package (#464),
/// `SessionMessenger` by those 8 screens and the collection's add sheet,
/// which say every bar through it, at 9 constructor calls in `lib/`, all
/// outside this package (#464, #694), and
/// `BgeLoadingState`, `BgeEmptyState` and `BgeStateSliver` by the loading,
/// empty and denied surfaces of the feature screens, at 28, 38 and 60 call
/// sites in `lib/` (#49, #807). `BgeOnlineOnly`, `BgeOnlineOnlyLabel`,
/// `BgeOnlineOnlyNote`, `BgeOnlineOnlyMenu` and `BgeOnlineOnlyPopupMenuItem`
/// are on the controls that write straight to the server, at 27, 12, 10, 4
/// and 4 call sites in `lib/` (#49, #807). Each `lib/` count is of
/// constructor calls in every package, this one included: 2 of
/// `BgeInertButton`'s, 1 of `BgeOnlineOnlyLabel`'s and 1 of
/// `BgeOnlineOnlyNote`'s are inside this package's own widgets.
/// `BgeMenuButton` is both of the navigation shell's menu buttons, a first
/// page's and the rail's (#414).
/// `replaceSnackBar`'s 4 uses are 3 method calls and the filter sheet's one
/// tear-off. One of the calls is inside this package, in `SessionMessenger`,
/// which every screen that saves and then leaves says its bars through.
///
/// Two surfaces deliberately do NOT use `BgePage`: `CrashReportPrompt` and
/// `BuildErrorView` render above the navigator with no `Scaffold` of their
/// own, so they are not pages. They share only the width constraint, which
/// they take from `BgeTokens.contentMaxWidth`.
///
/// New widgets belong here once a second call site wants them — not in
/// anticipation of one. Two exceptions, each by decision. `showBgePopup` came
/// here with one call site, the game quick look, because #707 placed the
/// sheet-or-dialog launcher in this package for #709's picker to open the
/// same way. That picker, the collection entry picker, is now its second.
/// `BgePopupCoverObserver` is part of it: the navigation shell installs one
/// on its nested navigator, so a pop-up opened from a page there hears of
/// the pages it opens (#414).
/// `BgeSearchField` came here with #715, whose Collection list was its one
/// call site, because #516's two lists, an event's Games tab and its Offer
/// games page, were designed with it to filter the same way as the user types.
/// Those two are its second and third.
/// `BgeSwitchField` moved here from the collection entry sheet, which has two
/// of them, for the server settings' reset-password switch, which #807 adds
/// in the same change: its third call site.
/// `BgeAvatar` came with #547 for two call sites at once, the household roster
/// and the event attendee rows, which name a person the same way (#603).
/// `BgeFieldNote` came with #547 for two call sites at once, the line under
/// the reach menu on the event form and on the profile form.
library;

export 'src/banners/bge_inline_banner.dart';
export 'src/banners/bge_offline_strip.dart';
export 'src/banners/bge_refresh_banner.dart';
export 'src/banners/bge_snack_bars.dart';
export 'src/banners/unverified_session_banner.dart';
export 'src/buttons/bge_fab_label.dart';
export 'src/buttons/bge_inert_button.dart';
export 'src/buttons/bge_submit_button.dart';
export 'src/connectivity/bge_connectivity_scope.dart';
export 'src/connectivity/bge_online_only.dart';
export 'src/connectivity/bge_online_only_menu.dart';
export 'src/connectivity/bge_online_only_popup_menu_item.dart';
export 'src/focus/bge_focus_handoff.dart';
export 'src/focus/bge_focus_ring.dart';
export 'src/focus/bge_pointer_focus.dart';
export 'src/focus/focus_is_free.dart';
export 'src/forms/bge_dropdown_field.dart';
export 'src/forms/bge_field_note.dart';
export 'src/forms/bge_form_actions.dart';
export 'src/forms/bge_rejected_submit.dart';
export 'src/forms/bge_search_field.dart';
export 'src/forms/bge_switch_field.dart';
export 'src/forms/bge_text_field.dart';
export 'src/images/bge_avatar.dart';
export 'src/images/bge_cover_expansions.dart' show BgeCoverExpansions;
export 'src/images/bge_cover_tile.dart';
export 'src/images/bge_stack_marker.dart';
export 'src/images/bge_thumbnail.dart';
export 'src/layout/bge_keyed_sliver_grid.dart';
export 'src/layout/bge_keyed_sliver_list.dart';
export 'src/layout/bge_layout_toggle.dart';
export 'src/layout/bge_navigation_menu.dart';
export 'src/layout/bge_page.dart';
export 'src/layout/bge_shelf.dart';
export 'src/layout/bge_unfolding_cover_grid.dart';
export 'src/popups/bge_popup.dart';
export 'src/routes/close_when_settled.dart';
export 'src/routes/read_again_when_uncovered.dart';
export 'src/routes/session_messenger.dart';
export 'src/states/bge_empty_state.dart';
export 'src/states/bge_error_state.dart';
export 'src/states/bge_loading_state.dart';
export 'src/states/bge_state_sliver.dart';
