// Server-side adoption signals for metagent.sh. Runs in Vercel Routing
// Middleware (see /middleware.js) and logs two anonymous events to the same
// PostHog project as the app:
//
// - `update check`: every installed copy fetches /appcast.xml once a day via
//   Sparkle, so distinct daily checks count running installs and the Sparkle
//   user agent carries the app version. Works even with app analytics off.
// - `download requested`: /download and /download/<platform> log the
//   download, then redirect to the GitHub release asset.
//
// No IP address or user agent is stored. The distinct ID is a hash of the
// UTC day, client IP and user agent, so it dedupes repeat requests within a
// day and cannot link a client across days.

export const POSTHOG_TOKEN = "phc_BEhfLjwSiN2vBoyEjs7gKDS5vowQX2v73bSrzcYEMso4";
export const POSTHOG_ENDPOINT = "https://us.i.posthog.com/i/v0/e/";

const RELEASES = "https://github.com/ianwatts22/metagent/releases";

export const DOWNLOAD_ASSETS = {
  mac: "Metagent.dmg",
  "linux-x86_64": "metagent-linux-x86_64.tar.gz",
  "linux-aarch64": "metagent-linux-aarch64.tar.gz",
};

const BOT_PATTERN =
  /bot|crawl|spider|slurp|preview|scanner|facebookexternalhit|embedly|whatsapp|telegram|discord|slack|linkedin|skype|pinterest|vkshare|headless|lighthouse|python-requests|python-urllib|go-http-client|okhttp|axios|node-fetch|undici|wget|scrapy|httpclient|libwww|zgrab|masscan|nmap|censys|expanse/i;

export function isBot(userAgent) {
  return !userAgent || BOT_PATTERN.test(userAgent);
}

/// "Metagent/0.10.0 Sparkle/2.7.1" -> { appVersion, sparkleVersion }.
export function parseSparkleUserAgent(userAgent) {
  const match = /^Metagent\/(\S+) Sparkle\/(\S+)/.exec(userAgent ?? "");
  return match ? { appVersion: match[1], sparkleVersion: match[2] } : null;
}

/// `/download`, `/download/`, `/download/mac`, `/download/linux-x86_64`, ...
/// Returns null for paths that are not download routes.
export function downloadPlatform(pathname) {
  const match = /^\/download(?:\/([^/]*))?\/?$/.exec(pathname);
  if (!match) return null;
  return match[1] || "mac";
}

export function downloadURL(platform) {
  const asset = DOWNLOAD_ASSETS[platform];
  return asset ? `${RELEASES}/latest/download/${asset}` : `${RELEASES}/latest`;
}

export function referrerHost(referrer) {
  if (!referrer) return "direct";
  try {
    return new URL(referrer).hostname || "direct";
  } catch {
    return "unknown";
  }
}

export async function dailyClientID(request, now = new Date()) {
  const ip =
    request.headers.get("x-real-ip") ??
    request.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ??
    "";
  const userAgent = request.headers.get("user-agent") ?? "";
  const day = now.toISOString().slice(0, 10);
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(`${day}\n${ip}\n${userAgent}`),
  );
  return Array.from(new Uint8Array(digest).slice(0, 16), (byte) =>
    byte.toString(16).padStart(2, "0"),
  ).join("");
}

function baseProperties(request) {
  return {
    $process_person_profile: false,
    $geoip_disable: true,
    country: request.headers.get("x-vercel-ip-country") ?? "unknown",
  };
}

/// The PostHog event for a request, or null when it should not be counted.
export async function adoptionEvent(request, now = new Date()) {
  if (request.method !== "GET") return null;
  const url = new URL(request.url);
  const userAgent = request.headers.get("user-agent") ?? "";

  if (url.pathname === "/appcast.xml") {
    const sparkle = parseSparkleUserAgent(userAgent);
    if (!sparkle) return null;
    return {
      event: "update check",
      distinct_id: `appcast-${await dailyClientID(request, now)}`,
      properties: {
        ...baseProperties(request),
        app_version: sparkle.appVersion,
        sparkle_version: sparkle.sparkleVersion,
      },
    };
  }

  const platform = downloadPlatform(url.pathname);
  if (platform && !isBot(userAgent)) {
    return {
      event: "download requested",
      distinct_id: `download-${await dailyClientID(request, now)}`,
      properties: {
        ...baseProperties(request),
        platform: platform in DOWNLOAD_ASSETS ? platform : "unknown",
        referrer_host: referrerHost(request.headers.get("referer")),
        utm_source: url.searchParams.get("utm_source") ?? undefined,
      },
    };
  }
  return null;
}

export async function capture(event, fetchImpl = fetch) {
  try {
    await fetchImpl(POSTHOG_ENDPOINT, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ api_key: POSTHOG_TOKEN, ...event }),
      signal: AbortSignal.timeout(2000),
    });
  } catch {
    // Analytics must never break downloads or update checks.
  }
}
