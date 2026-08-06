# Security Policy

## Supported versions

This project is pre-alpha and has published no releases. Only the current
`master` branch is supported; there are no backports.

## Reporting a vulnerability

**Please do not open a public issue for a security problem.**

Report it privately through GitHub:

1. Go to the [Security advisories page](https://github.com/BoardGamesEmpire/board-games-empire-client/security/advisories/new)
2. Fill in what you found

That opens a private thread visible only to the maintainers. If you cannot use
GitHub's reporting flow for any reason, open a regular issue asking for a private
contact channel — without vulnerability details — and someone will follow up.

Useful things to include, as far as you have them: the affected package or file,
the versions or commit you tested, reproduction steps, and what an attacker could
actually do with it.

Expect an initial acknowledgement within about a week. This is a small
volunteer-paced project — that is a realistic estimate, not an SLA. Please give
us a chance to ship a fix before disclosing publicly, and tell us if you have a
disclosure deadline in mind so we can plan around it.

## Scope

This repository is the **client** only. Server-side issues belong to the backend
repository.

Worth knowing before you report: Board Games Empire is self-hosted, so each
deployment is run by its own admin. A misconfigured server instance is that
admin's concern rather than a vulnerability in this client. What *is* in scope
here is anything in this codebase that mishandles credentials, tokens, or
at-rest data; leaks user data to a third party (the project's default is that
nothing leaves the device without opt-in); or fails to redact PII where it says
it does.
