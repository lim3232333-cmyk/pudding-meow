// ============================================================================
//  Supabase Edge Function: hitpay-webhook
//  接收 HitPay 的支付结果回调（客人在 HitPay 收银页完成付款后，HitPay 服务器
//  会 POST 到这个地址）。验证签名通过、状态是 completed 后，把对应订单从
//  pending 改成 preparing（跟 POS markPaid() 对 app 订单的效果一致），
//  并给会员结算 XP/Coin（跟 confirmOrder() 里 TNG 预付款分支同逻辑）。
//
//  HitPay 那边要把这个函数的 URL 填进「Webhook」——不过 hitpay-checkout 已经
//  在创建 payment request 时把 webhook 参数自动带上了，通常不需要手动填。
//
//  需要设的密钥（Supabase 后台 → Edge Functions → Secrets）：
//    HITPAY_SALT                HitPay 后台 API Keys 页面里那个用来验证
//                                webhook 签名的 salt（不是 API Key 本身）
//    SUPABASE_SERVICE_ROLE_KEY  Supabase 自动注入，不用手动设置
//    SUPABASE_URL               Supabase 自动注入，不用手动设置
// ============================================================================

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

    // 只更新还是 pending 的订单，避免 HitPay 重试回调重复结算会员奖励
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

    const order = Array.isArray(rows) && rows[0];
    if (order && order.member_id) {
      const rpcRes = await fetch(`${SUPABASE_URL}/rest/v1/rpc/rpc_on_order_completed`, {
        method: "POST",
        headers: {
          apikey: SERVICE_KEY,
          Authorization: `Bearer ${SERVICE_KEY}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ p_member_id: order.member_id, p_order_id: order.id, p_amount: order.total }),
      });
      if (!rpcRes.ok) console.error("hitpay-webhook: rpc_on_order_completed failed", await rpcRes.text());
    }

    return json({ ok: true });
  } catch (e) {
    console.error("hitpay-webhook error", e);
    return json({ ok: false, error: String(e) });
  }
});
