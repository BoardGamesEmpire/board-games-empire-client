// Zero-dependency dev reverse proxy for local web (browser) testing.
//
// Why this exists: the web client derives its API base from the browser
// origin (Uri.base.origin, via WebDioFactory.currentOrigin). BetterAuth uses
// httpOnly, same-origin session cookies. In development the Flutter web dev
// server and the NestJS backend run on different ports, so without a proxy the
// browser would treat them as different origins and the cookie model breaks.
//
// This proxy gives the browser ONE origin and fans out by path:
//   /api/*         and  /.well-known/*   -> NestJS backend   (BGE_BACKEND_PORT)
//   everything else (assets + hot-restart websocket) -> Flutter dev server (BGE_WEB_PORT)
//
// Open the browser at the PROXY origin (http://localhost:${BGE_PROXY_PORT}),
// never the Flutter dev server directly. No client code changes are required —
// this is purely local tooling.
//
// Requires Node 18+ (built-in modules only; nothing to install).

import http from 'node:http';
import net from 'node:net';

const PROXY_PORT = Number(process.env.BGE_PROXY_PORT ?? 8080);
const WEB_PORT = Number(process.env.BGE_WEB_PORT ?? 5000); // flutter dev server
const BACKEND_PORT = Number(process.env.BGE_BACKEND_PORT ?? 33_333); // bge backend default port

// Path prefixes routed to the backend. Extend if the backend serves auth or
// other API surface outside these (e.g. add '/socket.io' when the realtime
// features land). A request matches a prefix when it equals it exactly or is a
// sub-path of it, so '/apifoo' does NOT match '/api'.
const BACKEND_PREFIXES = ['/api', '/.well-known'];

// Callers normalize req.url once (see the handlers), so this takes a definite
// string.
function upstreamPortFor(url) {
  const matchesBackend = BACKEND_PREFIXES.some(
    (prefix) => url === prefix || url.startsWith(`${prefix}/`),
  );
  return matchesBackend ? BACKEND_PORT : WEB_PORT;
}

// Plain HTTP requests. The incoming Host header (localhost:${PROXY_PORT}) is
// forwarded verbatim so BetterAuth's origin checks and the cookie domain stay
// consistent with what the browser actually sees.
const server = http.createServer((req, res) => {
  // Node types req.url as string | undefined; normalize once and use the
  // normalized value for routing, logging, and the upstream request path.
  const url = req.url ?? '/';
  const port = upstreamPortFor(url);

  // Suppress the .js asset noise, but match on the path only — asset URLs
  // routinely carry a query (main.dart.js?v=…), which endsWith('.js') misses.
  const pathOnly = url.split('?')[0];
  if (!pathOnly.endsWith('.js')) {
    process.stdout.write(`[bge dev proxy] ${req.method} ${url} -> :${port}\n`);
  }
  const upstream = http.request(
    {
      host: 'localhost',
      port,
      method: req.method,
      path: url,
      headers: req.headers,
    },
    (upstreamRes) => {
      res.writeHead(upstreamRes.statusCode ?? 502, upstreamRes.headers);
      upstreamRes.pipe(res);
      // A reset AFTER the body starts streaming can't become a 502 — the
      // status line is already on the wire — so just tear the response down.
      upstreamRes.on('error', () => res.destroy());
    },
  );

  upstream.on('error', (error) => {
    // Only synthesize a 502 while the response is still unstarted; once
    // headers are sent, writeHead() would throw ERR_HTTP_HEADERS_SENT and
    // crash the proxy, so destroy the socket instead.
    if (res.headersSent) {
      res.destroy();
      return;
    }
    const target = port === BACKEND_PORT ? 'backend' : 'web dev server';
    res.writeHead(502, { 'content-type': 'text/plain' });
    res.end(`[bge dev proxy] ${target} (:${port}) unreachable: ${error.message}\n`);
  });

  req.pipe(upstream);
});

// WebSocket upgrades (Flutter's hot-restart / DWDS channel). Node routes
// upgrade requests here instead of the normal handler, so we open a raw TCP
// socket to the chosen upstream, replay the handshake, and pipe both ways. The
// Upgrade/Connection headers are forwarded untouched (req.headers verbatim),
// which is what makes the switch succeed.
server.on('upgrade', (req, clientSocket, head) => {
  const url = req.url ?? '/';
  const port = upstreamPortFor(url);
  const upstream = net.connect(port, 'localhost', () => {
    const requestLine = `${req.method ?? 'GET'} ${url} HTTP/1.1\r\n`;
    const headerLines = Object.entries(req.headers)
      .map(([key, value]) => `${key}: ${value}`)
      .join('\r\n');
    upstream.write(`${requestLine}${headerLines}\r\n\r\n`);
    if (head && head.length) upstream.write(head);
    upstream.pipe(clientSocket);
    clientSocket.pipe(upstream);
  });

  upstream.on('error', () => clientSocket.destroy());
  clientSocket.on('error', () => upstream.destroy());
});

server.listen(PROXY_PORT, 'localhost', () => {
  process.stdout.write(
    `[bge dev proxy] http://localhost:${PROXY_PORT}  ->  ` +
    `web:${WEB_PORT}  api:${BACKEND_PORT}\n` +
    `[bge dev proxy] backend paths: ${BACKEND_PREFIXES.join(', ')}\n` +
    `[bge dev proxy] open the browser at http://localhost:${PROXY_PORT} ` +
    `(NOT :${WEB_PORT})\n`,
  );
});
