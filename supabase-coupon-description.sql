-- ============================================================================
--  布丁喵 — 券的「使用说明」（详情页券面下面那一段）
--  用法：Supabase Dashboard → SQL Editor → New query → 整段粘贴 → Run。
--        跑一次就好，可以重复跑（幂等）。
--  前置：**supabase-coupon-free-claim.sql** 和 **supabase-coupon-image-pos.sql**
--        （这两份也会重建下面这两个函数，跑在这份后面会把 description 盖掉。
--          下面有硬检查。）
--
--  顾客点开一张券会进详情页（Figma 869:1584 / 1144:1382）。稿子里券面下面
--  有一句「How to Get a free item:」—— 那是店家对这张券自己的说明，
--  「买一送一怎么用」这种话只有店家写得出来，系统猜不出来，所以是一列文本。
--
--  条款（Terms and Condition）不在这里：那三条是通用法律文本，写死在前端。
-- ============================================================================

do $$
begin
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname='public' and p.proname='_coupon_rule_guard') then
    raise exception '请先跑 supabase-coupon-free-claim.sql';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='coupons' and column_name='image_pos') then
    raise exception '请先跑 supabase-coupon-image-pos.sql —— coupons 还没有 image_pos 列';
  end if;
end $$;

alter table public.coupons
  add column if not exists description text;
comment on column public.coupons.description is
  '券详情页上券面下面那一段说明（如「买一送一怎么用：…」）。留空则那一段不显示。条款是通用文本，写死在前端，不在这里。';

-- ── 商城列表 ───────────────────────────────────────────────────────────────
--  ⚠ 每一份重建这个函数的脚本都必须带齐所有列（mall_category / mall_image_url /
--    image_pos / description）。少带一列，就等于「重跑一份旧脚本把新功能悄悄
--    抹掉」——这个项目已经栽过一次：兑好礼的图不跟着取景走，而券包跟着走，
--    因为那两页读的是不同的函数。
drop function if exists public.rpc_list_mall_coupons();
create or replace function public.rpc_list_mall_coupons()
returns table(
  id uuid, name text, type text, value numeric, min_spend numeric,
  valid_days int, coin_price int, menu_item_id uuid, menu_item_name text, menu_item_image text,
  max_discount numeric, channels jsonb, applies_to jsonb, rule_id uuid,
  mall_category text, mall_image_url text, image_pos text, description text)
language plpgsql
security definer
set search_path = public
as $$
begin
  return query
  select c.id, c.name, c.type, c.value, c.min_spend, c.valid_days, r.coin_price,
         c.menu_item_id, mi.name, mi.image_url,
         c.max_discount, c.channels, coalesce(c.applies_to,'{"scope":"order"}'::jsonb), r.id,
         c.mall_category, c.mall_image_url, c.image_pos, c.description
    from public.coupons c
    join public.coupon_rules r on r.coupon_id = c.id
                              and r.trigger_event = 'coin_redeem'
                              and r.enabled
    left join public.menu_items mi on mi.id = c.menu_item_id
   where c.enabled
     and r.coin_price is not null            -- null = 没上架；0 = 上架了，免费领
     and (r.starts_at is null or now() >= r.starts_at)
     and (r.ends_at   is null or now() <= r.ends_at)
     and (r.total_limit is null or r.issued_count < r.total_limit)
   order by r.coin_price asc;
end;
$$;

-- ── 我的券 ─────────────────────────────────────────────────────────────────
drop function if exists public.rpc_get_my_coupons(uuid, text);
create or replace function public.rpc_get_my_coupons(p_member_id uuid, p_session_token text)
returns table(
  id uuid, coupon_id uuid, name text, type text, value numeric, min_spend numeric,
  status text, issued_at timestamptz, expires_at timestamptz,
  menu_item_name text, menu_item_image text,
  max_discount numeric, channels jsonb, applies_to jsonb, valid_from timestamptz,
  usable_days jsonb, usable_hours jsonb, mall_image_url text, voucher_image_url text,
  image_pos text, description text)
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public._auth_member(p_member_id, p_session_token);
  update public.member_coupons mc set status = 'expired'
   where mc.member_id = p_member_id and mc.status = 'unused'
     and mc.expires_at is not null and mc.expires_at < now();
  return query
  select mc.id, mc.coupon_id, c.name, c.type, c.value, c.min_spend,
         mc.status, mc.issued_at, mc.expires_at, mi.name, mi.image_url,
         c.max_discount, c.channels, coalesce(c.applies_to,'{"scope":"order"}'::jsonb), c.valid_from,
         c.usable_days, c.usable_hours, c.mall_image_url, c.voucher_image_url,
         c.image_pos, c.description
    from public.member_coupons mc
    join public.coupons c on c.id = mc.coupon_id
    left join public.menu_items mi on mi.id = c.menu_item_id
   where mc.member_id = p_member_id
   order by (mc.status = 'unused') desc, mc.issued_at desc;
end;
$$;

grant execute on function public.rpc_list_mall_coupons() to anon;
grant execute on function public.rpc_get_my_coupons(uuid, text) to anon;

-- 对账：哪些券写了说明
select name as 券名,
       case when description is null or description = '' then '（没写）' else description end as 使用说明
  from public.coupons
 where enabled
 order by (description is not null) desc, name;
