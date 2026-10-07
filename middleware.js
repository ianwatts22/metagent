// Vercel Routing Middleware for metagent.sh. Logs anonymous adoption events
// (see edge/adoption.mjs) without delaying the response.
import {
  adoptionEvent,
  capture,
  downloadPlatform,
  downloadURL,
} from "./edge/adoption.mjs";

export const config = {
  matcher: ["/appcast.xml", "/download", "/download/:path*"],
};

export default async function middleware(request, context) {
  try {
    const event = await adoptionEvent(request);
    if (event) {
      const sent = capture(event);
      if (context?.waitUntil) context.waitUntil(sent);
      else await sent;
    }
  } catch {
    // Never let logging block an update check or a download.
  }

  const platform = downloadPlatform(new URL(request.url).pathname);
  if (platform) {
    return new Response(null, {
      status: 302,
      headers: { Location: downloadURL(platform), "Cache-Control": "no-store" },
    });
  }
  // Fall through: /appcast.xml is served from the static site as before.
}
