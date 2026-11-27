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
    const url = new URL(req.url);
    const page = Math.max(0, Math.min(10000, Number.parseInt(url.searchParams.get("page") ?? "0", 10) || 0));
    const start = page * 100;
    if (url.searchParams.get("view") === "profiles") {
      const { data: profiles, error } = await admin
        .from("profiles")
        .select("id,display_name,age,city,photo_url,is_verified,is_active")
        .order("display_name", { ascending: true })
        .range(start, start + 100);
      if (error) return json({ error: "profiles_unavailable" }, 503);
      const rows = profiles ?? [];
      return json({ profiles: rows.slice(0, 100), has_more: rows.length > 100 });
    }

    const requestedStatus = url.searchParams.get("status") ?? "open";
    let query = admin
      .from("profile_reports")
      .select("id,reporter_user_id,target_profile_id,reason,status,created_at,reviewed_at,reviewed_by")
      .order("created_at", { ascending: false })
      .range(start, start + 100);
    if (requestedStatus === "open") query = query.in("status", ["new", "reviewing"]);
    else if (["new", "reviewing", "actioned", "dismissed"].includes(requestedStatus)) {
      query = query.eq("status", requestedStatus);
    } else if (requestedStatus !== "all") {
      return json({ error: "invalid_status" }, 400);
    }
    const { data: reports, error } = await query;
    if (error) return json({ error: "reports_unavailable" }, 503);

    const profileIds = [...new Set((reports ?? []).map((report) => report.target_profile_id))];
    const reporterIds = [...new Set((reports ?? []).map((report) => report.reporter_user_id))];
    const { data: profiles, error: profilesError } = profileIds.length
      ? await admin
          .from("profiles")
          .select("id,display_name,age,city,photo_url,is_verified,is_active")
          .in("id", profileIds)
      : { data: [], error: null };
    if (profilesError) return json({ error: "profiles_unavailable" }, 503);
    const { data: reporterProfiles, error: reporterProfilesError } = reporterIds.length
      ? await admin
          .from("profiles")
          .select("user_id,display_name,age,city")
          .in("user_id", reporterIds)
      : { data: [], error: null };
    if (reporterProfilesError) return json({ error: "profiles_unavailable" }, 503);
    const profileById = new Map((profiles ?? []).map((profile) => [profile.id, profile]));
    const reporterById = new Map((reporterProfiles ?? []).map((profile) => [profile.user_id, profile]));

    return json({
      reports: (reports ?? []).slice(0, 100).map((report) => ({
        ...report,
        target_profile: profileById.get(report.target_profile_id) ?? null,
        reporter_profile: reporterById.get(report.reporter_user_id) ?? null,
      })),
      has_more: (reports ?? []).length > 100,
    });
  }

  const payload = await req.json().catch(() => ({}));
  const profileId = String(payload?.profile_id ?? "");
  if (payload?.action === "set_profile_visibility") {
    if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(profileId) || typeof payload?.is_active !== "boolean") {
      return json({ error: "invalid_request" }, 400);
    }
    const { error } = await admin
      .from("profiles")
      .update({ is_active: payload.is_active })
      .eq("id", profileId);
    if (error) return json({ error: "profile_action_failed" }, 503);
    return json({ success: true, is_active: payload.is_active });
  }

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
