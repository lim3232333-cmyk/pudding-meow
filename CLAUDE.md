# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**布丁喵 PUDDING MEOW** is a mobile-first ordering web app for a dessert shop in Melaka, Malaysia. The entire application lives in a single file: `pudding-meow.html`. There is no build system, no package manager, and no framework — open the file directly in a browser to run it.

## Architecture

The app is a single-page application structured as one HTML file with three sections:

1. **CSS** (lines 1–535) — All styling as inline `<style>`. Uses CSS custom properties defined in `:root` for the entire design system (colors, spacing). Mobile-first, capped at `max-width: 480px`.

2. **HTML** (lines 1–535 interleaved with CSS, then markup through ~535) — Four tab pages rendered simultaneously as `.page` divs, toggled via `display:none/flex`. Drawers and modals are also in the DOM at all times.

3. **JavaScript** (lines 536–1041) — Vanilla JS, no modules. All logic is in a single `<script>` block with global state variables and functions.

### Tab pages
| Tab | `id` | Purpose |
|-----|------|---------|
| 首页 Home | `page-home` | Featured items, quick actions |
| 点单 Order | `page-order` | Category sidebar + scrollable menu |
| 订单 Orders | `page-orders` | Real-time order list for staff |
| 我的 Profile | `page-mine` | Member card, store info |

### Backend: Supabase
Connected via the CDN-loaded `@supabase/supabase-js@2` library. The client is initialized at the top of the script with hardcoded public anon credentials:

```js
const SUPABASE_URL = 'https://vmdjsvapikfgcbthnapw.supabase.co';
const SUPABASE_KEY = '...'; // anon/public key
const db = createClient(SUPABASE_URL, SUPABASE_KEY);
```

**Tables:**
- `menu_items` — product catalog: `id, name, description, price, emoji, cat, tag, bg, stripe_link, sold_out, sort_order`
- `orders` — customer orders: `id, type, items (JSONB array), total, status, note, created_at`

Real-time new-order notifications use Supabase Realtime (`db.channel(...).on('postgres_changes', ...)`).

### Payment: Stripe Payment Links
Each `menu_item` has an optional `stripe_link` field pointing to a pre-created Stripe Payment Link. On checkout, the app saves the order to Supabase and then redirects (`window.open`) to the first cart item's Stripe link. The link is configured per-item via the admin drawer (⚙️ gear icon on the order page).

## Key State Variables

```js
let menuItems = [];      // loaded from Supabase
let cart = [];           // [{id, qty}] — in-memory only, lost on refresh
let selectedPay = 'fpx'; // selected payment method display only
let currentOType = '自取'; // order type: 自取 | 堂食 | 外卖
let currentOrderTab = 'today'; // orders page: today | all
let currentFilter = '全部'; // order type filter
```

## Rendering Pattern

All UI updates are full re-renders of DOM subtrees via `innerHTML`. There is no virtual DOM or reactive state. After any cart change, call `updateCartBar()` and `renderMenu()` to keep the UI consistent. `renderFeatured()` should also be called when menu data changes.

## Offline Fallback

`loadMenu()` catches Supabase errors and falls back to `localStorage.getItem('pm_menu_cache')`. The cache is not explicitly written in the current code — if adding cache writes, use key `pm_menu_cache`.

## Admin Access

The ⚙️ admin drawer (opened from the order page topbar) lets staff add/edit/delete menu items and toggle `sold_out` status. All changes write directly to Supabase. No authentication is implemented — the admin UI is accessible to anyone who opens the page.

## Print / Receipt

`buildReceipt(order)` populates `#receipt-content` and `window.print()` is called with a 300ms delay. The print stylesheet is embedded in the CSS (look for `@media print`).

## Design System

Colors are defined as CSS variables in `:root`. The palette is pink-dominant (`--pink`, `--pink-deep`, `--pink-light`, `--pink-bg`) with mint and cream accents. Fonts (loaded from Google Fonts): Pacifico (headings/brand), Noto Sans SC (body), Noto Serif SC (Chinese brand name).

## Development

No build step. Edit `pudding-meow.html` and refresh the browser. To test Supabase integration, the existing Supabase project credentials are already in the file. To test orders and real-time, open the page in two browser tabs.
