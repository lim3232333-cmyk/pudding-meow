-- ============================================================================
--  布丁喵 — 销售渠道加营业时间（像 Grab：每天分开设，想关就关）
--  用法：Supabase Dashboard → SQL Editor → New query → 粘贴 → Run（跑一次）
--
--  给 sales_channels 加两列：
--    hours_enabled  是否按营业时间自动开关（false = 不限时间，只看「启用」总开关）
--    hours          每天营业时段，jsonb 数组，7 个元素，下标 0=周日 … 6=周六，
--                   每个元素形如 {"closed":false,"open":"16:00","close":"23:00"}
--                   closed=true 表示当天休息。
--
--  顾客端（小程序）会读这两列 + enabled：外卖/自取过了营业时间或手动暂停，
--  点进去只显示营业时间、不给下单；下单页的时段也只显示营业时段内的。
--  「启用(enabled)」= 总开关/手动暂停（想临时关就取消勾选）。
-- ============================================================================

alter table public.sales_channels
  add column if not exists hours_enabled boolean not null default false,
  add column if not exists hours jsonb;

-- 完成。回 POS「菜单管理 → 销售方式」，编辑外卖/自取，勾「按营业时间自动开关」并设每天时段。
