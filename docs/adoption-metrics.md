# Adoption metrics

How we count real Metagent installs and downloads. GitHub release download
counts are not used: they include our own reinstalls, link-preview bots, and
scanners.

All three signals land in the PostHog project **metagent** (Watts
Enterprises), on the [Metagent adoption dashboard](https://us.posthog.com/project/578216/dashboard/2183069).

| Signal | Event | Source | Counts |
| --- | --- | --- | --- |
| Active installs | `app launched` | The app (`ProductAnalytics.swift`), random install ID | Weekly active installs, new vs returning, version spread. Misses installs with analytics turned off. |
| Running installs | `update check` | `middleware.js` on `metagent.sh/appcast.xml` | Every release install fetches the Sparkle feed daily, so distinct clients per day ≈ running installs, with the app version from Sparkle's user agent. Works with analytics off. |
| Downloads | `download requested` | `middleware.js` on `metagent.sh/download/<platform>` | Real downloads by platform, referring site, and `utm_source`, then a 302 to the GitHub release asset. |

Filter `app launched` to `app_channel = release`; dev builds have no Sparkle feed
and never produce `update check`.

## Download links

Link to these instead of GitHub asset URLs so downloads are counted:

- `https://metagent.sh/download/` — macOS DMG (the site's Download buttons)
- `https://metagent.sh/download/linux-x86_64` and `/download/linux-aarch64` — Linux helper tarballs
- Add `?utm_source=<where>` when posting a link somewhere specific.

## Privacy

The middleware stores no IP address or user agent. Its distinct ID is a hash of
the UTC day, client IP, and user agent, so repeat requests within a day collapse
to one client and nothing links a client across days. Bot user agents and `HEAD`
requests are not counted; unknown clients on `/appcast.xml` (anything that is not
Sparkle) are ignored. Country comes from Vercel's `x-vercel-ip-country` header.

## Code

- `middleware.js` — Vercel Routing Middleware; logs, then redirects downloads or
  lets the static appcast through. Logging never blocks or fails the request.
- `edge/adoption.mjs` — pure helpers (bot filter, Sparkle UA parsing, routes).
- `edge/adoption.test.mjs` — `node --test edge/adoption.test.mjs`, run by
  `scripts/verify.sh`.
