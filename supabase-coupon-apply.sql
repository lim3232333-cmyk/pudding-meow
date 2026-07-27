-- ============================================================================
--  布丁喵 — 优惠券：发放时间窗口 + 真正抵扣订单金额
--  用法：Supabase Dashboard → SQL Editor → New query → 粘贴 → Run（跑一次）
--  前置：supabase-coupon-mall.sql、supabase-coupon-permanent.sql 已跑过。
--
--  A) 发放时间：coupons 加 issue_from / issue_until。两者都留空 = 不限时间。
--     不在窗口内时：不出现在积分商城、也不能后台发放/兑换。
--     注意这跟「有效期」是两回事——发放窗口管的是「这张券什么时候能拿到」，
--     valid_days 管的是「拿到之后多久过期」。
--
--  B) 抵扣：orders 加 coupon_id / discount 两列，并新增两个 RPC：
--     rpc_preview_coupon  只算不改，给结算页显示用
--     rpc_consume_coupon  校验 + 核销 + 返回折扣，下单时调用
--
--     折扣金额一律以服务端算的为准。前端算的那份只用来显示，
--     因为 anon key 是公开的，顾客可以随便改前端传上来的数字。
-- ============================================================================

-- ---------- A) 发放时间窗口 ----------
alter table public.coupons
  add column if not exists issue_from  timestamptz,
  add column if not exists issue_until timestamptz;

create or replace function public._coupon_issuable(p_from timestamptz, p_until timestamptz)
returns boolean
language sql
stable
as $$
  select (p_from is null or now() >= p_from)
     and (p_until is null or now() <= p_until);
$$;

-- 商城列表：只列出在发放窗口内的
create or replace function public.rpc_list_mall_coupons()
returns table(
  id uuid, name text, type text, value numeric, min_spend numeric,
  valid_days int, coin_price int, menu_item_id uuid, menu_item_name text, menu_item_image text)
language plpgsql
security definer
set search_path = public
as $$
begin
  return query
  select c.id, c.name, c.type, c.value, c.min_spend, c.valid_days, c.coin_price,
         c.menu_item_id, mi.name, mi.image_url
    from public.coupons c
    left join public.menu_items mi on mi.id = c.menu_item_id
   where c.enabled
     and coalesce(c.coin_price, 0) > 0
     and public._coupon_issuable(c.issue_from, c.issue_until)
   order by c.coin_price asc;
end;
$$;

-- ---------- B) 订单记录折扣 ----------
alter table public.orders
  add column if not exists coupon_id uuid references public.member_coupons(id),
  add column if not exists discount  numeric not null default 0;

-- 共用的校验 + 算折扣。p_item_ids 是购物车里的 menu_items id 列表（甜品券要用）。
-- 返回 (discount, coupon_row)；不通过直接 raise。
create or replace function public._coupon_calc(
  p_member_id uuid, p_member_coupon_id uuid, p_subtotal numeric, p_item_ids uuid[])
returns numeric
language plpgsql
stable
set search_path = public
as $$
declare v record; v_disc numeric;
begin
  select mc.status, mc.expires_at, mc.member_id,
         c.type, c.value, c.min_spend, c.menu_item_id, c.name
    into v
    from public.member_coupons mc
    join public.coupons c on c.id = mc.coupon_id
   where mc.id = p_member_coupon_id;

  if v is null then raise exception '优惠券不存在'; end if;
  if v.member_id <> p_member_id then raise exception '这不是你的优惠券'; end if;
  if v.status <> 'unused' then raise exception '该优惠券已使用或已失效'; end if;
  if v.expires_at is not null and v.expires_at < now() then raise exception '该优惠券已过期'; end if;
  if p_subtotal < coalesce(v.min_spend, 0) then
    raise exception '未达使用门槛：需满 RM%，当前 RM%', v.min_spend, p_subtotal;
  end if;

  if v.type = 'dessert' then
    if v.menu_item_id is null then raise exception '该甜品券未绑定商品，请联系店员'; end if;
    if p_item_ids is null or not (v.menu_item_id = any(p_item_ids)) then
      raise exception '购物车里没有「%」，这张券用不了', v.name;
    end if;
    -- 甜品券抵掉那件商品的售价
    select coalesce(price, 0) into v_disc from public.menu_items where id = v.menu_item_id;
  elsif v.type = 'percent_off' then
    v_disc := round(p_subtotal * coalesce(v.value, 0) / 100.0, 2);
  else   -- fixed_off
    v_disc := coalesce(v.value, 0);
  end if;

  -- 折扣不能超过小计，否则会算出负数总额
  return least(greatest(coalesce(v_disc, 0), 0), p_subtotal);
end;
$$;

