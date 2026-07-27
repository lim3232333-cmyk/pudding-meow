-- ============================================================================
--  布丁喵 — 补齐 member_levels 缺失的列
--  用法：Supabase Dashboard → SQL Editor → New query → 粘贴 → Run（跑一次）
--
--  症状：POS 收银台输电话查会员，报 column l.color_hex does not exist（42703）。
--  原因：线上这张 member_levels 少了几列。supabase-membership.sql 建表时是带
--        color_hex 的，但那份脚本开头有 drop table ... cascade，多半是当初分批跑、
--        或者表是用别的路径建起来的，没走到完整定义。
--
--  受影响的不只是收银台查会员——代码里读写 color_hex 的地方还有：
--    · 小程序「会员明细」等级表的底色（renderMemberDetail）
--    · POS 会员列表里等级那一列的颜色
--    · POS 会员等级编辑页保存时会写 color_hex（缺列的话保存直接失败）
--
--  下面全部是 add column if not exists，已经有的列不会动，重复跑也安全。
--  这里一次把代码依赖的列都补上，省得修好一个又撞下一个。
-- ============================================================================

alter table public.member_levels
  add column if not exists name_en        text,
  add column if not exists color_hex      text not null default '#8D0505',
  add column if not exists badge_icon     text,
  add column if not exists perks          jsonb not null default '[]'::jsonb,
  -- 小程序「会员明细」那张表的 4 列权益（supabase-level-perks.sql 也建这几列）
  add column if not exists perk_birthday  text,
  add column if not exists perk_coin_rate text,
  add column if not exists perk_draw      text,
  add column if not exists perk_memberday text;

-- 补出来的 color_hex 全是同一个默认红，等级之间分不出来。
-- 按 sort_order 给一组默认配色，只填还是默认值的那些，后台改过的不覆盖。
update public.member_levels set color_hex = c.hex
  from (values (0,'#C9B29B'),(1,'#D99A5B'),(2,'#B8703A'),(3,'#6B4530'),(4,'#B8933F')) as c(so,hex)
 where member_levels.sort_order = c.so
   and coalesce(member_levels.color_hex,'') in ('', '#8D0505');

-- PostgREST 缓存了一份表结构，加完列通知它重新加载
select pg_notify('pgrst', 'reload schema');

-- 跑完自查：这几列应该都在
select column_name, data_type
  from information_schema.columns
 where table_schema = 'public' and table_name = 'member_levels'
 order by ordinal_position;
