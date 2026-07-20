# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**布丁喵 PUDDING MEOW** is an ordering system for a dessert shop in Melaka, Malaysia. It consists of two standalone HTML files + one SQL setup script — no build system, no package manager, no framework.

| File | Audience | Device | Purpose |
|------|----------|--------|---------|
| `pudding-meow.html` | Customers | Mobile (390px) | Browse menu, build cart, place & track orders |
| `pos.html` | Staff | Desktop (1366×768) | Point of sale, payment, pending-payment queue, admin dashboard, menu management |
| `supabase-setup.sql` | one-time | — | Creates DB tables, RLS, realtime, seeds the menu |

Both apps are pure vanilla JS with inline `<style>`/`<script>`. They share a **Supabase** cloud backend (`orders` + `menu_items` tables + Realtime + a few Edge Functions) so a customer's phone and the shop's POS sync across devices. Payment is mode-based: **堂食 dine-in** is counter-only (TNG link or cash/DuitNow at counter, staff confirm in POS); **外卖 delivery / 自取 pickup** use **HitPay** (hosted checkout, online e-wallet/DuitNow) so the order is prepaid before the kitchen starts. If Supabase is unconfigured/unreachable, both apps fall back to a localStorage-only mode (single-device). See `DEPLOY.md` to go live.

## Mini-program: `pudding-meow.html`

Mobile-first, capped at a 390px `.phone` container. Four screens are all in the DOM at once and toggled by `switchTab()` (adds/removes `.active`); a fixed `.bottom-nav` switches between them.

| Screen | `id` | Notes |
|--------|------|-------|
| 首页 Home | `screen-home` | Pixel-precise absolute-positioned canvas (`.hc-*` classes) — brand logo, welcome bar, dine-in/pickup/delivery mode cards |
| 点单 Menu | `screen-menu` | Category sidebar (`#catList`) + item list (`#itemList`) + product-detail sheet with flavor pills |
| 订单 Orders | `screen-orders` | Customer's own order history with status filters + order-detail sheet (status stepper) |
| 我的 Profile | `screen-profile` | Member registration, 联系店长 (WhatsApp), store hours & address |

### Menu data
`const menu` (near the bottom of the script) is a hardcoded object of 6 categories — `special, classic, toast, boat, ice, drinks` — each `{cn, en, items:[{name, en, price, desc, flavors[]}]}`.

### Cart
`let cart = {}` keyed by `"cat|idx|flavorIdx"` → `{name, en, price, flavor, qty}`. In-memory only, lost on refresh. After any change call `renderItems()` + `updateCartBadge()`.

### Checkout — `openCheckout()` / `confirmOrder()`
Cart → **确认订单** full-screen checkout page (`renderCheckout()`), which shows the delivery-address block only in delivery mode, and shows a **mode-gated payment method list** (`_ckSyncPayRows()`): 堂食 shows counter-only; 外卖/自取 show HitPay-only (`ckPayHitpay` row, `selectedPay='hitpay'`). `ckPayNow()` closes the checkout page and calls `confirmOrder()`, which builds an order object, `unshift`es it into `_orders`, persists to `localStorage['pm_orders']`, then calls `pmBroadcastOrders()` (see Integration). Payment branches on `selectedPay`:
- `tng` → opens the Touch'n Go payment link, order `status:'preparing'` (prepaid).
- `counter` → order `status:'pending'` (unpaid; staff collect at counter).
- `hitpay` → order is inserted as `status:'pending'` first, then calls the `hitpay-checkout` Edge Function for a hosted-checkout URL and redirects the page there via `_pmGotoPay()` (a thin wrapper around `location.href =` kept separate so tests can intercept it without a real navigation). See "Delivery + online payment" below for the full flow.

### Delivery mode — address book + Lalamove quote
Picking 外卖 opens the address-book modal (`openDelivery()` / `dvModal`) — member addresses load via `rpc_list_my_addresses`; guests get a one-off form (`addrFormScreen`, not persisted). Selecting/saving an address fetches a delivery quote from the `lalamove-quote` Edge Function and stores it in `_deliveryInfo` (`address, lat, lng, fee, quotationId, recipientName, phone, addressId`). From the checkout page, the pencil icon (`ckEditAddr()`) reopens the address modal **as an overlay on top of the checkout page** (`_dvFromCheckout` flag) instead of navigating away; confirming refreshes the address + fee in place.

