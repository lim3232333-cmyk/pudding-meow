// ============================================================================
//  Supabase Edge Function: lalamove-quote
//  Lalamove v3 报价（服务器端签名）。API Key/Secret 只存在本函数的环境变量里，
//  前端（小程序/POS）只调用本函数，永远拿不到密钥。
//
//  前端调用（supabase-js）：
//    db.functions.invoke('lalamove-quote', { body: { dropoff:{lat,lng,address}, serviceType? } })
//
//  需要设的密钥（Supabase 后台 → Edge Functions → Secrets）：
//    LALAMOVE_KEY, LALAMOVE_SECRET            （Sandbox 的 API Key / Secret）
//  可选：
//    LALAMOVE_MARKET   默认 MY
//    LALAMOVE_HOST     默认 https://rest.sandbox.lalamove.com（上线改成 https://rest.lalamove.com）
//    STORE_LAT, STORE_LNG, STORE_ADDRESS       取货点（店铺）默认已填马六甲
// ============================================================================

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

// Lalamove 对坐标的校验正则限制两件事：lat 范围 -90~90（lng -180~180），
// 以及小数最多 15 位。浏览器定位返回的是完整双精度（如 2.1993147282958984，
// 16 位小数），直接发过去必撞 "does not match pattern"。这里统一：
// 1) 经纬度明显填反（lat 越界但 lng 没越界）就自动对调；
// 2) 小数压到 7 位（约 1cm 精度）再转字符串。
function normCoord(latIn: unknown, lngIn: unknown): { lat: string; lng: string } | null {
  let lat = Number(latIn), lng = Number(lngIn);
  if (!isFinite(lat) || !isFinite(lng)) return null;
  const inLat = (v: number) => Math.abs(v) <= 90;
  const inLng = (v: number) => Math.abs(v) <= 180;
  if (!inLat(lat) && inLat(lng) && inLng(lat)) { const t = lat; lat = lng; lng = t; } // 明显反了就对调
  if (!inLat(lat) || !inLng(lng)) return null; // 纠正后仍越界，判为无效
  const fmt = (v: number) => v.toFixed(7).replace(/0+$/, "").replace(/\.$/, "");
  return { lat: fmt(lat), lng: fmt(lng) };
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
    if (!KEY || !SECRET) return json({ ok: false, error: "未设置 LALAMOVE_KEY / LALAMOVE_SECRET（去 Edge Functions → Secrets 里加）" });

    const MARKET = Deno.env.get("LALAMOVE_MARKET") || "MY";
    const HOST = Deno.env.get("LALAMOVE_HOST") || "https://rest.sandbox.lalamove.com";
    const STORE_LAT = Deno.env.get("STORE_LAT") || "2.1988866";
    const STORE_LNG = Deno.env.get("STORE_LNG") || "102.2287024";
    const STORE_ADDR = Deno.env.get("STORE_ADDRESS") ||
      "NO K5, JALAN KPKS 1, KOMPLEKS PRENIAGAAN KOTA SHAYBANDAR, 75200 MELAKA";

    const input = await req.json().catch(() => ({} as any));
    const drop = input?.dropoff || {};
    if (!drop.lat || !drop.lng) return json({ ok: false, error: "缺少送货点坐标 dropoff.lat / dropoff.lng" });

    const storeCoord = normCoord(STORE_LAT, STORE_LNG);
    if (!storeCoord) return json({ ok: false, error: "店铺坐标无效（检查 Secrets 里的 STORE_LAT / STORE_LNG，纬度要 -90~90、经度 -180~180）" });
    const dropCoord = normCoord(drop.lat, drop.lng);
    if (!dropCoord) return json({ ok: false, error: "送货点坐标无效（纬度要 -90~90、经度 -180~180）" });

    const bodyObj = {
      data: {
        serviceType: input.serviceType || "MOTORCYCLE",
        language: "en_MY",
        stops: [
          { coordinates: storeCoord, address: STORE_ADDR },
          { coordinates: dropCoord, address: String(drop.address || "") },
        ],
      },
    };
    const body = JSON.stringify(bodyObj);
    const method = "POST";
    const path = "/v3/quotations";
    const ts = Date.now().toString();
    const raw = `${ts}\r\n${method}\r\n${path}\r\n\r\n${body}`;
    const sig = await hmacHex(SECRET, raw);

    const res = await fetch(HOST + path, {
      method,
      headers: {
        "Content-Type": "application/json",
        "Authorization": `hmac ${KEY}:${ts}:${sig}`,
        "Market": MARKET,
        "Request-ID": crypto.randomUUID(),
      },
      body,
    });
    const text = await res.text();
    let out: any;
    try { out = JSON.parse(text); } catch { out = { raw: text }; }

    if (!res.ok) {
      // Lalamove 错误体常见形如 { message, errors:[{id,message}] }；统一拼成可读字符串，
      // 避免前端拿到对象/数组直接 String() 变成 "[object Object]"
      let errMsg = out?.message;
      if (!errMsg && Array.isArray(out?.errors)) {
        errMsg = out.errors.map((e: any) => e?.message || e?.id || JSON.stringify(e)).join("; ");
      }
      if (!errMsg) errMsg = text || `HTTP ${res.status}`;
      return json({ ok: false, status: res.status, error: `[${res.status}] ${errMsg}` });
    }

    // 提取给前端：运费 + quotationId（下单要用）
    const bd = out?.data?.priceBreakdown || {};
    return json({
      ok: true,
      quotationId: out?.data?.quotationId,
      currency: bd.currency,
      total: bd.total,
      priceBreakdown: bd,
      data: out?.data,
    });
  } catch (e) {
    // 同上：这里也不用非 2xx 状态码——Supabase functions.invoke 对非 2xx 响应会把 body
    // 吞掉，前端只会拿到一句笼统的 "Edge Function returned a non-2xx status code"，
    // 看不到真正的报错，所以本函数所有已知错误都固定用 200 + { ok:false, error }。
    return json({ ok: false, error: String(e) });
  }
});
