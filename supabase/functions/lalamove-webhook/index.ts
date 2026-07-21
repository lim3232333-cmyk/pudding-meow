// ============================================================================
//  Supabase Edge Function: lalamove-webhook
//  接收 Lalamove 的订单状态回调（骑手接单 / 取餐 / 送达 等）。按订单里存的
//  Lalamove orderId 找到对应订单，把最新状态 + 骑手信息写进 delivery_info.lalamove。
//  POS 和顾客订单页通过已有的 realtime 订阅自动刷新，看到「配送中 / 已送达」。
//
//  Lalamove 是账号级别设一个 webhook 地址（在 Lalamove 开发者后台登记本函数 URL），
//  不像 HitPay 每单带。事件类型主要是 ORDER_STATUS_CHANGED 和 DRIVER_ASSIGNED。
//
//  安全说明：Lalamove v3 的 webhook 没有像 HitPay 那样的共享密钥 HMAC 签名，
//  这里靠「只更新数据库里已经存在、且 lalamove.orderId 完全匹配的订单」来防滥用
//  （orderId 是一长串不可猜的字符串）。状态只是展示用、不涉及金额，风险很低。
//
//  需要的密钥：SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY（Supabase 自动注入，无需设置）
//  部署时 Verify JWT 要关掉（Lalamove 服务器调用，没有你的登录令牌）。
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
    const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
    const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!SUPABASE_URL || !SERVICE_KEY) {
      console.error("lalamove-webhook: missing SUPABASE_URL / SUPABASE_SERVICE_ROLE_KEY");
      return json({ ok: false, error: "服务器未配置齐全" });
    }

    const body = await req.json().catch(() => ({} as any));
    const data = body?.data || {};
    const order = data.order || data;
    const driver = data.driver || {};

    // orderId / status 在不同事件里位置略有差异，做几处兜底
    const lmOrderId = order.orderId || data.orderId || body.orderId || "";
    const status = order.status || data.status || "";
    if (!lmOrderId) return json({ ok: true, skipped: "no orderId" });

    const restBase = SUPABASE_URL + "/rest/v1/orders";
    const authHeaders = {
      apikey: SERVICE_KEY,
      Authorization: `Bearer ${SERVICE_KEY}`,
      "Content-Type": "application/json",
    };

    // 找到 delivery_info.lalamove.orderId == lmOrderId 的订单
    const findRes = await fetch(
      `${restBase}?select=id,delivery_info&delivery_info->lalamove->>orderId=eq.${encodeURIComponent(lmOrderId)}`,
      { headers: authHeaders },
    );
    const rows = await findRes.json().catch(() => []);
    if (!findRes.ok) { console.error("lalamove-webhook find failed", rows); return json({ ok: false, error: "查询失败" }); }
    if (!Array.isArray(rows) || !rows.length) return json({ ok: true, skipped: "order not found" });

    const row = rows[0];
    const di = row.delivery_info || {};
    const lm = di.lalamove || {};
    if (status) lm.status = status;
    if (driver.driverId) lm.driverId = driver.driverId;
    if (driver.name) lm.driverName = driver.name;
    if (driver.phone) lm.driverPhone = driver.phone;
    if (driver.plateNumber) lm.driverPlate = driver.plateNumber;
    lm.updatedAt = new Date().toISOString();
    di.lalamove = lm;

    const patchRes = await fetch(`${restBase}?id=eq.${encodeURIComponent(row.id)}`, {
      method: "PATCH",
      headers: { ...authHeaders, Prefer: "return=minimal" },
      body: JSON.stringify({ delivery_info: di }),
    });
    if (!patchRes.ok) { console.error("lalamove-webhook update failed", await patchRes.text()); return json({ ok: false, error: "更新失败" }); }

    return json({ ok: true });
  } catch (e) {
    console.error("lalamove-webhook error", e);
    return json({ ok: false, error: String(e) });
  }
});