**Delivery-fee buffer** — the fee shown to and charged to the customer is the raw Lalamove quote × `DELIVERY_FEE_MULTIPLIER` (default `1.2`, via `_dvCustomerFee()`). The 20% markup is a cushion: when staff later dispatch a rider from POS, Lalamove is re-quoted at the then-current (possibly higher) price, and the buffer means the shop rarely eats the difference. The buffer is applied **only on the customer side** — the POS dispatch flow shows the raw (un-buffered) Lalamove price as the shop's real cost.

**Order → delivery persistence** — a delivery order's `confirmOrder()` also builds `order.deliveryInfo` (`address, lat, lng, recipientName, phone, remarks, fee, quotationId`) which `orderToRow` writes to the `orders.delivery_info` jsonb column (added by `supabase-orders-delivery.sql`). This is what lets the POS on another device read the dropoff coords + phone needed to dispatch a rider — the older per-field `deliveryAddress`/`deliveryCoords`/etc. are localStorage-only receipt fallbacks and do **not** cross devices.

## POS: `pos.html`

Fixed 1366×768 layout. PIN-gated (`localStorage['pm_pin']`, default `'0000'`). Two top-level views toggled by display:
- **`#posView`** — cart panel, T/A (dine-in/takeaway) toggle, menu grid, action bar, Cash + DuitNow numpad, **Pending Payment** modal (`showPending()`), change & print-ask overlays. `showPending()` labels `payMethod==='hitpay'` rows "在线支付" and hides the manual **已付款** button for them (they show "等待线上支付确认…" instead) — those orders should self-confirm via the `hitpay-webhook` Edge Function, so a staff member manually confirming one that the customer abandoned mid-payment would falsely mark it paid.
- **`#adminView`** — dashboard KPIs + transaction table (`renderDash`), members grid (`renderMembers`), monthly reports (`renderReports`).
- **外卖配送 modal** (`showDelivery()` / `dlvBg`, blue header button with a待叫车 count `updDlv()`) — lists paid, active delivery orders (`deliveryInfo` present). Each shows recipient/phone/address/customer-paid fee + a **叫车 Lalamove** button. `dispatchLalamove(id)` first calls `lalamove-quote` for a fresh price and `confirm()`s "现在叫车运费 vs 顾客已付" (so staff never silently overpay), then calls `lalamove-order` to actually book the rider, writing the result (`orderId, status, shareLink, price`) back to `deliveryInfo.lalamove` (DB + broadcast). Already-dispatched orders show the tracking link and can't be re-dispatched.

Helpers: `sg/ss` (string get/set), `gj/sj` (JSON get/set) wrap `localStorage`. `showN(msg)` shows a transient toast.

## Backend: Supabase (cloud, cross-device)

Both files load `@supabase/supabase-js@2` from CDN and share **one config block** (`SUPABASE_URL` + `SUPABASE_KEY`, near the top of each `<script>` — **must be identical in both files**). `var db = window.supabase && configured ? createClient(...) : null`. When `db` is null (creds not filled, offline, or CDN blocked) both apps **degrade gracefully** to the local/offline path below.

`supabase-setup.sql` (run once in the Supabase SQL Editor) creates the schema, RLS, realtime, and seeds the menu:

| Table | Columns | Purpose |
|-------|---------|---------|
| `orders` | `id, order_num, created_at, items(jsonb), total, pay_method, status, source, table_name, ta_mode, member_id, device_id, receipt_no, delivery_info(jsonb)` | all customer + counter orders (`delivery_info` holds the dropoff address/coords/phone + Lalamove dispatch result for 外卖 orders) |
| `menu_items` | `id, cat, name, en, price, descr, flavors(jsonb), sold_out, sort_order` | the editable menu |

