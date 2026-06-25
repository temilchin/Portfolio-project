/* ---------------------------------------------------------------------------
 * Anonymous feature — runtime config (safe to commit / embed in the browser).
 * The anon public key is designed to be public; it is gated by Row-Level
 * Security. NEVER put the service_role key or Turnstile SECRET here.
 * Replace the YOUR-... placeholders after creating your Supabase + Turnstile.
 * ------------------------------------------------------------------------- */
window.ANON_CONFIG = {
  // Supabase project (Settings -> API)
  SUPABASE_URL: "https://dqtcwdwvegtdmsbrhbfe.supabase.co",
  SUPABASE_ANON_KEY: "sb_publishable__lL-Zh8v-iZm0xpLrgUIQg_-xRn4mqZ",

  // Deployed Edge Function endpoint (supabase functions deploy submit)
  SUBMIT_FN_URL: "https://dqtcwdwvegtdmsbrhbfe.supabase.co/functions/v1/submit",

  // Cloudflare Turnstile (OPTIONAL). Leave "" to disable the bot check for now;
  // add the site key later when you want spam protection.
  TURNSTILE_SITE_KEY: "",

  // UX limits (must match the DB CHECK + Edge Function)
  MESSAGE_MAX: 500,
  HINT_MAX: 200,
};

/* Register the service worker (asset precache + instant repeat loads). */
if ("serviceWorker" in navigator) {
  window.addEventListener("load", function () {
    navigator.serviceWorker.register("./sw.js").catch(function () {});
  });
}
