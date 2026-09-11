# bge_test_support

Shared test helpers that cannot live in any one package's `test/` tree, because
a `test/` directory is not importable across packages even when a path
dependency already exists.

Created by **#354**, absorbing **#213** and **#257** — three issues that each
resolved to this same package.

## Two entry points, one package

```dart
import 'package:bge_test_support/network.dart';  // needs only dio
import 'package:bge_test_support/widgets.dart';  // needs flutter_test + the theme
```

They are separate **libraries**, not separate **packages**. pub resolves
dependencies per package, not per library, so a second package would not have
isolated anything — both `dio_network` and `web_network` already declare
`flutter` as a regular dependency and `flutter_test` as a dev one.

What the split does buy is an honest import surface, and a future split that
stays mechanical: if a genuinely pure-Dart consumer ever appears
(`network_interface` is the only candidate), move `network.dart` plus its
`src/` into its own package and consumers change one import line.

Add it as a **dev dependency**:

```yaml
dev_dependencies:
  bge_test_support:
    path: ../../testing/support
```

## `network.dart`

Real `Dio` instances whose transport is swapped for a canned one, so a suite
exercises Dio's own body pipeline — transformer, cast, `assureDioException` —
rather than a `MockDio` that stubs `Dio.get`/`Dio.post` and therefore passes
against the very bug it is meant to catch.

| Helper | Use |
|---|---|
| `cannedDio(body:, statusCode:, contentType:, permissiveStatus:)` | One canned answer for every request |
| `routingDio(byPathSuffix, permissiveStatus:)` | A different answer per request path |
| `unreachableDio(type)` | A fresh `Dio` that always fails with no response |
| `FailingAdapter(type, error:)` | The same failure, installable on a `Dio` you did not construct |

**`permissiveStatus` means the same thing on both** and defaults to `true`:
Dio hands every status back as a `Response` rather than throwing. Pass `false`
for Dio's default, where a non-2xx throws `DioException.badResponse` with the
response attached. The two copies this package replaced disagreed on that
default, which is why it is spelled out here.

## `widgets.dart`

| Helper | Use |
|---|---|
| `useViewSize(tester, size)` | Size the render surface, teardown included |
| `hostAtSize(tester, child, size:, textScale:)` | The above, plus a `BgeTheme` host |
| `scrollChildCountOnScrollingNode(tester, scrollActions:)` | The "item 3 of 9" count, off the node that really scrolls |
| `scrollViewportOf(tester)` / `pageScrollOf(tester)` | The page's scroll viewport / its state |
| `topInViewport(tester, target)` | A widget's top edge in the viewport's own space |

Three things worth knowing before reaching past these:

**Size goes on the view, not in a `MediaQuery`.** `MediaQueryData.size` is
metadata and constrains nothing, so a widget under `MediaQuery(size: …)` still
lays out against the 800x600 default. Text *scale* is the opposite — an
ancestor `MediaQuery` is effective for it.

**The teardown is not optional.** `tester.view` lives on the singleton binding
and `TestWidgetsFlutterBinding.reset()` does not restore it, so a missing reset
leaks into every later test in the file. `useViewSize` owns it, so no call site
can forget it.

**Assert a position, not a boolean.** `topInViewport` returns a signed offset
because a widget scrolled out of view is still in the tree with a *negative*
top edge — invisible to `findsOneWidget`, which is the bug in #209. A
predicate of the form "is it on screen" restates the widget's own guard and so
cannot fail for any implementation satisfying it.
