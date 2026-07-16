-- ============================================================================
--  布丁喵 — 规格库加「必填 / 选填」
--  用法：Supabase Dashboard → SQL Editor → New query → 粘贴 → Run
--  给 spec_defs 加一个 required 布尔字段：true=必填（显示 *），false=选填（显示 (optional)）。
--  默认 true（必填），不影响已有规格。只加字段，不动任何数据。
-- ============================================================================

alter table public.spec_defs
  add column if not exists required boolean not null default true;

-- 完成。后台「规格管理」新增/编辑规格时可选必填/选填，POS 点单的规格页也会显示 * / (optional)。
