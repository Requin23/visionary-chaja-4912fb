import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const resendApiKey = Deno.env.get("RESEND_API_KEY") ?? "";
const verificationPepper = Deno.env.get("VERIFICATION_CODE_PEPPER") ?? "";
const fromEmail = Deno.env.get("RESEND_FROM_EMAIL") ?? "onboarding@resend.dev";

const admin = createClient(supabaseUrl, serviceRoleKey, {
  auth: { persistSession: false },
});

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return json({}, 204);
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  if (!supabaseUrl || !serviceRoleKey || !resendApiKey || !verificationPepper) {
    return json({ error: "missing_server_config" }, 500);
  }

  const { email } = await req.json().catch(() => ({}));
  const normalizedEmail = String(email || "").trim().toLowerCase();
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(normalizedEmail) || normalizedEmail.length > 254) {
    return json({ error: "invalid_email" }, 400);
  }

  // The database RPC serializes requests for the same email so parallel calls
  // cannot bypass the one-minute cooldown or hourly quota.
  const { data: reserved, error: limitError } = await admin.rpc("reserve_verification_code_request", {
    p_email: normalizedEmail,
  });
  if (limitError) return json({ error: "rate_limit_unavailable" }, 503);
  if (reserved !== true) return json({ error: "rate_limited" }, 429);

  const code = String(crypto.getRandomValues(new Uint32Array(1))[0] % 1000000).padStart(6, "0");
  const codeHash = await hashCode(code, verificationPepper);
  const expiresAt = new Date(Date.now() + 10 * 60 * 1000).toISOString();

  // A new code invalidates any earlier code for this address.
  const { error: invalidateError } = await admin
    .from("verification_codes")
    .update({ verified: true })
    .eq("email", normalizedEmail)
    .eq("verified", false);
  if (invalidateError) return json({ error: "verification_unavailable" }, 503);

  const { error: insertError } = await admin.from("verification_codes").insert({
    email: normalizedEmail,
    code_hash: codeHash,
    expires_at: expiresAt,
  });

  if (insertError) return json({ error: "verification_unavailable" }, 503);

  const resendResponse = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${resendApiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      from: fromEmail,
      to: normalizedEmail,
      subject: "Ton code de vérification mbifê",
      text: `Ton code mbifê est ${code}. Il expire dans 10 minutes.`,
      html: `<p>Ton code mbifê est <strong>${code}</strong>.</p><p>Il expire dans 10 minutes.</p>`,
    }),
  });

  if (!resendResponse.ok) {
    // Do not leave a valid code behind when the email provider rejects delivery.
    await admin
      .from("verification_codes")
      .update({ verified: true })
      .eq("email", normalizedEmail)
      .eq("code_hash", codeHash);
    return json({ error: "email_delivery_failed" }, 502);
  }

  return json({ success: true });
});

async function hashCode(code: string, pepper: string) {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(pepper),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const digest = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(code));
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "content-type": "application/json" },
  });
}
