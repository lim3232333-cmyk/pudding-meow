// ============================================================================
//  Supabase Edge Function: hitpay-checkout
//  创建 HitPay Payment Request，返回给前端一个 hosted 收银页链接去跳转。
//  API Key 只存在本函数的环境变量里，前端（小程序）永远拿不到密钥。
//
//  前端调用（supabase-js）：
//    db.functions.invoke('hitpay-checkout', {
//      body: { orderId, amount, currency?, redirectUrl, customerName?, customerPhone? }
//    })
//
//  需要设的密钥（Supabase 后台 → Edge Functions → Secrets）：
//    HITPAY_API_KEY   商家 API Key（sandbox 用 test_ 开头的那个，上线换成 live key）
//  可选：
//    HITPAY_HOST      默认 https://api.sandbox.hit-pay.com（上线改成 https://api.hit-pay.com）
//
//  webhook 地址会自动拼成本项目的 hitpay-webhook 函数地址（用 Supabase 自动注入的
//  SUPABASE_URL 环境变量），不需要额外配置。
// ============================================================================

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const json = (obj: unknown, status = 200) =>
    new Response(JSON.stringify(obj), { status, headers: { ...cors, "Content-Type": "application/json" } });

  try {
    const API_KEY = Deno.env.get("HITPAY_API_KEY");
    if (!API_KEY) return json({ ok: false, error: "未设置 HITPAY_API_KEY（去 Edge Functions → Secrets 里加）" });

    const HOST = Deno.env.get("HITPAY_HOST") || "https://api.sandbox.hit-pay.com";
    const SUPABASE_URL = Deno.env.get("SUPABASE_URL") || "";

    const input = await req.json().catch(() => ({} as any));
    const orderId = String(input.orderId || "").trim();
    const amount = Number(input.amount);
    const redirectUrl = String(input.redirectUrl || "").trim();

    if (!orderId) return json({ ok: false, error: "缺少 orderId" });
    if (!isFinite(amount) || amount <= 0) return json({ ok: false, error: "amount 无效" });
    try { new URL(redirectUrl); } catch { return json({ ok: false, error: "redirectUrl 无效" }); }

    const form = new URLSearchParams();
    form.set("amount", amount.toFixed(2));
    form.set("currency", input.currency || "MYR");
    form.set("reference_number", orderId);
    form.set("redirect_url", redirectUrl);
    if (SUPABASE_URL) form.set("webhook", SUPABASE_URL + "/functions/v1/hitpay-webhook");
    form.set("purpose", "布丁喵订单 #" + orderId);
    if (input.customerName) form.set("name", String(input.customerName).slice(0, 100));
    if (input.customerPhone) form.set("phone", String(input.customerPhone).slice(0, 30));
    form.set("send_sms", "false");
    form.set("send_email", "false");
    form.set("allow_repeated_payments", "false");

    // 客人在小程序里已经选好付款方式，只把这一个方式放进 payment_methods，HitPay 收银页就
    // 直接进它、跳过「选付款方式」那步。前端传的是中性码(tng/fpx/card)，HitPay 的实际叫法都收在这——
    // 若你的 HitPay 后台某个方式的码不一样，改这张表即可（不用动前端）。
    const HP_METHOD_MAP: Record<string, string[]> = {
      tng: ["tng_ewallet"], // Touch 'n Go eWallet
      fpx: ["fpx"],         // Online Banking (FPX)
      card: ["card"],       // 信用卡 / 借记卡
    };
    const methods = HP_METHOD_MAP[String(input.method || "").toLowerCase()] || [];

    const postPaymentRequest = (withMethods: boolean) => {
      const f = new URLSearchParams(form.toString());
      if (withMethods) for (const m of methods) f.append("payment_methods[]", m);
      return fetch(HOST + "/v1/payment-requests", {
        method: "POST",
        headers: {
          "X-BUSINESS-API-KEY": API_KEY,
          "Content-Type": "application/x-www-form-urlencoded",
          "Accept": "application/json",
        },
        body: f.toString(),
      });
    };

    // 先按指定方式建单；若被 HitPay 拒了（账号没开该方式/码对不上等），退回不限定方式再建一次——
    // 宁可回到完整收银页让客人自己选，也绝不让他付不了款。
    let res = await postPaymentRequest(methods.length > 0);
    if (!res.ok && methods.length > 0) res = await postPaymentRequest(false);
    const text = await res.text();
    let out: any;
    try { out = JSON.parse(text); } catch { out = { raw: text }; }

    if (!res.ok) {
      let errMsg = out?.message || out?.error;
      if (!errMsg && out?.errors) errMsg = typeof out.errors === "string" ? out.errors : JSON.stringify(out.errors);
      if (!errMsg) errMsg = text || `HTTP ${res.status}`;
      return json({ ok: false, status: res.status, error: `[${res.status}] ${errMsg}` });
    }
    if (!out?.url) return json({ ok: false, error: "HitPay 未返回支付链接", raw: out });

    return json({ ok: true, url: out.url, paymentRequestId: out.id });
  } catch (e) {
    // 跟 lalamove-quote 一样：固定 200 + { ok:false, error }，避免
    // functions.invoke 在非 2xx 时把 body 吞掉、前端看不到真实报错。
    return json({ ok: false, error: String(e) });
  }
});
