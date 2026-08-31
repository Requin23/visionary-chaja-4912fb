import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

type NotificationRow = {
  id: string;
  user_id: string;
  kind: string;
  title: string;
  body: string;
  data: Record<string, unknown> | null;
};

type PushSubscriptionRow = {
  id: string;
  endpoint: string;
  p256dh: string;
  auth: string;
};

const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
const vapidPublicKey = Deno.env.get("VAPID_PUBLIC_KEY") ?? "";
const vapidPrivateKey = Deno.env.get("VAPID_PRIVATE_KEY") ?? "";
const vapidSubject = Deno.env.get("VAPID_SUBJECT") ?? "mailto:admin@example.com";

webpush.setVapidDetails(vapidSubject, vapidPublicKey, vapidPrivateKey);

const admin = createClient(supabaseUrl, serviceRoleKey, {
  auth: { persistSession: false },
});

Deno.serve(async (req) => {
  if (req.method !== "POST") {
    return json({ error: "Method not allowed" }, 405);
  }

  if (!supabaseUrl || !serviceRoleKey || !vapidPublicKey || !vapidPrivateKey) {
    return json({ error: "Missing Supabase or VAPID secrets" }, 500);
  }

  const authHeader = req.headers.get("authorization") ?? "";
  if (authHeader !== `Bearer ${serviceRoleKey}`) {
    return json({ error: "Unauthorized" }, 401);
  }

  const { notification_id } = await req.json().catch(() => ({}));
  if (!notification_id) {
    return json({ error: "notification_id is required" }, 400);
  }

  const { data: notification, error: notificationError } = await admin
    .from("notifications")
    .select("id,user_id,kind,title,body,data")
    .eq("id", notification_id)
    .maybeSingle<NotificationRow>();

  if (notificationError || !notification) {
    return json({ error: notificationError?.message ?? "Notification not found" }, 404);
  }

  const { data: subscriptions, error: subscriptionsError } = await admin
    .from("push_subscriptions")
    .select("id,endpoint,p256dh,auth")
    .eq("user_id", notification.user_id)
    .returns<PushSubscriptionRow[]>();

  if (subscriptionsError) {
    return json({ error: subscriptionsError.message }, 500);
  }

  const payload = JSON.stringify({
    title: notification.title || "mbife",
    body: notification.body || "Tu as une nouvelle activite.",
    tag: `${notification.kind}-${notification.id}`,
    url: "/?panel=messages",
    data: notification.data ?? {},
  });

  const results = await Promise.allSettled(
    (subscriptions ?? []).map(async (row) => {
      try {
        await webpush.sendNotification(
          {
            endpoint: row.endpoint,
            keys: {
              p256dh: row.p256dh,
              auth: row.auth,
            },
          },
          payload,
        );
        return { id: row.id, ok: true };
      } catch (error) {
        const statusCode = Number((error as { statusCode?: number }).statusCode ?? 0);
        if (statusCode === 404 || statusCode === 410) {
          await admin.from("push_subscriptions").delete().eq("id", row.id);
        }
        throw error;
      }
    }),
  );

  await admin
    .from("notifications")
    .update({ pushed_at: new Date().toISOString() })
    .eq("id", notification.id);

  return json({
    sent: results.filter((result) => result.status === "fulfilled").length,
    failed: results.filter((result) => result.status === "rejected").length,
  });
});

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}
