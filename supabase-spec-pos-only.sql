-- ============================================================================
--  布丁喵 — 规格选项「仅POS」隐藏
--  用法：Supabase Dashboard → SQL Editor → New query → 粘贴 → Run（跑一次即可）
--
--  给 spec_defs 加一列 pos_only_options：里面列出的选项只在 POS 收银台可选，
--  顾客小程序完全看不到（渲染规格时会把这些选项过滤掉）。
--  整组仅POS 则复用 channels = ['__pos_only__']（跟商品的隐藏菜单一套），不需要改表。
-- ============================================================================

alter table public.spec_defs
  add column if not exists pos_only_options jsonb not null default '[]'::jsonb;

-- 完成。POS「菜单管理 → 规格」里每个选项旁多了个 🔒 开关，勾了就只在 POS 卖。
