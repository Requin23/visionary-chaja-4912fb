import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};

const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const moderators = new Set(
  (Deno.env.get("MODERATOR_USER_IDS") ?? "")
    .split(",")
    .map((value) => value.trim())
    .filter(Boolean),
);

const admin = createClient(supabaseUrl, serviceRoleKey, {
  auth: { persistSession: false },
});

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return json({}, 204);
  if (req.method !== "GET" && req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  if (!supabaseUrl || !serviceRoleKey || moderators.size === 0) {
    return json({ error: "moderation_not_configured" }, 503);
  }

  const token = (req.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "");
  if (!token) return json({ error: "unauthorized" }, 401);

  const { data: authData, error: authError } = await admin.auth.getUser(token);
  const user = authData?.user;
  if (authError || !user) return json({ error: "unauthorized" }, 401);
  if (!moderators.has(user.id)) return json({ error: "forbidden" }, 403);

  if (req.method === "GET") {
    const { data: reports, error } = await admin
      .from("profile_reports")
      .select("id,reporter_user_id,target_profile_id,reason,status,created_at,reviewed_at,reviewed_by")
      .in("status", ["new", "reviewing"])
      .order("created_at", { ascending: false })
      .limit(50);
    if (error) return json({ error: "reports_unavailable" }, 503);

    const profileIds = [...new Set((reports ?? []).map((report) => report.target_profile_id))];
    const { data: profiles, error: profilesError } = profileIds.length
      ? await admin
          .from("profiles")
          .select("id,display_name,age,city,photo_url,is_verified,is_active")
          .in("id", profileIds)
      : { data: [], error: null };
    if (profilesError) return json({ error: "profiles_unavailable" }, 503);
    const profileById = new Map((profiles ?? []).map((profile) => [profile.id, profile]));

    return json({
      reports: (reports ?? []).map((report) => ({
        ...report,
        target_profile: profileById.get(report.target_profile_id) ?? null,
      })),
    });
  }

  const payload = await req.json().catch(() => ({}));
  const reportId = String(payload?.report_id ?? "");
  const action = String(payload?.action ?? "");
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(reportId) || !["review", "dismiss", "hide_profile"].includes(action)) {
    return json({ error: "invalid_request" }, 400);
  }

  const { data: report, error: reportError } = await admin
    .from("profile_reports")
    .select("id,target_profile_id,status")
    .eq("id", reportId)
    .maybeSingle();
  if (reportError) return json({ error: "report_unavailable" }, 503);
  if (!report) return json({ error: "report_not_found" }, 404);

  if (action === "hide_profile") {
    const { error: hideError } = await admin
      .from("profiles")
      .update({ is_active: false })
      .eq("id", report.target_profile_id);
    if (hideError) return json({ error: "profile_action_failed" }, 503);
  }

  const status = action === "review" ? "reviewing" : action === "dismiss" ? "dismissed" : "actioned";
  const { error: updateError } = await admin
    .from("profile_reports")
    .update({ status, reviewed_at: new Date().toISOString(), reviewed_by: user.id })
    .eq("id", reportId);
  if (updateError) return json({ error: "report_update_failed" }, 503);

  return json({ success: true, status });
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "content-type": "application/json" },
  });
}
