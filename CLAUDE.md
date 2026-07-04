# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**布丁喵 PUDDING MEOW** is an ordering system for a dessert shop in Melaka, Malaysia. It consists of two standalone HTML files + one SQL setup script — no build system, no package manager, no framework.

| File | Audience | Device | Purpose |
|------|----------|--------|---------|
| `pudding-meow.html` | Customers | Mobile (390px) | Browse menu, build cart, place & track orders |
| `pos.html` | Staff | Desktop (1366×768) | Point of sale, payment, pending-payment queue, admin dashboard, menu management |
| `supabase-setup.sql` | one-time | — | Creates DB tables, RLS, realtime, seeds the menu |

Both apps are pure vanilla JS with inline `<style>`/`<script>`. They share a **Supabase** cloud backend (`orders` + `menu_items` tables + Realtime) so a customer's phone and the shop's POS sync across devices. Payment is **TNG** (a fixed payment link) or **柜台/cash at counter** — no online card processor. If Supabase is unconfigured/unreachable, both apps fall back to a localStorage-only mode (single-device). See `DEPLOY.md` to go live.

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

### Checkout — `confirmOrder()`
Builds an order object, `unshift`es it into `_orders`, persists to `localStorage['pm_orders']`, then calls `pmBroadcastOrders()` (see Integration). Payment branches on `selectedPay`:
- `tng` → opens the Touch'n Go payment link, order `status:'preparing'` (prepaid).
- `counter` → order `status:'pending'` (unpaid; staff collect at counter).

## POS: `pos.html`

Fixed 1366×768 layout. PIN-gated (`localStorage['pm_pin']`, default `'0000'`). Two top-level views toggled by display:
- **`#posView`** — cart panel, T/A (dine-in/takeaway) toggle, menu grid, action bar, Cash + DuitNow numpad, **Pending Payment** modal (`showPending()`), change & print-ask overlays.
- **`#adminView`** — dashboard KPIs + transaction table (`renderDash`), members grid (`renderMembers`), monthly reports (`renderReports`).

Helpers: `sg/ss` (string get/set), `gj/sj` (JSON get/set) wrap `localStorage`. `showN(msg)` shows a transient toast.

## Backend: Supabase (cloud, cross-device)

Both files load `@supabase/supabase-js@2` from CDN and share **one config block** (`SUPABASE_URL` + `SUPABASE_KEY`, near the top of each `<script>` — **must be identical in both files**). `var db = window.supabase && configured ? createClient(...) : null`. When `db` is null (creds not filled, offline, or CDN blocked) both apps **degrade gracefully** to the local/offline path below.

`supabase-setup.sql` (run once in the Supabase SQL Editor) creates the schema, RLS, realtime, and seeds the menu:

| Table | Columns | Purpose |
|-------|---------|---------|
| `orders` | `id, order_num, created_at, items(jsonb), total, pay_method, status, source, table_name, ta_mode` | all customer + counter orders |
| `menu_items` | `id, cat, name, en, price, descr, flavors(jsonb), sold_out, sort_order` | the editable menu |

Field mapping between the JS order object (camelCase) and DB rows (snake_case) is done by **`orderToRow()` / `rowToOrder()`** — defined identically in both files. `orderToRow` only emits real columns, so POS-only fields (`tender`, `change`, `customerName`) are dropped on insert.

**Menu** — the customer app (`loadMenu` → `buildMenuFromRows`) and the POS cashier grid (`loadMenu` → `buildPosMenuFromRows`) both read `menu_items`, so the POS admin **菜单管理** page (`renderMenuAdmin` + `menuAdd/menuEdit/menuToggleSold/menuDel`) is the single source of truth. `sold_out` items are hidden from customers ("下架"). The hardcoded `MENU_FALLBACK` / `MENU_FALLBACK`-style objects remain as offline fallback and seed reference. Category display names are a small hardcoded map (`CAT_META` / `POS_CATN`); only items are cloud-editable.

**Orders realtime** — both apps `subscribeOrders()` via `db.channel(...).on('postgres_changes', {table:'orders'})`. App `confirmOrder()` and POS order-save `insert`; POS `markPaid()` `update`s status. A customer counter order INSERTs → POS `loadOrdersFromCloud(true)` refreshes the 待付款 queue and toasts `🔔 新线上订单`. POS `markPaid` on an app order sets it to `preparing` → the customer's order flips to 制作中 live.

## Order `status` vocabulary (shared)

`pending` (unpaid) → `paid`/`preparing` (paid, being made) → `ready` → `done`. The POS pending-payment queue filters strictly on `status === 'pending'`. The app's `STATUS` map treats `paid` as an alias of `preparing` (制作中). `source` is `'app'` or `'pos'`; app orders set `tableName` to `📱线上·{堂食|自取|外卖}`. Prepaid **TNG** orders are `preparing` (not `pending`), so they're intentionally excluded from the pending queue. Known MVP limitation: the app's 订单 tab shows all recent orders (no per-customer identity yet).

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