Field mapping between the JS order object (camelCase) and DB rows (snake_case) is done by **`orderToRow()` / `rowToOrder()`** — defined identically in both files. `orderToRow` only emits real columns, so POS-only fields (`tender`, `change`, `customerName`) are dropped on insert.

**Menu** — the customer app (`loadMenu` → `buildMenuFromRows`) and the POS cashier grid (`loadMenu` → `buildPosMenuFromRows`) both read `menu_items`, so the POS admin **菜单管理** page (`renderMenuAdmin` + `menuAdd/menuEdit/menuToggleSold/menuDel`) is the single source of truth. `sold_out` items are hidden from customers ("下架"). The hardcoded `MENU_FALLBACK` / `MENU_FALLBACK`-style objects remain as offline fallback and seed reference. Category display names are a small hardcoded map (`CAT_META` / `POS_CATN`); only items are cloud-editable.

**Orders realtime** — both apps `subscribeOrders()` via `db.channel(...).on('postgres_changes', {table:'orders'})`. App `confirmOrder()` and POS order-save `insert`; POS `markPaid()` `update`s status. A customer counter order INSERTs → POS `loadOrdersFromCloud(true)` refreshes the 待付款 queue and toasts `🔔 新线上订单`. POS `markPaid` on an app order sets it to `preparing` → the customer's order flips to 制作中 live. The `hitpay-webhook` Edge Function does the same DB `update` as `markPaid` (pending → preparing) when a HitPay payment completes, so the customer's order flips live the same way without staff involvement.

### Edge Functions (`supabase/functions/`)
Server-side code that holds secrets the front-end must never see (browser source is public). Deployed to Supabase, called from the apps via `db.functions.invoke(name, {body})`. Both return HTTP 200 with `{ok:false, error}` on failure rather than a non-2xx status — `functions.invoke` swallows the response body on non-2xx, which used to hide the real error from the front end.

| Function | Called from | Purpose | Secrets (Edge Functions → Secrets) |
|----------|-------------|---------|-------------------------------------|
| `lalamove-quote` | app (delivery mode) + POS (`dispatchLalamove` re-quote) | Signs + calls Lalamove `/v3/quotations` for a delivery-fee quote to a given address; normalizes/clamps lat-lng decimals (Lalamove's regex rejects full browser-geolocation precision) and auto-swaps obviously-flipped lat/lng | `LALAMOVE_KEY`, `LALAMOVE_SECRET`; optional `LALAMOVE_MARKET`, `LALAMOVE_HOST`, `STORE_LAT`, `STORE_LNG`, `STORE_ADDRESS` |
| `lalamove-order` | POS, `dispatchLalamove()` | Books a Lalamove rider: re-quotes (`/v3/quotations`, since the checkout quote has expired) then `POST /v3/orders`; returns `lalamoveOrderId, status, shareLink, price`. Normalizes MY phones to E.164 (`0xx`→`+60xx`) | `LALAMOVE_KEY`, `LALAMOVE_SECRET`, `STORE_PHONE` (sender phone, required); optional `STORE_NAME` + same store-coord vars as `lalamove-quote` |
| `hitpay-checkout` | app, `confirmOrder()` when `selectedPay==='hitpay'` | Creates a HitPay Payment Request (`POST /v1/payment-requests`), returns the hosted checkout `url` the app redirects to | `HITPAY_API_KEY`; optional `HITPAY_HOST` (defaults to the sandbox host — switch to the live host when going live) |
| `hitpay-webhook` | HitPay's servers (not the app) | Receives the payment-result callback, verifies the HMAC signature, and on `status==='completed'` flips the matching order from `pending` → `preparing` and settles member XP/coin via `rpc_on_order_completed` (only if the row was still `pending`, so retried webhook calls can't double-credit) | `HITPAY_SALT` (the webhook signing salt from the same API Keys page, *not* the API key); `SUPABASE_URL` / `SUPABASE_SERVICE_ROLE_KEY` are auto-injected by Supabase, no need to set them |

