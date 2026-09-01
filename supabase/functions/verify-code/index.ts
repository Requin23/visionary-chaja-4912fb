import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";

const admin = createClient(supabaseUrl, serviceRoleKey, {
  auth: { persistSession: false },
});

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return json({}, 204);
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  if (!supabaseUrl || !serviceRoleKey) return json({ error: "missing_server_config" }, 500);

  const { email, code } = await req.json().catch(() => ({}));
  const normalizedEmail = String(email || "").trim().toLowerCase();
  const normalizedCode = String(code || "").trim();

  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(normalizedEmail) || !/^\d{6}$/.test(normalizedCode)) {
    return json({ error: "invalid" }, 400);
  }

  const { data: latest, error: lookupError } = await admin
    .from("verification_codes")
    .select("id,code,expires_at,verified")
    .eq("email", normalizedEmail)
    .eq("verified", false)
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (lookupError) return json({ error: lookupError.message }, 500);
  if (!latest) return json({ error: "expired" }, 400);
  if (new Date(latest.expires_at).getTime() < Date.now()) return json({ error: "expired" }, 400);
  if (latest.code !== normalizedCode) return json({ error: "invalid" }, 400);

  const { error: updateError } = await admin
    .from("verification_codes")
    .update({ verified: true })
    .eq("id", latest.id);

  if (updateError) return json({ error: updateError.message }, 500);

  const user = await findUserByEmail(normalizedEmail);
  if (user?.id) {
    await admin.auth.admin.updateUserById(user.id, { email_confirm: true });
    await admin.from("profiles").update({ is_verified: true }).eq("user_id", user.id);
  }

  return json({ success: true });
});

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
