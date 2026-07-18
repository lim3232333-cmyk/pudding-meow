# Lalamove 对接 — 部署指南（第一步：报价）

密钥**只存服务器端**（Edge Function 的 Secrets），前端永远拿不到。

## 一、部署 Edge Function（Supabase 后台网页，不用 CLI）

1. 打开 Supabase 后台 → 选你的项目 → 左边栏 **Edge Functions**。
2. 点 **Deploy a new function**（或 Create function）→ 选**用编辑器写 / Via Editor**。
3. 函数名填：`lalamove-quote`
4. 把仓库里 `supabase/functions/lalamove-quote/index.ts` 的**全部代码**粘进去 → **Deploy**。

## 二、设置密钥（Secrets）

Edge Functions 页 → **Secrets / Manage secrets**（或 Project Settings → Edge Functions → Secrets），加：

| 名称 | 值 |
|------|-----|
| `LALAMOVE_KEY` | 你的 Sandbox API Key |
| `LALAMOVE_SECRET` | 你的 Sandbox API Secret |

可选（有默认值，可不填）：
| 名称 | 默认 | 说明 |
|------|------|------|
| `LALAMOVE_MARKET` | `MY` | 马来西亚 |
| `LALAMOVE_HOST` | `https://rest.sandbox.lalamove.com` | 上线后改成 `https://rest.lalamove.com` |
| `STORE_LAT` / `STORE_LNG` | `2.1988866` / `102.2287024` | 店铺取货点坐标（马六甲，已填好） |
| `STORE_ADDRESS` | 收据上的店址 | 取货点地址文字 |

> ⚠️ 密钥值填进 Secrets 就好，**别贴进代码、别发聊天**。

## 三、单独测一下函数（先不碰小程序）

Edge Functions → `lalamove-quote` → **Test / Invoke**，Body 填：

```json
{ "dropoff": { "lat": "2.2000", "lng": "102.2500", "address": "Test drop, Melaka" } }
```

**成功**会返回类似：
```json
{ "ok": true, "quotationId": "xxxx", "currency": "MYR", "total": "8.50", "priceBreakdown": { ... } }
```

**失败**会返回 `{ "ok": false, "status": 401/400, "error": ... }`：
- `401` → 密钥或签名不对，检查 `LALAMOVE_KEY/SECRET` 是不是沙盒那对、有没有多空格。
- `400` / 地址错误 → 坐标格式或 Market 问题。

（也可以用 curl 测，`ANON_KEY` 是你项目的 anon public key：）
```bash
curl -i -X POST "https://<项目ref>.supabase.co/functions/v1/lalamove-quote" \
  -H "Authorization: Bearer <ANON_KEY>" -H "Content-Type: application/json" \
  -d '{"dropoff":{"lat":"2.2000","lng":"102.2500","address":"Test drop, Melaka"}}'
```

## 四、通了之后

告诉我函数测通了（能返回运费），我再把**小程序外卖流程**接上：
- 顾客选外卖 → 填/选收货地址 → 调这个函数 → 显示 Lalamove 运费。

之后再做「下单自动叫车」「追踪司机」（用同一个函数扩展 place-order / webhook）。
