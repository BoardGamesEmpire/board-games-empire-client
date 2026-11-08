# Pointing a native app at a dev server

The mobile and desktop apps don't read their server from the build. You add one
in the app, on the **Add a Server** screen, and it connects to whatever address
you type there. The work is making the backend reachable from the device at an
address the app accepts.

Two rules decide which addresses work:

- **The app accepts `http` only for loopback and private addresses**:
  `localhost`, `127.0.0.0/8`, `::1`, `10/8`, `172.16/12` and `192.168/16`
  (`server_url_input.dart` in `packages/features/server_onboarding`). Anything
  else needs `https`. The app assumes `https` when you type no scheme, so type
  `http://` in full.
- **The backend answers only at its own names**: `localhost`, any IP address,
  and the hosts in its configured URLs. Any other `Host` gets a 421. The
  backend's
  [DEPLOYMENT.md](https://github.com/BoardGamesEmpire/board-games-empire-backend/blob/master/docs/DEPLOYMENT.md#behind-a-reverse-proxy)
  has the details.

## Topology

```
emulator or USB device ──adb reverse──▶ localhost:33333 on this machine ─▶ api
emulator               ──10.0.2.2────▶ this machine's loopback          ─▶ api
phone on the same Wi-Fi ──<lan-ip>───▶ this machine's LAN interface     ─▶ api
macOS app              ──localhost──▶ this machine                      ─▶ api
```

The api listens on port `33333` in every recipe below.

## 1. An emulator or a USB device: `adb reverse`

Start here. `adb reverse` makes the device's `localhost:33333` this machine's
`localhost:33333`, which every backend default already expects. Nothing on the
backend changes.

1. Start the backend as you normally do.
2. With the device connected (or the emulator running):

   ```sh
   adb reverse tcp:33333 tcp:33333
   ```

3. In the app, add `http://localhost:33333`.

The mapping lasts only as long as the connection. When the cable comes out or
the emulator restarts, the app can't reach the server until you run the command
again.

## 2. An emulator without `adb reverse`: `10.0.2.2`

The Android emulator reaches this machine's loopback interface at `10.0.2.2`. A
backend that listens only on loopback, as the Compose profile does by default,
is still reachable this way, and the api answers any IP address as a host.
Nothing on the backend changes.

In the app, add `http://10.0.2.2:33333`.

## 3. A phone on Wi-Fi: the LAN address

The phone reaches this machine at its LAN address, such as `192.168.1.20`. Find
it in your network settings, or with `ipconfig getifaddr en0` on macOS.

1. **Let the backend listen on the LAN.** Under Compose, set `BGE_BIND_ADDRESS`
   to `0.0.0.0`, or to that interface's address. The Compose profile publishes
   the api on loopback only by default: the first account to sign up becomes
   the server's owner, so a new deployment starts out unreachable from other
   machines. Sign up the owner first if anyone else is on the network. A
   backend run from source, with `npm start` in its checkout, already listens on
   every interface.
2. **Tell the backend the address clients use.** Under Compose, set
   `BGE_PUBLIC_URL=http://<lan-ip>:33333`, with no trailing slash: it is the URL
   the api trusts for sign-in. It also takes `localhost`'s place in the trusted
   origins, so to keep signing in from a browser on this machine, set
   `TRUSTED_ORIGINS=http://<lan-ip>:33333,http://localhost:33333` as well. From
   source, set `BETTER_AUTH_URL` to that URL, and add it to `TRUSTED_ORIGINS`
   beside the `localhost` entries already there.
3. In the app, add `http://<lan-ip>:33333`.

The LAN address is private, so the app accepts `http` for it. A server at a
public address needs `https`.

## 4. A self-hosted server, Kubernetes included

Add the server's public `https` URL, the one its `BETTER_AUTH_URL` names (under
Compose, `BGE_PUBLIC_URL`). Deploying the server is the backend's business:
[DEPLOYMENT.md](https://github.com/BoardGamesEmpire/board-games-empire-backend/blob/master/docs/DEPLOYMENT.md)
covers its images, settings and reverse proxies. This repository ships no
manifests.

## 5. Desktop

The macOS app runs on this machine, so it reaches the backend at
`http://localhost:33333` with no setup.

## A device that has master's APK

`melos run mobile` installs a debug build under the same id as the APK master's
CI run signs, but with the debug key. Android refuses it as an update over the
release-signed copy, and `flutter run` answers that by printing
"Uninstalling old version..." and uninstalling the copy, which deletes its data.
Develop on an emulator, or on a device whose sideloaded app holds nothing you
need.

## Troubleshooting

- **"Plain http is only allowed for local and private network addresses"** —
  the address isn't loopback or private, so the app refused it before trying.
  Use `https`, or one of the addresses above.
- **The app times out on `localhost` from a device** — the `adb reverse` mapping
  is gone. Run it again, and check `adb reverse --list`.
- **The app times out on the LAN address** — the backend is listening on
  loopback only (recipe 3, step 1), or this machine's firewall is refusing the
  port.
- **A 421 with `HOST_NOT_ALLOWED`** — the app reached the api under a name the
  api isn't configured for, such as a self-hosted server's second domain. Use
  the name its `BETTER_AUTH_URL` names, or add the other one to
  `TRUSTED_ORIGINS`.
