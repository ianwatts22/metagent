import assert from "node:assert/strict";
import { test } from "node:test";

import {
  adoptionEvent,
  capture,
  downloadPlatform,
  downloadURL,
  isBot,
  parseSparkleUserAgent,
  POSTHOG_ENDPOINT,
  referrerHost,
} from "./adoption.mjs";
import middleware from "../middleware.js";

const BROWSER =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15";
const SPARKLE = "Metagent/0.10.0 Sparkle/2.7.1";
const NOW = new Date("2026-10-07T12:00:00Z");

function request(path, headers = {}, method = "GET") {
  return new Request(`https://metagent.sh${path}`, {
    method,
    headers: { "x-real-ip": "203.0.113.7", "x-vercel-ip-country": "US", ...headers },
  });
}

test("download routes map to release assets", () => {
  assert.equal(downloadPlatform("/download"), "mac");
  assert.equal(downloadPlatform("/download/"), "mac");
  assert.equal(downloadPlatform("/download/linux-x86_64"), "linux-x86_64");
  assert.equal(downloadPlatform("/download/linux-aarch64/"), "linux-aarch64");
  assert.equal(downloadPlatform("/downloads"), null);
  assert.equal(downloadPlatform("/download/a/b"), null);
  assert.equal(
    downloadURL("mac"),
    "https://github.com/ianwatts22/metagent/releases/latest/download/Metagent.dmg",
  );
  assert.equal(
    downloadURL("linux-aarch64"),
    "https://github.com/ianwatts22/metagent/releases/latest/download/metagent-linux-aarch64.tar.gz",
  );
  assert.equal(downloadURL("windows"), "https://github.com/ianwatts22/metagent/releases/latest");
});

test("bots and link previews are not counted", () => {
  for (const agent of [
    "",
    "Slackbot-LinkExpanding 1.0 (+https://api.slack.com/robots)",
    "facebookexternalhit/1.1",
    "Mozilla/5.0 (compatible; Googlebot/2.1)",
    "python-requests/2.32",
    "Mozilla/5.0 (compatible; Discordbot/2.0)",
  ]) {
    assert.equal(isBot(agent), true, agent);
  }
  assert.equal(isBot(BROWSER), false);
  assert.equal(isBot("curl/8.5.0"), false);
});

test("Sparkle user agent yields the app version", () => {
  assert.deepEqual(parseSparkleUserAgent(SPARKLE), {
    appVersion: "0.10.0",
    sparkleVersion: "2.7.1",
  });
  assert.equal(parseSparkleUserAgent(BROWSER), null);
});

test("referrer is reduced to its host", () => {
  assert.equal(referrerHost(null), "direct");
  assert.equal(referrerHost("https://news.ycombinator.com/item?id=1"), "news.ycombinator.com");
  assert.equal(referrerHost("not a url"), "unknown");
});

test("update checks are counted per client per day without storing the IP", async () => {
  const event = await adoptionEvent(request("/appcast.xml", { "user-agent": SPARKLE }), NOW);
  assert.equal(event.event, "update check");
  assert.match(event.distinct_id, /^appcast-[0-9a-f]{32}$/);
  assert.equal(event.properties.app_version, "0.10.0");
  assert.equal(event.properties.country, "US");
  assert.equal(event.properties.$process_person_profile, false);
  assert.doesNotMatch(JSON.stringify(event), /203\.0\.113\.7|Sparkle\/2/);

  const sameDay = await adoptionEvent(request("/appcast.xml", { "user-agent": SPARKLE }), NOW);
  assert.equal(sameDay.distinct_id, event.distinct_id);
  const nextDay = await adoptionEvent(
    request("/appcast.xml", { "user-agent": SPARKLE }),
    new Date("2026-10-08T12:00:00Z"),
  );
  assert.notEqual(nextDay.distinct_id, event.distinct_id);

  assert.equal(await adoptionEvent(request("/appcast.xml", { "user-agent": BROWSER }), NOW), null);
});

test("downloads record platform and referrer, skipping bots and HEAD", async () => {
  const event = await adoptionEvent(
    request("/download/?utm_source=x", {
      "user-agent": BROWSER,
      referer: "https://x.com/some/post",
    }),
    NOW,
  );
  assert.equal(event.event, "download requested");
  assert.equal(event.properties.platform, "mac");
  assert.equal(event.properties.referrer_host, "x.com");
  assert.equal(event.properties.utm_source, "x");

  const linux = await adoptionEvent(
    request("/download/linux-x86_64", { "user-agent": "curl/8.5.0" }),
    NOW,
  );
  assert.equal(linux.properties.platform, "linux-x86_64");
  assert.equal(linux.properties.referrer_host, "direct");

  assert.equal(
    await adoptionEvent(request("/download", { "user-agent": "Twitterbot/1.0" }), NOW),
    null,
  );
  assert.equal(
    await adoptionEvent(request("/download", { "user-agent": BROWSER }, "HEAD"), NOW),
    null,
  );
});

test("capture posts to PostHog and swallows failures", async () => {
  const calls = [];
  await capture({ event: "e", distinct_id: "d", properties: {} }, async (url, init) => {
    calls.push({ url, body: JSON.parse(init.body) });
  });
  assert.equal(calls[0].url, POSTHOG_ENDPOINT);
  assert.equal(calls[0].body.event, "e");
  assert.match(calls[0].body.api_key, /^phc_/);

  await capture({ event: "e" }, async () => {
    throw new Error("offline");
  });
});

test("middleware redirects downloads and passes the appcast through", async () => {
  const realFetch = globalThis.fetch;
  const sent = [];
  globalThis.fetch = async (url, init) => {
    sent.push(JSON.parse(init.body).event);
    return new Response(null);
  };
  try {
    const pending = [];
    const context = { waitUntil: (promise) => pending.push(promise) };

    const download = await middleware(request("/download/", { "user-agent": BROWSER }), context);
    assert.equal(download.status, 302);
    assert.equal(
      download.headers.get("location"),
      "https://github.com/ianwatts22/metagent/releases/latest/download/Metagent.dmg",
    );

    const bot = await middleware(request("/download", { "user-agent": "Slackbot 1.0" }), context);
    assert.equal(bot.status, 302);

    const appcast = await middleware(request("/appcast.xml", { "user-agent": SPARKLE }), context);
    assert.equal(appcast, undefined);

    await Promise.all(pending);
    assert.deepEqual(sent, ["download requested", "update check"]);
  } finally {
    globalThis.fetch = realFetch;
  }
});