`hitpay-checkout` fills in the `webhook` field itself (built from the auto-injected `SUPABASE_URL`), so HitPay's dashboard doesn't need a webhook URL configured manually. Use HitPay's **sandbox** key/salt while testing — sandbox payments don't move real money — and swap to live credentials only when actually launching.

## Order `status` vocabulary (shared)

`pending` (unpaid) → `paid`/`preparing` (paid, being made) → `ready` → `done`. The POS pending-payment queue filters strictly on `status === 'pending'`. The app's `STATUS` map treats `paid` as an alias of `preparing` (制作中). `source` is `'app'` or `'pos'`; app orders set `tableName` to `📱线上·{堂食|自取|外卖}`. Prepaid **TNG** orders are `preparing` (not `pending`), so they're intentionally excluded from the pending queue. **HitPay** orders, unlike TNG, *do* start as `pending` (the order is inserted before the customer has actually paid on HitPay's hosted page) and only flip to `preparing` once the `hitpay-webhook` Edge Function confirms payment — so they briefly appear in the POS pending queue, but tagged "在线支付" with no manual confirm button (see POS section). Known MVP limitation: the app's 订单 tab shows all recent orders (no per-customer identity yet).

## Offline / local fallback layer (localStorage)

When `db` is null, or as a same-device backup, the apps still use `localStorage['pm_orders']` + a live-notify layer that predates the cloud:
- **`pmBroadcastOrders()`** posts on `BroadcastChannel('pm_orders_sync')`; each app also listens to the `window 'storage'` event. This only bridges **tabs of the same browser/origin** — it does NOT cross devices (that's what Supabase is for).
- Other localStorage keys: `pm_members` (POS members), `pm_pin` (staff PIN), `pm_ctr`/`pm_rm` (counter/reports), `pm_menu_cache` (last-fetched menu, for offline).

## Rendering Pattern

Both apps use full `innerHTML` re-renders of DOM subtrees — no virtual DOM, no reactive state. State lives in module-level `var`/`let` globals; re-render functions read those globals and rebuild the relevant subtree.

## Design System

CSS variables in `:root` (identical in both files):

```css
--cream:#FFFDD6;  --bg:rgba(255,255,213,.835);  --blue:#B6F3FF;
--red:#8D0505;    --yellow:#FFDE5B;  --cream2:#FFFFD5;  --muted:#4A4848;
```

Cream/yellow background, deep-red (`--red`) text and accents, blue (`--blue`) for active/selected states. Fonts (Google Fonts): **Pattaya** for the brand wordmark, **Noto Sans SC** for everything else. The design mirrors a Figma file (mobile screens + POS); when adjusting layout, match the pixel values already encoded in the `.hc-*` / absolute-positioned rules.

## Print / Receipt

Both apps print an 80mm receipt. The mini-program renders into `#pmPrintArea` and the POS into its receipt builder (`printRec`); an `@media print` block hides everything except the receipt node, then `window.print()` is called.

## Development

No build step. Edit the HTML file and refresh the browser.

**Cloud config:** put the same `SUPABASE_URL` + `SUPABASE_KEY` in both `pudding-meow.html` and `pos.html`, and run `supabase-setup.sql` once in the Supabase SQL Editor. See `DEPLOY.md` for the full launch guide (hosting + table QR).

**Local testing:** with real cloud, cross-device sync works over the internet — open the two files on two different devices. Without cloud (or to test the offline path), serve both from one origin so the localStorage/`BroadcastChannel` fallback bridges two tabs:

```bash
python3 -m http.server 8000
# http://127.0.0.1:8000/pudding-meow.html  (phone view: DevTools device toolbar)
# http://127.0.0.1:8000/pos.html           (another tab)
```

**Automated checks** (this repo's dev container blocks Supabase, so cloud round-trips can't run here): `node --check` the extracted `<script>` blocks for syntax; the Playwright scripts in scratchpad cover (a) graceful degradation when `db` is null and (b) cloud code paths via a mock `window.supabase` (verifying table names + `orderToRow` snake_case mapping + realtime wiring). Real end-to-end cloud verification happens in a normal browser.
