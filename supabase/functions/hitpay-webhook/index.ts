// ============================================================================
//  Supabase Edge Function: hitpay-webhook
//  接收 HitPay 的支付结果回调（客人在 HitPay 收银页完成付款后，HitPay 服务器
//  会 POST 到这个地址）。验证签名通过、状态是 completed 后，把对应订单从
//  pending 改成 preparing（跟 POS markPaid() 对 app 订单的效果一致），
//  并给会员结算 XP/Coin（跟 confirmOrder() 里 TNG 预付款分支同逻辑）。
//  另外：自取/外卖订单付款到账时，给所有开了 notify.html「订单提醒」的手机发 Web Push。
//
//  HitPay 那边要把这个函数的 URL 填进「Webhook」——不过 hitpay-checkout 已经
//  在创建 payment request 时把 webhook 参数自动带上了，通常不需要手动填。
//
//  需要设的密钥（Supabase 后台 → Edge Functions → Secrets）：
//    HITPAY_SALT                HitPay 后台 API Keys 页面里那个用来验证
//                                webhook 签名的 salt（不是 API Key 本身）
//    VAPID_PUBLIC_KEY           手机推送公钥（跟 notify.html 里的那串一致）
//    VAPID_PRIVATE_KEY          手机推送私钥（只放这里，别提交进代码库）
//    VAPID_SUBJECT              可选，mailto:你的邮箱（默认一个占位邮箱）
//    SUPABASE_SERVICE_ROLE_KEY  Supabase 自动注入，不用手动设置
//    SUPABASE_URL               Supabase 自动注入，不用手动设置
// ============================================================================

import webpush from "npm:web-push@3.6.7";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

async function hmacHex(secret: string, msg: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(msg));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

