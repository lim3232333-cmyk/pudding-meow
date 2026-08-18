-- ============================================================================
--  布丁喵 — 券图的取景位置（店家自己拖，决定图被切掉哪一块）
--  用法：Supabase Dashboard → SQL Editor → New query → 整段粘贴 → Run。
--        跑一次就好，可以重复跑（幂等）。
--  前置：supabase-my-coupon-image.sql、**supabase-coupon-free-claim.sql**
--        ⚠ 顺序不能反：free-claim 也会重建 rpc_list_mall_coupons，
--          先跑这份再跑它，image_pos 会被它的旧版本盖掉。下面有硬检查。
--
--  券图一律 cover 铺满两个槽位（商城卡 230×98 = 2.35、券面 345×128 = 2.70），
--  比例对不上就必然要切掉一部分。原来切的永远是正中间那一块——可券绑定的商品图
--  是菜单那条路裁出来的 380×310 方图，居中未必是布丁最好看的那一半。
--
--  image_pos 存的就是 CSS 的 object-position（`'50% 35%'`），店家在 POS 上
--  两个真实尺寸的预览框里拖出来。null = 居中，跟以前一样。
--
--  为什么不做成「给券再裁一张图」：裁要过 canvas，canvas 一碰 SVG 就把它栅格化
--  （这一点在券图上传那里已经栽过一次）；而且裁一次就把原图的其余部分永久丢了，
--  换个槽位比例又得重裁。存一个位置则是无损的，SVG 也照样能拖。
-- ============================================================================

do $$
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='coupons' and column_name='voucher_image_url') then
    raise exception '请先跑 supabase-my-coupon-image.sql —— coupons 还没有 voucher_image_url 列';
  end if;
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname='public' and p.proname='_coupon_rule_guard') then
    raise exception '请先跑 supabase-coupon-free-claim.sql —— 它也会重建 rpc_list_mall_coupons，跑在这份后面会把 image_pos 盖掉';
  end if;
end $$;

alter table public.coupons
  add column if not exists image_pos text;
comment on column public.coupons.image_pos is
  '券图的取景位置，就是 CSS object-position（如 ''50% 35%''）。图一律 cover 铺满，这个值决定切掉哪一块。null = 居中。';

-- ── 商城列表：把取景位置带出去 ──────────────────────────────────────────────
--  where 沿用 supabase-coupon-free-claim.sql 那版（coin_price is not null，
--  0 = 免费领），只是多返回一列。
drop function if exists public.rpc_list_mall_coupons();
create or replace function public.rpc_list_mall_coupons()
returns table(
  id uuid, name text, type text, value numeric, min_spend numeric,
  valid_days int, coin_price int, menu_item_id uuid, menu_item_name text, menu_item_image text,
  max_discount numeric, channels jsonb, applies_to jsonb, rule_id uuid,
  mall_category text, mall_image_url text, image_pos text)
language plpgsql
security definer
set search_path = public
as $$
begin
  return query
  select c.id, c.name, c.type, c.value, c.min_spend, c.valid_days, r.coin_price,
         c.menu_item_id, mi.name, mi.image_url,
         c.max_discount, c.channels, coalesce(c.applies_to,'{"scope":"order"}'::jsonb), r.id,
         c.mall_category, c.mall_image_url, c.image_pos
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

-- ── 我的券：同上 ───────────────────────────────────────────────────────────
drop function if exists public.rpc_get_my_coupons(uuid, text);
create or replace function public.rpc_get_my_coupons(p_member_id uuid, p_session_token text)
returns table(
  id uuid, coupon_id uuid, name text, type text, value numeric, min_spend numeric,
  status text, issued_at timestamptz, expires_at timestamptz,
  menu_item_name text, menu_item_image text,
  max_discount numeric, channels jsonb, applies_to jsonb, valid_from timestamptz,
  usable_days jsonb, usable_hours jsonb, mall_image_url text, voucher_image_url text,
  image_pos text)
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
         c.usable_days, c.usable_hours, c.mall_image_url, c.voucher_image_url, c.image_pos
    from public.member_coupons mc
    join public.coupons c on c.id = mc.coupon_id
    left join public.menu_items mi on mi.id = c.menu_item_id
   where mc.member_id = p_member_id
   order by (mc.status = 'unused') desc, mc.issued_at desc;
end;
$$;

grant execute on function public.rpc_list_mall_coupons() to anon;
grant execute on function public.rpc_get_my_coupons(uuid, text) to anon;

-- 对账：哪些券调过取景
select name as 券名,
       coalesce(image_pos, '50% 50%（居中）') as 取景,
       (mall_image_url is not null) as 有商城图,
       (voucher_image_url is not null) as 有券面图
  from public.coupons
 where enabled
 order by (image_pos is not null) desc, name;
