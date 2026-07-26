-- ============================================================================
--  布丁喵 — 等级权益拆成 4 个独立字段，让「会员明细」那张表由后台驱动
--  用法：Supabase Dashboard → SQL Editor → New query → 粘贴 → Run（跑一次）
--  前置：supabase-membership.sql 已跑过。
--
--  背景：小程序「会员明细」里那张表是固定 5 列
--        （等级/权益 | 生日 | Coin倍率 | 幸运抽奖 | 会员日），
--        原本整段写死在 HTML 里，POS 后台改等级完全不影响它。
--        而 member_levels 只有一个自由填写的 perks 字符串数组，撑不起这 4 列
--        （靠数组下标对号入座太脆：店员少填一项后面全错位）。
--        所以给这 4 列各建一个字段，POS 等级编辑页分别可填。
--
--  perks 保留不动：它仍是「其他权益」的自由列表，本次不使用、也不删。
-- ============================================================================

alter table public.member_levels
  add column if not exists perk_birthday   text,   -- 生日
  add column if not exists perk_coin_rate  text,   -- Coin 倍率
  add column if not exists perk_draw       text,   -- 幸运抽奖
  add column if not exists perk_memberday  text;   -- 会员日

-- 用原先写死在小程序里的那张表回填，保证上线后顾客看到的内容不变。
-- 只填还没填过的（coalesce 判空），重复跑本脚本不会覆盖后台已改过的值。
update public.member_levels set
  perk_birthday  = coalesce(perk_birthday , '100 Coin'),
  perk_coin_rate = coalesce(perk_coin_rate, '1x'),
  perk_draw      = coalesce(perk_draw     , '1次/月'),
  perk_memberday = coalesce(perk_memberday, '1.5x Coin')
where name_cn = '新生小猫';

update public.member_levels set
  perk_birthday  = coalesce(perk_birthday , '200 Coin'),
  perk_coin_rate = coalesce(perk_coin_rate, '1.2x'),
  perk_draw      = coalesce(perk_draw     , '2次/月'),
  perk_memberday = coalesce(perk_memberday, '1.5x Coin')
where name_cn = '幼猫';

update public.member_levels set
  perk_birthday  = coalesce(perk_birthday , '300 Coin'),
  perk_coin_rate = coalesce(perk_coin_rate, '1.5x'),
  perk_draw      = coalesce(perk_draw     , '3次/月'),
  perk_memberday = coalesce(perk_memberday, '2x Coin·抽奖1次')
where name_cn = '青年猫';

update public.member_levels set
  perk_birthday  = coalesce(perk_birthday , '500 Coin'),
  perk_coin_rate = coalesce(perk_coin_rate, '2x'),
  perk_draw      = coalesce(perk_draw     , '5次/月'),
  perk_memberday = coalesce(perk_memberday, '3x Coin·抽奖1次')
where name_cn in ('布丁喵','布丁猫');   -- 两种写法都可能存在

-- 完成。之后在 POS「忠诚度 → 等级管理」编辑等级，这 4 项会直接反映到
-- 小程序的会员明细表（member_levels 已在 realtime 发布里，改完立刻同步）。
