import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const verificationPepper = Deno.env.get("VERIFICATION_CODE_PEPPER") ?? "";

const admin = createClient(supabaseUrl, serviceRoleKey, {
  auth: { persistSession: false },
});

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return json({}, 204);
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  if (!supabaseUrl || !serviceRoleKey || !verificationPepper) return json({ error: "missing_server_config" }, 500);

  const { email, code } = await req.json().catch(() => ({}));
  const normalizedEmail = String(email || "").trim().toLowerCase();
  const normalizedCode = String(code || "").trim();

  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(normalizedEmail) || normalizedEmail.length > 254 || !/^\d{6}$/.test(normalizedCode)) {
    return json({ error: "invalid" }, 400);
  }

  const { data: result, error: verifyError } = await admin.rpc("verify_email_code", {
    p_email: normalizedEmail,
    p_code_hash: await hashCode(normalizedCode, verificationPepper),
  });
  if (verifyError) return json({ error: "verification_unavailable" }, 503);

  if (result !== "verified") {
    const message = result === "expired" ? "expired" : result === "locked" ? "locked" : "invalid";
    return json({ error: message }, 400);
  }

  const user = await findUserByEmail(normalizedEmail);
  if (!user?.id) return json({ error: "account_not_found" }, 404);

  const { error: confirmError } = await admin.auth.admin.updateUserById(user.id, { email_confirm: true });
  if (confirmError) return json({ error: "account_confirmation_failed" }, 503);

  const { error: profileError } = await admin
    .from("profiles")
    .update({ is_verified: true })
    .eq("user_id", user.id);
  if (profileError) return json({ error: "profile_confirmation_failed" }, 503);

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

async function findUserByEmail(email: string) {
  for (let page = 1; page <= 20; page += 1) {
    const { data, error } = await admin.auth.admin.listUsers({ page, perPage: 100 });
    if (error || !data?.users?.length) return null;
    const found = data.users.find((user) => user.email?.toLowerCase() === email);
    if (found) return found;
    if (data.users.length < 100) return null;
  }
  return null;
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "content-type": "application/json" },
  });
}
