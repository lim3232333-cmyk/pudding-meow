-- ============================================================================
--  布丁喵 — 母分类 / 子分类「仅POS」隐藏
--  用法：Supabase Dashboard → SQL Editor → New query → 粘贴 → Run（跑一次）
--
--  给 menu_categories 加一列 pos_only：勾了的（母或子）分类只在 POS 收银台出现，
--  顾客小程序完全看不到——连它下面的所有商品也一并从小程序过滤掉（子分类的商品
--  不会掉回顶级散装显示）。POS 照常显示，跟商品/规格的「仅POS」一套逻辑。
--
--  跟「停用(enabled=false)」不同：停用是两边都藏；仅POS 是只藏小程序、POS 还能卖。
-- ============================================================================

alter table public.menu_categories
  add column if not exists pos_only boolean not null default false;

-- 完成。POS「菜单管理 → 商品管理」里新增/编辑分类时多了个 🔒 仅POS 开关。