// HitPay 官方验签方式：除 hmac 外的所有参数按 key 字母序排序，
// 相邻 key+value 直接拼接（不加分隔符），再用 salt 做 HMAC-SHA256 取 hex。
function buildSignSource(params: Record<string, string>): string {
  return Object.keys(params).filter((k) => k !== "hmac").sort()
    .map((k) => k + params[k]).join("");
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

// 自取/外卖订单付款到账时，给所有开了「订单提醒」的手机发 Web Push。
// 只推自取/外卖（堂食客人就在店里，不打扰）。失效订阅（404/410）顺手删掉。
async function sendOrderPush(SUPABASE_URL: string, SERVICE_KEY: string, order: Record<string, unknown>) {
  try {
    const PUB = Deno.env.get("VAPID_PUBLIC_KEY");
    const PRIV = Deno.env.get("VAPID_PRIVATE_KEY");
    const SUBJ = Deno.env.get("VAPID_SUBJECT") || "mailto:shop@puddingmeow.example";
    if (!PUB || !PRIV) { console.warn("hitpay-webhook: VAPID keys 未设置，跳过推送"); return; }
    const tn = String(order.table_name || "");
    const isDelivery = tn.includes("外卖");
    const isPickup = tn.includes("自取");
    if (!isDelivery && !isPickup) return;

    webpush.setVapidDetails(SUBJ, PUB, PRIV);
    const num = String(order.order_num ?? "").padStart(2, "0");
    const code = (isDelivery ? "DL" : "TA") + num;
    const kind = isDelivery ? "外卖" : "自取";
    const payload = JSON.stringify({
      title: `🔔 新${kind}订单 ${code}`,
      body: `RM ${Number(order.total || 0).toFixed(2)} · 已付款，请备餐`,
      url: "./notify.html",
      tag: "order-" + String(order.id),
    });

    const subsRes = await fetch(
      `${SUPABASE_URL}/rest/v1/push_subscriptions?select=endpoint,p256dh,auth`,
      { headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` } },
    );
    const subs = await subsRes.json().catch(() => []);
    if (!Array.isArray(subs) || !subs.length) return;

    await Promise.all(subs.map(async (s: { endpoint: string; p256dh: string; auth: string }) => {
      try {
        await webpush.sendNotification(
          { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
          payload,
        );
      } catch (err) {
        const sc = (err as { statusCode?: number; status?: number })?.statusCode
          ?? (err as { status?: number })?.status;
        if (sc === 404 || sc === 410) {
          await fetch(
            `${SUPABASE_URL}/rest/v1/push_subscriptions?endpoint=eq.${encodeURIComponent(s.endpoint)}`,
            { method: "DELETE", headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` } },
          ).catch(() => {});
        } else {
          console.error("push send error", sc, (err as { body?: unknown })?.body);
        }
      }
    }));
  } catch (e) {
    console.error("sendOrderPush error", e);
  }
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const json = (obj: unknown, status = 200) =>
    new Response(JSON.stringify(obj), { status, headers: { ...cors, "Content-Type": "application/json" } });

  try {
    const SALT = Deno.env.get("HITPAY_SALT");
    const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
    const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!SALT || !SUPABASE_URL || !SERVICE_KEY) {
      console.error("hitpay-webhook: missing HITPAY_SALT / SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY");
      return json({ ok: false, error: "服务器未配置齐全" });
    }

    const ct = req.headers.get("content-type") || "";
    const params: Record<string, string> = {};
    if (ct.includes("application/json")) {
      const body = await req.json().catch(() => ({}));
      for (const k of Object.keys(body || {})) params[k] = String(body[k]);
    } else {
      const fd = await req.formData().catch(() => null);
      if (fd) for (const [k, v] of fd.entries()) params[k] = String(v);
    }

    const receivedHmac = params.hmac || "";
    const computedHmac = await hmacHex(SALT, buildSignSource(params));
    if (!receivedHmac || !timingSafeEqual(receivedHmac, computedHmac)) {
      console.error("hitpay-webhook: signature mismatch", { params });
      return json({ ok: false, error: "签名校验失败" }); // 200，避免 HitPay 无意义重试
    }

    const referenceNumber = params.reference_number || "";
    const status = params.status || "";
    if (!referenceNumber || status !== "completed") {
      return json({ ok: true, skipped: true }); // 未完成/取消/失败的回调，不用处理
    }

    // 先读这张单，判断是「钱包充值」还是普通餐单——两者到账方式不同
    const getRes = await fetch(
      `${SUPABASE_URL}/rest/v1/orders?id=eq.${encodeURIComponent(referenceNumber)}&select=id,ta_mode,member_id,total,status,table_name,order_num`,
      { headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` } },
    );
    const found = await getRes.json().catch(() => []);
    const order = Array.isArray(found) && found[0];
    if (!order || order.status !== "pending") {
      return json({ ok: true, skipped: true }); // 单不在 / 已处理过（防 HitPay 重试重复结算）
    }

    if (order.ta_mode === "recharge") {
      // 钱包充值：走 rpc_complete_recharge，服务端给钱包加钱 + 送 coin，订单翻 done，
      // 且只在还 pending 时生效（幂等），HitPay 重试回调不会重复到账。
      const rpcRes = await fetch(`${SUPABASE_URL}/rest/v1/rpc/rpc_complete_recharge`, {
        method: "POST",
        headers: { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}`, "Content-Type": "application/json" },
        body: JSON.stringify({ p_order_id: order.id }),
      });
      if (!rpcRes.ok) {
        console.error("hitpay-webhook: rpc_complete_recharge failed", await rpcRes.text());
        return json({ ok: false, error: "充值到账失败" });
      }
      return json({ ok: true, recharge: true });
    }

    // 普通餐单：pending → preparing（带 status=pending 守卫防重复），再结算会员 XP/Coin
    const patchRes = await fetch(
      `${SUPABASE_URL}/rest/v1/orders?id=eq.${encodeURIComponent(referenceNumber)}&status=eq.pending`,
      {
        method: "PATCH",
        headers: {
          apikey: SERVICE_KEY,
          Authorization: `Bearer ${SERVICE_KEY}`,
          "Content-Type": "application/json",
          Prefer: "return=representation",
        },
        body: JSON.stringify({ status: "preparing" }),
      },
    );
    const rows = await patchRes.json().catch(() => []);
    if (!patchRes.ok) {
      console.error("hitpay-webhook: order update failed", rows);
      return json({ ok: false, error: "订单更新失败" });
    }
    const updated = Array.isArray(rows) && rows[0];
    if (updated && updated.member_id) {
      const rpcRes = await fetch(`${SUPABASE_URL}/rest/v1/rpc/rpc_on_order_completed`, {
        method: "POST",
        headers: {
          apikey: SERVICE_KEY,
          Authorization: `Bearer ${SERVICE_KEY}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ p_member_id: updated.member_id, p_order_id: updated.id, p_amount: updated.total }),
      });
      if (!rpcRes.ok) console.error("hitpay-webhook: rpc_on_order_completed failed", await rpcRes.text());
    }

    // 自取/外卖：付款到账 → 推送到店员手机（尽力而为，失败不影响订单已翻 preparing）
    if (updated) await sendOrderPush(SUPABASE_URL, SERVICE_KEY, updated as Record<string, unknown>);

    return json({ ok: true });
  } catch (e) {
    console.error("hitpay-webhook error", e);
    return json({ ok: false, error: String(e) });
  }
});
