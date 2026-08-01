-- ============================================================================
--  布丁喵 — 营业日（跨午夜的单算前一天）
--  用法：Supabase Dashboard → SQL Editor → New query → 粘贴 → Run（跑一次）
--
--  店里有时做过午夜。凌晨 1 点那几单要跟当晚其它单算在同一天，
--  因为收档时是一次性对现金和 DuitNow 的——按自然日切的话，
--  这几单会被丢到"明天"，那晚的现金怎么点都对不上。
--
--  做法：营业日 = (下单时间 − 切点小时) 那天。切点默认凌晨 4 点：
--    · 8 月 1 日 01:30 − 4h = 7 月 31 日 21:30 → 算 7 月 31 日 ✅
--    · 8 月 1 日 09:00 − 4h = 8 月 1 日 05:00  → 算 8 月 1 日 ✅
--  4 点这个数足够晚（晚市收档一般到 1~2 点），又足够早（不会把第二天
--  真正的早班算进前一天）。要改在 shop_settings 里改。
--
--  关键：营业日在下单那一刻就算好、写进 orders.business_date，之后不再回算。
--  以后把切点从 4 点改成 3 点，只影响之后的单——已经出过的日结报表不会
--  被追溯改写。对账这件事上，昨天的数字今天不该变。
-- ============================================================================

-- ---------------------------------------------------------------------------
--  1) 店铺设置（单行表，以后店名/营业时间/税率也能往里放）
-- ---------------------------------------------------------------------------
create table if not exists public.shop_settings (
  id              int primary key default 1,
  day_cutoff_hour int  not null default 4,                      -- 营业日切点：0~23
  tz              text not null default 'Asia/Kuala_Lumpur',
  updated_at      timestamptz not null default now(),
  constraint shop_settings_single_row check (id = 1),
  constraint shop_settings_cutoff_range check (day_cutoff_hour between 0 and 23)
);
insert into public.shop_settings (id) values (1) on conflict (id) do nothing;

alter table public.shop_settings enable row level security;
drop policy if exists shop_settings_anon_read on public.shop_settings;
create policy shop_settings_anon_read on public.shop_settings for select to anon using (true);
drop policy if exists shop_settings_anon_write on public.shop_settings;
create policy shop_settings_anon_write on public.shop_settings for all to anon using (true) with check (true);

do $$
begin
  alter publication supabase_realtime add table public.shop_settings;
exception when duplicate_object then null;
end $$;

-- ---------------------------------------------------------------------------
--  2) 算营业日。先换算到本地时区再减切点——直接对 UTC 减会差 8 小时，
--     马来西亚早上 8 点前的单会整批算错天（月报那个老 bug 就是这么来的）。
-- ---------------------------------------------------------------------------
create or replace function public.biz_date(p_ts timestamptz)
returns date
language sql
stable
set search_path = public
as $$
  select ((p_ts at time zone coalesce((select s.tz from public.shop_settings s where s.id = 1), 'Asia/Kuala_Lumpur'))
          - make_interval(hours => coalesce((select s.day_cutoff_hour from public.shop_settings s where s.id = 1), 4)))::date;
$$;
grant execute on function public.biz_date(timestamptz) to anon, authenticated;

-- ---------------------------------------------------------------------------
--  3) orders 加一列存营业日 + 触发器自动填
--     用触发器而不是让前端算：下单的路径有三条（收银台、小程序、
--     HitPay webhook），漏掉任何一条就会出现 business_date 为空的孤儿单。
-- ---------------------------------------------------------------------------
alter table public.orders add column if not exists business_date date;
create index if not exists orders_business_date_idx on public.orders (business_date);

create or replace function public._orders_set_biz_date()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.business_date is null then
    new.business_date := public.biz_date(coalesce(new.created_at, now()));
  end if;
  return new;
end;
$$;
drop trigger if exists orders_biz_date on public.orders;
create trigger orders_biz_date before insert on public.orders
  for each row execute function public._orders_set_biz_date();

-- 历史单回填。注意这是按"现在"的切点回算的，跑完之后凌晨的老单会从
-- 原来那天挪到前一天，两天的营业额都会变一次——这是预期的，不是算错了。
update public.orders set business_date = public.biz_date(created_at) where business_date is null;

-- ---------------------------------------------------------------------------
--  4) 订单号也按营业日重置
--     不改的话，跨午夜那一刻号会从 0001 重来，同一晚出现两个 #0001，
--     收档对账时分不清哪张是哪张。
--
--     线上这个函数的签名是 supabase-order-code-per-type.sql 换过的
--     rpc_next_order_num(p_kind text default null)，不是最早那个无参版。
--     必须先把两个签名都 drop 掉再建：create or replace 碰到不同签名会变成
--     重载，两个同名函数并存时不带参数的调用会 ambiguous，下单直接取不到号。
--     （这一段我第一次就是这么写错的，本地跑出来 "function is not unique"。）
--     只跑过最早那版 order-numbers.sql 的店也能用：带默认值的参数版对
--     rpc('rpc_next_order_num') 这种无参调用照样匹配。
-- ---------------------------------------------------------------------------
alter table public.order_counters
  add column if not exists ta_seq int not null default 0,
  add column if not exists dl_seq int not null default 0;

drop function if exists public.rpc_next_order_num();
drop function if exists public.rpc_next_order_num(text);

create or replace function public.rpc_next_order_num(p_kind text default null)
returns table(receipt_no bigint, order_no int, kind_seq int)
language plpgsql
security definer
set search_path = public
as $$
declare
  d       date := public.biz_date(now());      -- 这里是唯一的改动：自然日 → 营业日
  inc_ta  int  := case when p_kind = 'takeaway' then 1 else 0 end;
  inc_dl  int  := case when p_kind = 'delivery' then 1 else 0 end;
begin
  return query
  update public.order_counters
     set receipt_seq = receipt_seq + 1,
         day_seq     = case when day = d then day_seq + 1      else 1      end,
         ta_seq      = case when day = d then ta_seq  + inc_ta else inc_ta end,
         dl_seq      = case when day = d then dl_seq  + inc_dl else inc_dl end,
         day         = d
   where id = 1
   returning order_counters.receipt_seq,
             order_counters.day_seq,
             case p_kind
               when 'takeaway' then order_counters.ta_seq
               when 'delivery' then order_counters.dl_seq
               else null
             end;
end;
$$;
grant execute on function public.rpc_next_order_num(text) to anon, authenticated;

select pg_notify('pgrst', 'reload schema');

-- 完成。跨午夜的单会算进当晚那个营业日，订单号也不会在午夜重来一次。
