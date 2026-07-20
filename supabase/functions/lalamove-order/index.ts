// ============================================================================
//  Supabase Edge Function: lalamove-order
//  下单叫车：店员在 POS 点「叫车」时调用。先 POST /v3/quotations 拿一张新鲜的
//  报价（顾客下单时那张几分钟就过期了，不能复用），再 POST /v3/orders 正式下单，
//  Lalamove 开始派骑手。返回订单号 + 追踪链接 + 当前状态给 POS 存回订单。
//
//  API Key/Secret 只存在环境变量里，前端永远拿不到。
//
//  前端调用（supabase-js，从 POS）：
//    db.functions.invoke('lalamove-order', { body: {
//      dropoff:{lat,lng,address}, recipient:{name,phone,remarks?}, serviceType?
//    }})
//
//  需要的密钥/配置（Supabase 后台 → Edge Functions → Secrets）：
//    LALAMOVE_KEY, LALAMOVE_SECRET            （和 lalamove-quote 同一对）
//    STORE_PHONE                              发件人（店铺）联系电话，Lalamove 必填
//  可选（和 lalamove-quote 共用，已有默认）：
//    LALAMOVE_MARKET(MY) / LALAMOVE_HOST(sandbox) / STORE_LAT / STORE_LNG /
//    STORE_ADDRESS / STORE_NAME(布丁喵 Pudding Meow)
// ============================================================================

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

// 见 lalamove-quote：压小数到 7 位，经纬度填反自动对调，越界判无效。
function normCoord(latIn: unknown, lngIn: unknown): { lat: string; lng: string } | null {
  let lat = Number(latIn), lng = Number(lngIn);
  if (!isFinite(lat) || !isFinite(lng)) return null;
  const inLat = (v: number) => Math.abs(v) <= 90;
  const inLng = (v: number) => Math.abs(v) <= 180;
  if (!inLat(lat) && inLat(lng) && inLng(lat)) { const t = lat; lat = lng; lng = t; }
  if (!inLat(lat) || !inLng(lng)) return null;
  const fmt = (v: number) => v.toFixed(7).replace(/0+$/, "").replace(/\.$/, "");
  return { lat: fmt(lat), lng: fmt(lng) };
}

// 马来西亚本地号（0123456789）转成 Lalamove 要的 E.164（+60123456789）。
// 已经是 + 开头的原样返回；60 开头的补个 +。
function normPhone(p: string): string {
  let s = String(p || "").replace(/[\s-]/g, "");
  if (!s) return s;
  if (s.startsWith("+")) return s;
  if (s.startsWith("0")) return "+60" + s.slice(1);
  if (s.startsWith("60")) return "+" + s;
  return s;
}

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

    const MARKET = Deno.env.get("LALAMOVE_MARKET") || "MY";
    const HOST = Deno.env.get("LALAMOVE_HOST") || "https://rest.sandbox.lalamove.com";
    const STORE_LAT = Deno.env.get("STORE_LAT") || "2.1988866";
    const STORE_LNG = Deno.env.get("STORE_LNG") || "102.2287024";
    const STORE_ADDR = Deno.env.get("STORE_ADDRESS") ||
      "NO K5, JALAN KPKS 1, KOMPLEKS PRENIAGAAN KOTA SHAYBANDAR, 75200 MELAKA";
    const STORE_NAME = Deno.env.get("STORE_NAME") || "布丁喵 Pudding Meow";
    const STORE_PHONE = normPhone(Deno.env.get("STORE_PHONE") || "");
    if (!STORE_PHONE) return json({ ok: false, error: "未设置 STORE_PHONE（发件人电话，Lalamove 下单必填）" });

    const input = await req.json().catch(() => ({} as any));
    const drop = input?.dropoff || {};
    const recip = input?.recipient || {};
    if (!drop.lat || !drop.lng) return json({ ok: false, error: "缺少送货点坐标 dropoff.lat / dropoff.lng" });
    const recipPhone = normPhone(recip.phone || "");
    if (!recipPhone) return json({ ok: false, error: "缺少收货人电话 recipient.phone" });

    const storeCoord = normCoord(STORE_LAT, STORE_LNG);
    const dropCoord = normCoord(drop.lat, drop.lng);
    if (!storeCoord) return json({ ok: false, error: "店铺坐标无效（检查 STORE_LAT / STORE_LNG）" });
    if (!dropCoord) return json({ ok: false, error: "送货点坐标无效" });

    const serviceType = input.serviceType || "MOTORCYCLE";
    const market = MARKET;
    const reqId = () => crypto.randomUUID();

    // Lalamove 已签名请求：raw = ts\r\nMETHOD\r\nPATH\r\n\r\nBODY
    async function signedFetch(method: string, path: string, bodyObj: unknown) {
      const body = JSON.stringify(bodyObj);
      const ts = Date.now().toString();
      const sig = await hmacHex(SECRET!, `${ts}\r\n${method}\r\n${path}\r\n\r\n${body}`);
      const res = await fetch(HOST + path, {
        method,
        headers: {
          "Content-Type": "application/json",
          "Authorization": `hmac ${KEY}:${ts}:${sig}`,
          "Market": market,
          "Request-ID": reqId(),
        },
        body,
      });
      const text = await res.text();
      let out: any;
      try { out = JSON.parse(text); } catch { out = { raw: text }; }
      return { res, out, text };
    }
    function errText(out: any, text: string, status: number): string {
      let m = out?.message;
      if (!m && Array.isArray(out?.errors)) m = out.errors.map((e: any) => e?.message || e?.id || JSON.stringify(e)).join("; ");
      return `[${status}] ${m || text || "HTTP " + status}`;
    }

    // 1) 重新报价（拿新鲜 quotationId + 两个 stopId）
    const q = await signedFetch("POST", "/v3/quotations", {
      data: {
        serviceType, language: "en_MY",
        stops: [
          { coordinates: storeCoord, address: STORE_ADDR },
          { coordinates: dropCoord, address: String(drop.address || "") },
        ],
      },
    });
    if (!q.res.ok) return json({ ok: false, status: q.res.status, error: "报价失败 " + errText(q.out, q.text, q.res.status) });
    const qd = q.out?.data || {};
    const quotationId = qd.quotationId;
    const stops = qd.stops || [];
    if (!quotationId || stops.length < 2) return json({ ok: false, error: "报价返回缺少 quotationId / stops" });

    // 2) 正式下单叫车
    const o = await signedFetch("POST", "/v3/orders", {
      data: {
        quotationId,
        sender: { stopId: stops[0].stopId, name: STORE_NAME, phone: STORE_PHONE },
        recipients: [{
          stopId: stops[1].stopId,
          name: String(recip.name || "客户").slice(0, 100),
          phone: recipPhone,
          remarks: String(recip.remarks || "").slice(0, 200),
        }],
        isRecipientSMSEnabled: true,
        isPODEnabled: false,
      },
    });
    if (!o.res.ok) return json({ ok: false, status: o.res.status, error: "叫车失败 " + errText(o.out, o.text, o.res.status) });

    const od = o.out?.data || {};
    const bd = od.priceBreakdown || qd.priceBreakdown || {};
    return json({
      ok: true,
      lalamoveOrderId: od.orderId,
      status: od.status || "ASSIGNING_DRIVER",
      shareLink: od.shareLink || "",
      driverId: od.driverId || "",
      currency: bd.currency,
      price: bd.total,
      data: od,
    });
  } catch (e) {
    return json({ ok: false, error: String(e) });
  }
});
