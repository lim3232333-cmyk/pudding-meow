-- ============================================================================
--  布丁喵 — 规格组加英文名（POS 面包屑用英文）
--  用法：Supabase Dashboard → SQL Editor → New query → 粘贴 → Run（跑一次）
--
--  给 spec_defs 加一列 name_en。POS item panel 的面包屑（分类 \ 子分类 \ 商品 \ 规格）
--  用英文显示规格组名；留空则退回中文 name。小程序商品详情页仍用中文 name 给顾客看。
--  例：规格组 name='温度'，name_en='Temperature' → POS 面包屑显示 Temperature。
-- ============================================================================

alter table public.spec_defs
  add column if not exists name_en text;

-- 完成。回 POS「菜单管理 → 规格」编辑规格组，填上 English 名（如 Temperature）即可。
