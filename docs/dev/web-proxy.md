# Local web testing via a dev reverse proxy

The web client reads its API base from the **browser origin**
(`Uri.base.origin`, via `WebDioFactory.currentOrigin`), and auth uses
httpOnly, same-origin session cookies (BetterAuth). In production the client is
served from the backend origin, so this "just works." In development the
Flutter web dev server and the NestJS backend run on different ports — two
origins — which breaks the cookie model.

A small reverse proxy fixes this by giving the browser **one origin** and
routing by path. **No client code changes are required** — this is purely local
tooling. `tool/dev_proxy/dev_proxy.mjs` is a zero-dependency Node script (built-in
modules only; Node 18+).

## Topology

```
browser ──▶ http://localhost:8080  (the proxy — open THIS)
                 │
                 ├─ /api/*         ─▶ NestJS backend        (:33333)
                 ├─ /.well-known/* ─▶ NestJS backend        (:33333)
                 └─ everything else ─▶ Flutter web dev server (:5000)
                    (assets + hot-restart websocket)
```

## Prerequisites

- Node 18+ (`node --version`).
- The NestJS backend running locally (default `:33333`).
- One trusted-origin change on the backend — see [Backend config](#backend-config-required).

## Run it (three terminals)

**1 — Backend** (in the NestJS repo):

```sh
npm run start:dev        # serves on :33333
```

**2 — Flutter web dev server.** Use the `web-server` device (not `chrome`) so
Flutter does **not** auto-open a browser at `:5000`; you open the proxy origin
yourself.

```sh
BGE_WEB_PORT=5000 melos exec --scope=browser -- \
  flutter run -d web-server --web-hostname=localhost --web-port=5000
```

**3 — Proxy**, then browse to `http://localhost:8080`:

```sh
node tool/dev_proxy/dev_proxy.mjs
```

Hot restart still works: press `R` (or `r`) in terminal 2 — the injected client
reconnects through the proxy's websocket passthrough. A manual browser refresh
also works, since assets are served live through the proxy.

### Optional melos shortcuts

The root `pubspec.yaml` defines matching melos scripts:

```sh
melos run web            # terminal 2 — Flutter web dev server (fixed port)
melos run web:proxy      # terminal 3 — the dev reverse proxy
```

Or run both in one terminal (Ctrl-C stops both); prefer the two-terminal form
above when you want independent logs:

```sh
melos run web:server     # proxy + web dev server together
```

## Environment variables

All optional; sensible defaults baked in.

| Variable            | Default | Meaning                                  |
| ------------------- | ------- | ---------------------------------------- |
| `BGE_PROXY_PORT`    | `8080`  | Origin the browser opens.                |
| `BGE_WEB_PORT`      | `5000`  | Flutter web dev server port.             |
| `BGE_BACKEND_PORT`  | `33333`  | NestJS backend port.                     |

Keep `BGE_WEB_PORT` in sync between the Flutter command and the proxy. A fixed
proxy port also keeps the backend's trusted-origin allow-list stable.

## Backend config (required)

Because the browser origin is now `http://localhost:8080`, the backend must
trust it or sign-in requests fail origin/CSRF checks even though routing works:

- **Trusted origin / baseURL** includes `http://localhost:8080` (BetterAuth
  `trustedOrigins` / `baseURL`).
- **Session cookie is host-only** — no explicit `Domain` attribute — so it binds
  to `localhost:8080`. `SameSite=Lax` (or `Strict`) is fine because, from the
  browser's point of view, every request is same-origin. `Secure` is OK too:
  Chrome treats `localhost` as a secure context.

The `issuer` field in the well-known document is informational — the client
builds request URLs from `Uri.base.origin`, not from `issuer` — so an `issuer`
that names a different port is cosmetic for the alpha.

## Extending the routes

Backend paths live in `BACKEND_PREFIXES` in `dev_proxy.mjs`. Add a prefix when
the backend gains surface outside `/api` and `/.well-known` — for example
`'/socket.io'` when the realtime (Socket.io) features land, so the websocket
upgrade is routed to the backend rather than the Flutter dev server.

## Troubleshooting

- **`502 ... unreachable`** — the named upstream isn't up. Check the backend
  (terminal 1) or the Flutter dev server (terminal 2) and the ports.
- **Blank page / assets 404** — you opened `:5000` instead of the proxy. Open
  `http://localhost:8080`.
- **Sign-in returns 401/403 but `/.well-known` loads** — routing is fine; the
  backend isn't trusting `http://localhost:8080` yet (see
  [Backend config](#backend-config-required)).
- **Cookie set but not sent back** — the cookie likely has an explicit `Domain`
  or `SameSite=None` without `Secure`. Prefer a host-only `SameSite=Lax` cookie
  in dev.
- **Hot restart doesn't reconnect** — confirm you launched with `-d web-server`;
  the websocket passthrough only matters for that device.
