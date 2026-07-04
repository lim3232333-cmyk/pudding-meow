# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**布丁喵 PUDDING MEOW** is an ordering system for a dessert shop in Melaka, Malaysia. It consists of two standalone HTML files — no build system, no package manager, no framework. Open either file directly in a browser to run it.

| File | Audience | Device | Purpose |
|------|----------|--------|---------|
| `pudding-meow.html` | Customers | Mobile (390px) | Browse menu, build cart, place & track orders |
| `pos.html` | Staff | Desktop (1366×768) | Point of sale, payment, pending-payment queue, admin dashboard |

Both apps are pure vanilla JS with inline `<style>`/`<script>` and share data through the browser's `localStorage`. There is **no backend** in the current version — everything runs client-side. (An earlier iteration used Supabase + Stripe; that has been replaced by the standalone localStorage design.)

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

## Shared data (localStorage keys)

| Key | Written by | Shape |
|-----|-----------|-------|
| `pm_orders` | both apps | `[{ id, orderNum, createdAt, items:[{name, qty, price, ...}], total, payMethod, status, source, tableName, taMode }]` |
| `pm_members` | POS | member records |
| `pm_pin` | POS | staff PIN |
| `pm_ctr`, `pm_rm` | POS | order counter / reports config |

**Order `status` vocabulary** (shared, must stay compatible across both apps):
`pending` (unpaid) → `paid`/`preparing` (paid, being made) → `ready` → `done`. The POS pending-payment queue filters strictly on `status === 'pending'`. The app's `STATUS` map treats `paid` as an alias of `preparing` (制作中) so POS-side payment reflects sensibly in the customer view.

`source` is `'app'` (from mini-program) or `'pos'` (created at the counter). App orders set `tableName` to `📱线上·{堂食|自取|外卖}` so they're distinguishable in the POS queue and transaction table.

## Integration: app ↔ POS real-time sync

The two apps are "connected" purely through `localStorage['pm_orders']` plus a live-notify layer. **Same origin is required** — serve both files from the same host/port (see Development) for cross-tab events to fire.

The sync layer is symmetric and lives near the bottom of each script:
- **`pmBroadcastOrders()`** — after any write to `pm_orders`, posts a message on `BroadcastChannel('pm_orders_sync')`.
- **Listeners** — each app subscribes to both the `BroadcastChannel` *and* the `window 'storage'` event (fires in other tabs of the same origin). On either signal it reloads `pm_orders` and re-renders.
  - POS: `pmRefreshOrders(true)` → refreshes the pending badge/list + admin dashboard, and toasts `🔔 新线上订单 #NNNN` for genuinely new `source:'app'` `pending` orders.
  - App: `pmOnOrdersChanged()` → `mergeOrdersFromStorage()` then re-renders the orders list and any open order-detail sheet (so a POS "已付款" flips the customer's order to 制作中 live).

Net effect: a customer placing a **counter** order instantly appears in the POS **待付款** queue; when staff tap 已付款 the customer's app updates in real time. Prepaid **TNG** orders are intentionally excluded from the pending queue.

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

**To exercise the app ↔ POS integration you must use a server (not `file://`)** so both pages share an origin and `storage`/`BroadcastChannel` events fire:

```bash
python3 -m http.server 8000
# open http://127.0.0.1:8000/pudding-meow.html  (phone view: DevTools device toolbar)
# open http://127.0.0.1:8000/pos.html           (in another tab)
```

Place a counter order in the mini-program and watch the POS pending-payment badge/list update live.
