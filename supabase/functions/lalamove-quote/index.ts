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
    if (!KEY || !SECRET) return json({ error: "未设置 LALAMOVE_KEY / LALAMOVE_SECRET" }, 500);

    const MARKET = Deno.env.get("LALAMOVE_MARKET") || "MY";
    const HOST = Deno.env.get("LALAMOVE_HOST") || "https://rest.sandbox.lalamove.com";
    const STORE_LAT = Deno.env.get("STORE_LAT") || "2.1988866";
    const STORE_LNG = Deno.env.get("STORE_LNG") || "102.2287024";
    const STORE_ADDR = Deno.env.get("STORE_ADDRESS") ||
      "NO K5, JALAN KPKS 1, KOMPLEKS PRENIAGAAN KOTA SHAYBANDAR, 75200 MELAKA";

    const input = await req.json().catch(() => ({} as any));
    const drop = input?.dropoff || {};
    if (!drop.lat || !drop.lng) return json({ error: "缺少送货点坐标 dropoff.lat / dropoff.lng" }, 400);

    const bodyObj = {
      data: {
        serviceType: input.serviceType || "MOTORCYCLE",
        language: "en_MY",
        stops: [
          { coordinates: { lat: String(STORE_LAT), lng: String(STORE_LNG) }, address: STORE_ADDR },
          { coordinates: { lat: String(drop.lat), lng: String(drop.lng) }, address: String(drop.address || "") },
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

    if (!res.ok) return json({ ok: false, status: res.status, error: out?.message || out?.errors || text });

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
    return json({ error: String(e) }, 500);
  }
});
