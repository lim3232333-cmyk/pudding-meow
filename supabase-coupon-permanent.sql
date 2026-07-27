-- ============================================================================
--  布丁喵 — 优惠券支持「永久有效」
--  用法：Supabase Dashboard → SQL Editor → New query → 粘贴 → Run（跑一次）
--  前置：supabase-membership-phase2.sql、supabase-coupon-mall.sql 已跑过。
--
--  原本每张券必定有到期日：coupons.valid_days 是 not null，
--  member_coupons.expires_at 也是 not null，发券时一律 now() + valid_days。
--
--  改法：valid_days 留空（null）或填 0 = 永久有效，发出去的券 expires_at 存 null。
--  所有判断过期的地方都要加 "expires_at is not null" —— 否则 null < now() 恒为
--  null（不是 true 也不是 false），虽然不会误判成过期，但把条件写清楚更稳妥。
-- ============================================================================

-- 1) 放开两个 not null
alter table public.member_coupons alter column expires_at drop not null;
alter table public.coupons        alter column valid_days drop not null;

-- 2) 统一算到期时间：永久返回 null
create or replace function public._coupon_expiry(p_valid_days int)
returns timestamptz
language sql
immutable
as $$
  select case when coalesce(p_valid_days, 0) <= 0
              then null
              else now() + (p_valid_days || ' days')::interval
         end;
$$;

-- 3) 后台发券
create or replace function public.rpc_admin_issue_coupon(p_coupon_id uuid, p_member_id uuid default null)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare v_coupon record; v_count int := 0;
begin
  select * into v_coupon from public.coupons where id = p_coupon_id and enabled = true;
  if v_coupon is null then raise exception '优惠券不存在或已停用'; end if;
  if p_member_id is not null then
    insert into public.member_coupons(member_id, coupon_id, expires_at)
      values (p_member_id, p_coupon_id, public._coupon_expiry(v_coupon.valid_days));
    v_count := 1;
  else
    insert into public.member_coupons(member_id, coupon_id, expires_at)
      select id, p_coupon_id, public._coupon_expiry(v_coupon.valid_days) from public.members;
    get diagnostics v_count = row_count;
  end if;
  return v_count;
end;
$$;

-- 4) 积分商城兑换
create or replace function public.rpc_redeem_coupon(
  p_member_id uuid, p_session_token text, p_coupon_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_coupon record;
  v_coins  int;
  v_new_id uuid;
begin
  perform public._auth_member(p_member_id, p_session_token);

  select * into v_coupon from public.coupons where id = p_coupon_id;
  if v_coupon is null or not v_coupon.enabled then
    raise exception '该优惠券不存在或已下架';
  end if;
  if coalesce(v_coupon.coin_price, 0) <= 0 then
    raise exception '该优惠券未在积分商城出售';
  end if;

  -- 锁住会员行再读余额，避免连点两次各扣一次却发两张券
  select coins into v_coins from public.members where id = p_member_id for update;
  if v_coins < v_coupon.coin_price then
    raise exception 'Coin 不足：需要 %，当前 %', v_coupon.coin_price, v_coins;
  end if;

  update public.members set coins = coins - v_coupon.coin_price where id = p_member_id;
  insert into public.member_coin_ledger(member_id, delta, reason, ref_type, ref_id)
    values (p_member_id, -v_coupon.coin_price, 'mall_redeem', 'coupon', p_coupon_id::text);

  insert into public.member_coupons(member_id, coupon_id, status, expires_at)
    values (p_member_id, p_coupon_id, 'unused', public._coupon_expiry(v_coupon.valid_days))
    returning id into v_new_id;

  return v_new_id;
end;
$$;

-- 5) 核销：永久券永远不判过期
create or replace function public.rpc_pos_use_coupon(p_member_coupon_id uuid, p_order_id text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_row record;
begin
  select * into v_row from public.member_coupons where id = p_member_coupon_id;
  if v_row is null then raise exception '优惠券不存在'; end if;
  if v_row.status <> 'unused' then raise exception '该优惠券已使用或已失效'; end if;
  if v_row.expires_at is not null and v_row.expires_at < now() then
    update public.member_coupons set status = 'expired' where id = p_member_coupon_id;
    raise exception '该优惠券已过期';
  end if;
  update public.member_coupons set status = 'used', used_at = now(), order_id = p_order_id
   where id = p_member_coupon_id;
end;
$$;

-- 6) 顾客端「我的优惠券」：自动过期时跳过永久券
create or replace function public.rpc_get_my_coupons(p_member_id uuid, p_session_token text)
returns table(
  id uuid, coupon_id uuid, name text, type text, value numeric, min_spend numeric,
  status text, issued_at timestamptz, expires_at timestamptz,
  menu_item_name text, menu_item_image text)
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public._auth_member(p_member_id, p_session_token);
  -- 别名 + 限定列：expires_at / status 也是 OUT 参数名，不限定会 ambiguous
  update public.member_coupons mc set status = 'expired'
   where mc.member_id = p_member_id and mc.status = 'unused'
     and mc.expires_at is not null and mc.expires_at < now();
  return query
  select mc.id, mc.coupon_id, c.name, c.type, c.value, c.min_spend,
         mc.status, mc.issued_at, mc.expires_at, mi.name, mi.image_url
    from public.member_coupons mc
    join public.coupons c on c.id = mc.coupon_id
    left join public.menu_items mi on mi.id = c.menu_item_id
   where mc.member_id = p_member_id
   order by (mc.status = 'unused') desc, mc.issued_at desc;
end;
$$;

-- 7) 后台「已发出的券」列表：同样跳过永久券
create or replace function public.rpc_admin_list_member_coupons(p_search text default null)
returns table(id uuid, member_id uuid, member_phone text, member_nickname text,
              coupon_name text, status text, issued_at timestamptz, expires_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.member_coupons mc set status = 'expired'
   where mc.status = 'unused' and mc.expires_at is not null and mc.expires_at < now();
  return query
  select mc.id, mc.member_id, m.phone, m.nickname, c.name, mc.status, mc.issued_at, mc.expires_at
    from public.member_coupons mc
    join public.members m on m.id = mc.member_id
    join public.coupons c on c.id = mc.coupon_id
   where p_search is null or p_search = ''
      or m.phone ilike '%' || p_search || '%'
      or m.nickname ilike '%' || p_search || '%'
   order by mc.issued_at desc
   limit 200;
end;
$$;

grant execute on function public.rpc_admin_issue_coupon(uuid, uuid) to anon;
grant execute on function public.rpc_redeem_coupon(uuid, text, uuid) to anon;
grant execute on function public.rpc_pos_use_coupon(uuid, text) to anon;
grant execute on function public.rpc_get_my_coupons(uuid, text) to anon;
grant execute on function public.rpc_admin_list_member_coupons(text) to anon;

-- 完成。POS 建券时「有效期」选「永久有效」即可；已发出去的旧券不受影响。
