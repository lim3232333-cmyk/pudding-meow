// ============================================================================
//  Supabase Edge Function: lalamove-driver
//  取骑手的实时位置：顾客打开订单详情页时，前端每隔十几秒调一次，把坐标画到地图上。
//
//  Lalamove 的骑手坐标不走 webhook（webhook 只推状态 + 骑手姓名电话），
//  要主动查这个接口：GET /v3/orders/{orderId}/drivers/{driverId}
//  → data.coordinates = { lat, lng, updatedAt }，位置每 10 秒更新一次，
//  查得比这更勤也只会拿到上一次的位置，所以前端 15 秒一轮就够了。
//
//  可查的时间窗：骑手到达取餐点（或 scheduleAt 前 1 小时，取早的那个）
//  → 订单完成为止。窗口外 Lalamove 返回 403 —— 那不是故障，是「现在没有位置可给」，
//  所以这里统一转成 { ok:true, available:false }，前端只要不画那个点就行，不用弹错。
//
//  前端只传我们自己的订单 id，Lalamove 的 orderId / driverId 由本函数在库里查，
//  不下发给浏览器（少暴露一个可以拿去调 Lalamove 的凭据）。
//
//  前端调用（supabase-js，从小程序）：
//    db.functions.invoke('lalamove-driver', { body: { orderId: '<我们的订单id>' } })
//
//  需要的密钥（Supabase 后台 → Edge Functions → Secrets）：
//    LALAMOVE_KEY, LALAMOVE_SECRET     （和 lalamove-quote / lalamove-order 同一对）
//    SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY  （Supabase 自动注入，无需设置）
//  可选：LALAMOVE_MARKET(MY) / LALAMOVE_HOST(sandbox)
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

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const json = (obj: unknown, status = 200) =>
    new Response(JSON.stringify(obj), { status, headers: { ...cors, "Content-Type": "application/json" } });

  try {
    const KEY = Deno.env.get("LALAMOVE_KEY");
    const SECRET = Deno.env.get("LALAMOVE_SECRET");
    if (!KEY || !SECRET) return json({ ok: false, error: "未设置 LALAMOVE_KEY / LALAMOVE_SECRET" });

    const SUPABASE_URL = Deno.env.get("SUPABASE_URL");
    const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!SUPABASE_URL || !SERVICE_KEY) return json({ ok: false, error: "服务器未配置齐全" });

    const MARKET = Deno.env.get("LALAMOVE_MARKET") || "MY";
    const HOST = Deno.env.get("LALAMOVE_HOST") || "https://rest.sandbox.lalamove.com";

    const input = await req.json().catch(() => ({} as any));
    const orderId = String(input?.orderId || "");
    if (!orderId) return json({ ok: false, error: "缺少 orderId" });

    // GET 没有 body，签名串里 BODY 段留空
    async function signedGet(path: string) {
      const ts = Date.now().toString();
      const sig = await hmacHex(SECRET!, `${ts}\r\nGET\r\n${path}\r\n\r\n`);
      const res = await fetch(HOST + path, {
        headers: {
          "Content-Type": "application/json",
          "Authorization": `hmac ${KEY}:${ts}:${sig}`,
          "Market": MARKET,
          "Request-ID": crypto.randomUUID(),
        },
      });
      const text = await res.text();
      let out: any;
      try { out = JSON.parse(text); } catch { out = { raw: text }; }
      return { res, out, text };
    }

    // 1) 从库里取这单的 Lalamove orderId / driverId
    const restBase = SUPABASE_URL + "/rest/v1/orders";
    const authHeaders = {
      apikey: SERVICE_KEY,
      Authorization: `Bearer ${SERVICE_KEY}`,
      "Content-Type": "application/json",
    };
    const findRes = await fetch(
      `${restBase}?select=id,delivery_info&id=eq.${encodeURIComponent(orderId)}`,
      { headers: authHeaders },
    );
    const rows = await findRes.json().catch(() => []);
    if (!findRes.ok) { console.error("lalamove-driver find failed", rows); return json({ ok: false, error: "查询订单失败" }); }
    if (!Array.isArray(rows) || !rows.length) return json({ ok: false, error: "订单不存在" });

    const di = rows[0].delivery_info || {};
    const lm = di.lalamove || {};
    const lmOrderId = String(lm.orderId || "");
    if (!lmOrderId) return json({ ok: true, available: false, reason: "尚未叫车" });

    // 2) driverId 可能还没落库（webhook 还没到 / 下单时还没派到人）——直接问 Lalamove 要
    let driverId = String(lm.driverId || "");
    let status = String(lm.status || "");
    if (!driverId) {
      const od = await signedGet(`/v3/orders/${encodeURIComponent(lmOrderId)}`);
      if (od.res.ok) {
        driverId = String(od.out?.data?.driverId || "");
        status = String(od.out?.data?.status || status);
      }
      if (!driverId) return json({ ok: true, available: false, reason: "尚未派到骑手", status });
    }

    // 3) 取骑手位置。403 = 不在可查时间窗内（还没到店取餐 / 订单已结束），不是错误
    const dr = await signedGet(`/v3/orders/${encodeURIComponent(lmOrderId)}/drivers/${encodeURIComponent(driverId)}`);
    if (dr.res.status === 403) return json({ ok: true, available: false, reason: "位置暂不可查", status });
    if (!dr.res.ok) {
      console.error("lalamove-driver fetch failed", dr.res.status, dr.text);
      return json({ ok: true, available: false, reason: "位置获取失败", status });
    }

    const d = dr.out?.data || {};
    const c = d.coordinates || {};
    const lat = Number(c.lat), lng = Number(c.lng);
    if (!isFinite(lat) || !isFinite(lng)) return json({ ok: true, available: false, reason: "无坐标", status });

    return json({
      ok: true,
      available: true,
      status,
      driver: {
        name: d.name || "",
        phone: d.phone || "",
        plateNumber: d.plateNumber || "",
        photo: d.photo || "",
      },
      coordinates: { lat, lng, updatedAt: c.updatedAt || "" },
    });
  } catch (e) {
    console.error("lalamove-driver error", e);
    return json({ ok: false, error: String(e) });
  }
});
