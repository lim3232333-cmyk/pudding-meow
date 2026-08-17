-- ============================================================================
--  布丁喵 — 积分商城分区改成店家自己维护（不再写死在代码里）
--  用法：Supabase Dashboard → SQL Editor → New query → 整段粘贴 → Run。
--        跑一次就好，可以重复跑（幂等）。
--  前置：supabase-coupon-mall-category.sql 已跑过（它给 coupons 加了 mall_category）。
--
--  原来商城首页那四段（限定 / 现金回扣·折扣 / 免邮 / 合作）是写死在两个前端里的，
--  店家想加一段「中秋限定」就得找人改代码。改成跟 menu_categories、sales_channels
--  一样的做法：分区本身也是一张表，POS 上增删改排序。
--
--  ⚠ code 建好之后不给改：coupons.mall_category 存的就是这个 code，改了等于把
--    已经归好类的券全部打散。名字（name）随便改，那只是显示。
--
--  ⚠ 「其他好礼」不在这张表里，它是前端凭空多出来的一段，专门收留没分区的券。
--    做成一行的话，店家一删它，那些券就从商城上消失了——那不是删一个分类该有的后果。
-- ============================================================================

create table if not exists public.mall_categories (
  id         uuid primary key default gen_random_uuid(),
  code       text not null unique,          -- coupons.mall_category 存的就是它，建后不改
  name       text not null,                 -- 显示用，随时可改
  sort_order int  not null default 0,       -- 商城首页从上到下的顺序
  enabled    boolean not null default true, -- 关掉 = 商城不显示这一段，但券的归属还在
  created_at timestamptz not null default now()
);
create index if not exists mall_categories_sort_idx on public.mall_categories (sort_order);

alter table public.mall_categories enable row level security;
drop policy if exists mall_categories_anon_read on public.mall_categories;
create policy mall_categories_anon_read on public.mall_categories for select to anon using (true);
drop policy if exists mall_categories_anon_write on public.mall_categories;
create policy mall_categories_anon_write on public.mall_categories for all to anon using (true) with check (true);

--  把原来写死的四段灌进去，这样跑完脚本商城长得跟之前一模一样，
--  已经归好类的券也不会掉出来（它们存的就是这四个 code）。
--  on conflict do nothing：重复跑不会覆盖你后来改过的名字和顺序。
insert into public.mall_categories (code, name, sort_order) values
  ('limited',   '限定',          10),
  ('cashback',  '现金回扣/折扣', 20),
  ('free_ship', '免邮',          30),
  ('partner',   '合作',          40)
on conflict (code) do nothing;

--  对账：看看现在有哪些分区、各自挂了几张券
select mc.sort_order as 排序, mc.code, mc.name as 名称, mc.enabled as 启用,
       (select count(*) from public.coupons c where c.mall_category = mc.code) as 挂了几张券
  from public.mall_categories mc
 order by mc.sort_order, mc.name;
