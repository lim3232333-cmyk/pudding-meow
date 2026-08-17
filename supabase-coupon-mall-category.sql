-- ============================================================================
--  布丁喵 — 积分商城分区（限定 / 现金回扣·折扣 / 免邮 / 合作）
--  用法：Supabase Dashboard → SQL Editor → New query → 整段粘贴 → Run。
--        跑一次就好，可以重复跑（幂等）。
--  前置：supabase-coupon-v2.sql 已跑过（v3 跑不跑都行）。
--
--  商城首页按四个分区横向排券。分区**不是**从券的类型推出来的，而是店家自己选：
--  「限定」和「合作」本来就是营销概念——同样一张 RM5 券，这个月放「限定」、
--  下个月放「合作」，系统没法猜。类型能推的只有「免邮」，但为了一件事只有一个
--  地方管，四个分区一律走这一列。
--
--  留空 = 不分区，掉进商城最后的「其他好礼」那一段，不会消失。
-- ============================================================================

alter table public.coupons
  add column if not exists mall_category text;

comment on column public.coupons.mall_category is
  '积分商城的分区：limited(限定) / cashback(现金回扣·折扣) / free_ship(免邮) / partner(合作)。null = 不分区，排在「其他好礼」。';

-- 商城列表要把分区带出去。返回的列变了，create or replace 改不动，得先删——
-- 这一条已经栽过一次（cannot change return type of existing function）。
drop function if exists public.rpc_list_mall_coupons();
create or replace function public.rpc_list_mall_coupons()
returns table(
  id uuid, name text, type text, value numeric, min_spend numeric,
  valid_days int, coin_price int, menu_item_id uuid, menu_item_name text, menu_item_image text,
  max_discount numeric, channels jsonb, applies_to jsonb, rule_id uuid, mall_category text)
language plpgsql
security definer
set search_path = public
as $$
begin
  return query
  select c.id, c.name, c.type, c.value, c.min_spend, c.valid_days, r.coin_price,
         c.menu_item_id, mi.name, mi.image_url,
         c.max_discount, c.channels, coalesce(c.applies_to,'{"scope":"order"}'::jsonb), r.id,
         c.mall_category
    from public.coupons c
    join public.coupon_rules r on r.coupon_id = c.id
                              and r.trigger_event = 'coin_redeem'
                              and r.enabled
    left join public.menu_items mi on mi.id = c.menu_item_id
   where c.enabled
     and coalesce(r.coin_price, 0) > 0
     and (r.starts_at is null or now() >= r.starts_at)
     and (r.ends_at   is null or now() <= r.ends_at)
     and (r.total_limit is null or r.issued_count < r.total_limit)
   order by r.coin_price asc;
end;
$$;

grant execute on function public.rpc_list_mall_coupons() to anon;

select count(*) as 商城在售券,
       count(*) filter (where mall_category is not null) as 已分区
  from public.coupons where enabled;