-- 结算页预览：只算不改
create or replace function public.rpc_preview_coupon(
  p_member_id uuid, p_session_token text, p_member_coupon_id uuid,
  p_subtotal numeric, p_item_ids uuid[] default null)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public._auth_member(p_member_id, p_session_token);
  return public._coupon_calc(p_member_id, p_member_coupon_id, p_subtotal, p_item_ids);
end;
$$;

-- 下单时核销：校验 → 标记已使用 → 返回服务端认可的折扣金额。
-- 先核销再落单，避免「折扣给了但券没扣掉」；行锁防连点两次用同一张券。
create or replace function public.rpc_consume_coupon(
  p_member_id uuid, p_session_token text, p_member_coupon_id uuid,
  p_order_id text, p_subtotal numeric, p_item_ids uuid[] default null)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare v_disc numeric; v_status text;
begin
  perform public._auth_member(p_member_id, p_session_token);

  select status into v_status from public.member_coupons
   where id = p_member_coupon_id for update;
  if v_status is null then raise exception '优惠券不存在'; end if;

  v_disc := public._coupon_calc(p_member_id, p_member_coupon_id, p_subtotal, p_item_ids);

  update public.member_coupons
     set status = 'used', used_at = now(), order_id = p_order_id
   where id = p_member_coupon_id;

  return v_disc;
end;
$$;

-- 券作废退回（订单落库失败时调用，把券放回去）
create or replace function public.rpc_release_coupon(
  p_member_id uuid, p_session_token text, p_member_coupon_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public._auth_member(p_member_id, p_session_token);
  update public.member_coupons
     set status = 'unused', used_at = null, order_id = null
   where id = p_member_coupon_id and member_id = p_member_id and status = 'used';
end;
$$;

-- 后台发券：不在发放窗口内就拒绝
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
  if not public._coupon_issuable(v_coupon.issue_from, v_coupon.issue_until) then
    raise exception '该优惠券不在发放时间内';
  end if;
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

-- 商城兑换：同样受发放窗口限制
create or replace function public.rpc_redeem_coupon(
  p_member_id uuid, p_session_token text, p_coupon_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare v_coupon record; v_coins int; v_new_id uuid;
begin
  perform public._auth_member(p_member_id, p_session_token);

  select * into v_coupon from public.coupons where id = p_coupon_id;
  if v_coupon is null or not v_coupon.enabled then raise exception '该优惠券不存在或已下架'; end if;
  if coalesce(v_coupon.coin_price, 0) <= 0 then raise exception '该优惠券未在积分商城出售'; end if;
  if not public._coupon_issuable(v_coupon.issue_from, v_coupon.issue_until) then
    raise exception '该优惠券不在发放时间内';
  end if;

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

-- 「我的优惠券」补上甜品券绑定的商品 id，前端才能判断购物车里有没有那件商品
drop function if exists public.rpc_get_my_coupons(uuid, text);
create or replace function public.rpc_get_my_coupons(p_member_id uuid, p_session_token text)
returns table(
  id uuid, coupon_id uuid, name text, type text, value numeric, min_spend numeric,
  status text, issued_at timestamptz, expires_at timestamptz,
  menu_item_id uuid, menu_item_name text, menu_item_image text)
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public._auth_member(p_member_id, p_session_token);
  -- 必须写别名 mc 并限定列：expires_at / status / id 同时也是本函数的 OUT 参数名，
  -- 不限定的话 plpgsql 分不清是列还是变量，直接报 column reference ... is ambiguous
  update public.member_coupons mc set status = 'expired'
   where mc.member_id = p_member_id and mc.status = 'unused'
     and mc.expires_at is not null and mc.expires_at < now();
  return query
  select mc.id, mc.coupon_id, c.name, c.type, c.value, c.min_spend,
         mc.status, mc.issued_at, mc.expires_at, c.menu_item_id, mi.name, mi.image_url
    from public.member_coupons mc
    join public.coupons c on c.id = mc.coupon_id
    left join public.menu_items mi on mi.id = c.menu_item_id
   where mc.member_id = p_member_id
   order by (mc.status = 'unused') desc, mc.issued_at desc;
end;
$$;

grant execute on function public.rpc_list_mall_coupons() to anon;
grant execute on function public.rpc_preview_coupon(uuid, text, uuid, numeric, uuid[]) to anon;
grant execute on function public.rpc_consume_coupon(uuid, text, uuid, text, numeric, uuid[]) to anon;
grant execute on function public.rpc_release_coupon(uuid, text, uuid) to anon;
grant execute on function public.rpc_admin_issue_coupon(uuid, uuid) to anon;
grant execute on function public.rpc_redeem_coupon(uuid, text, uuid) to anon;
grant execute on function public.rpc_get_my_coupons(uuid, text) to anon;

-- 完成。POS 建券可设发放时间；顾客在结算页选券后金额直接减，下单时服务端核销。
