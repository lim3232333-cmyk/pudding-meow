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

## 四、报价通了之后（已完成）

顾客选外卖 → 填/选收货地址 → 调 `lalamove-quote` → 结算页显示运费。
顾客看到的运费 = Lalamove 报价 **× 1.2**（多收 20% 做差价缓冲，见下）。

---

# 第二步：下单叫车（店员在 POS 点「叫车」）

## 五、再部署一个 Edge Function：`lalamove-order`

和第一步一样（Edge Functions → Deploy a new function → Via Editor）：
- 函数名：`lalamove-order`
- 代码：`supabase/functions/lalamove-order/index.ts` 全部粘进去 → Deploy

它做两件事：① 重新报一次价（顾客下单时那张几分钟就过期，不能复用）；
② 用新报价 `POST /v3/orders` 正式下单叫车，返回追踪链接。

## 六、加一个密钥：`STORE_PHONE`

Edge Functions → Secrets，加：

| 名称 | 值 | 说明 |
|------|-----|------|
| `STORE_PHONE` | 你店铺联系电话 | Lalamove 下单要发件人电话，必填。本地号如 `0123456789` 即可，函数会自动转成 +60 格式 |

`LALAMOVE_KEY` / `LALAMOVE_SECRET` 和第一步共用，不用重设。
可选：`STORE_NAME`（默认「布丁喵 Pudding Meow」）。

## 七、还要跑一次 SQL：外卖收货信息入库

Supabase → SQL Editor → New query → 把 `supabase-orders-delivery.sql` 全部粘进去 → Run。
（只给 orders 表加一列 `delivery_info`，存收货地址/坐标/电话，POS 才叫得了车。可安全重复执行。）

## 八、怎么用（店员）

POS 顶部新增蓝色「外卖配送」按钮（带待叫车数字）。点开：
1. 列出已付款的外卖单（收货人 / 电话 / 地址 / 顾客付的运费）。
2. 点「叫车 Lalamove」→ 先弹确认框：**现在叫车运费 RM X · 顾客已付 RM Y · 差价**。
   - 「现在叫车运费」是 Lalamove **真实价**（店里实付成本，不含缓冲）；
   - 「顾客已付」是下单时的 ×1.2 缓冲价。多数情况店里不倒贴、甚至小赚。
3. 确认 → 正式叫车，按钮变「已叫车 ✓」并显示追踪链接；已叫车的不会重复叫。

## 九、运费缓冲 ×1.2 想改

在 `pudding-meow.html` 里搜 `DELIVERY_FEE_MULTIPLIER`（默认 `1.2`）。
改成 `1.0` 就是照实收（不缓冲）、`1.3` 就是多收 30%，改完重新部署网站即可。

---

# 第三步：实时追踪（骑手状态自动更新）

分两层，都已做好，需要你部署 + 登记：

## 十、层一：追踪链接（已随叫车自动带上）

叫车成功后 Lalamove 返回的 `shareLink` 是**实时地图页**。顾客在小程序「订单 → 查看详情」
里会看到「📍 追踪骑手」按钮，点开就是骑手在地图上的实时位置。这层不用额外部署。

## 十一、层二：状态自动同步（部署 `lalamove-webhook`）

让「正在安排骑手 / 骑手前往取餐 / 已取餐·配送中 / 已送达」这些文字状态自动更新在
POS 外卖配送面板和顾客订单页上。

1. **部署函数**：Edge Functions → 新建 `lalamove-webhook`，粘 `supabase/functions/lalamove-webhook/index.ts`
   → Deploy。**Verify JWT 要关掉**（Lalamove 服务器调用，没有你的登录令牌）。

2. **在 Lalamove 开发者后台登记 webhook 地址**（就是你拿 API Key 那个后台）：
   找到 Webhook / Notifications 设置，填本函数的 URL：
   ```
   https://<你的项目ref>.supabase.co/functions/v1/lalamove-webhook
   ```
   Lalamove 是**账号级别设一次**（不像 HitPay 每单带）。之后所有订单的状态变化都会推过来。

> 安全说明：Lalamove v3 的 webhook 没有共享密钥签名，本函数靠「只更新数据库里已存在、
> 且 Lalamove orderId 完全匹配的订单」防滥用（orderId 不可猜）。状态只是展示、不涉及金额。

## 十二、状态含义

| Lalamove 状态 | 显示 |
|--------------|------|
| ASSIGNING_DRIVER | 正在安排骑手 |
| ON_GOING | 骑手前往取餐 |
| PICKED_UP | 已取餐 · 配送中 |
| COMPLETED | 已送达 |
| CANCELED / REJECTED / EXPIRED | 已取消 / 拒单 / 过期 |
