// =============================================================================
// Anonymous feature — Supabase Edge Function: `submit`
// Verifies Cloudflare Turnstile, rate-limits by hashed IP, inserts a pending
// row using the service_role key (never exposed to the browser), returns the
// one-time reveal code.
//
// Deploy:
//   supabase functions deploy submit --no-verify-jwt
//   supabase secrets set TURNSTILE_SECRET=...  IP_SALT=...  MAX_PER_HOUR=5
//   (SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are injected automatically.)
// =============================================================================
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const TURNSTILE_SECRET = Deno.env.get("TURNSTILE_SECRET") ?? "";
const IP_SALT = Deno.env.get("IP_SALT") ?? "change-me";
const MAX_PER_HOUR = Number(Deno.env.get("MAX_PER_HOUR") ?? "5");

const MESSAGE_MAX = 500;
const HINT_MAX = 200;
const ALLOWED = new Set(["love", "regret", "funny", "hate", "other"]);

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(obj: unknown, status = 200) {
  return new Response(JSON.stringify(obj), {
    status,
    headers: { ...cors, "content-type": "application/json" },
  });
}

async function sha256hex(s: string) {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function makeCode() {
  const alpha = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"; // no ambiguous 0/O/1/I
  const bytes = crypto.getRandomValues(new Uint8Array(5));
  let out = "";
  for (const b of bytes) out += alpha[b % alpha.length];
  return "ANON-" + out;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ error: "bad_json" }, 400);
  }

  const category = String(body.category ?? "").toLowerCase();
  const message = String(body.message ?? "").trim();
  const hint = String(body.hint ?? "").trim();
  const token = String(body.token ?? "");

  if (!ALLOWED.has(category)) return json({ error: "bad_category" }, 400);
  if (message.length < 1 || message.length > MESSAGE_MAX) return json({ error: "bad_message" }, 400);
  if (hint.length < 1 || hint.length > HINT_MAX) return json({ error: "bad_hint" }, 400);

  const ip =
    req.headers.get("x-forwarded-for")?.split(",")[0].trim() ||
    req.headers.get("cf-connecting-ip") ||
    "0.0.0.0";

  // Verify Turnstile (skipped only if no secret configured, e.g. local dev).
  if (TURNSTILE_SECRET) {
    if (!token) return json({ error: "captcha_required" }, 400);
    const verify = await fetch("https://challenges.cloudflare.com/turnstile/v0/siteverify", {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ secret: TURNSTILE_SECRET, response: token, remoteip: ip }),
    })
      .then((r) => r.json())
      .catch(() => ({ success: false }));
    if (!verify.success) return json({ error: "captcha_failed" }, 403);
  }

  const ip_hash = await sha256hex(IP_SALT + "|" + ip);
  const admin = createClient(SUPABASE_URL, SERVICE_ROLE, { auth: { persistSession: false } });

  // Rate limit by hashed IP over the last hour.
  const since = new Date(Date.now() - 3_600_000).toISOString();
  const { count, error: cErr } = await admin
    .from("submissions")
    .select("id", { count: "exact", head: true })
    .eq("ip_hash", ip_hash)
    .gte("created_at", since);
  if (cErr) return json({ error: "server_error" }, 500);
  if ((count ?? 0) >= MAX_PER_HOUR) return json({ error: "rate_limited" }, 429);

  // Insert with a unique reveal code (retry on rare collision).
  for (let attempt = 0; attempt < 5; attempt++) {
    const code = makeCode();
    const { error } = await admin.from("submissions").insert({
      category,
      message,
      hint,
      reveal_code: code,
      status: "pending",
      ip_hash,
    });
    if (!error) return json({ ok: true, reveal_code: code }, 200);
    if (error.code !== "23505") return json({ error: "server_error" }, 500); // not a unique violation
  }
  return json({ error: "code_collision" }, 500);
});
