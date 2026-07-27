-- ============================================================================
--  布丁喵 — 优惠券分类（现金折扣/百分比折扣/甜品兑换）+ 积分商城真正能兑换
--  用法：Supabase Dashboard → SQL Editor → New query → 粘贴 → Run（跑一次）
--  前置：supabase-membership.sql / -phase2.sql / supabase-setup.sql 已跑过。
--
--  背景：小程序的「积分商城」原本是假的——商品写死在代码里的两条，
--        「兑换」按钮只弹「敬请期待」，没有商品表也没有兑换逻辑。
--
--  设计：积分商城的商品 = 优惠券模板本身。给 coupons 加一个 coin_price，
--        填了就出现在商城里，顾客花 Coin 兑换 → 生成一张 member_coupons，
--        在小程序「我的」里看得到。这样不用维护两套东西。
--
--  券类型：
--    fixed_off    现金折扣   减 RM value
--    percent_off  百分比折扣 打折，value=20 表示减 20%
--    dessert      甜品兑换   换 menu_item_id 指定的那件商品（value/min_spend 不用）
-- ============================================================================

alter table public.coupons
  add column if not exists coin_price   int,     -- 积分商城售价；null 或 0 = 不在商城出售
  add column if not exists menu_item_id uuid references public.menu_items(id);  -- 仅 dessert 类型用

-- 1) 商城列表：只列出有标价且启用的券。不含个人数据，anon 可直接读。
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
   where c.enabled and coalesce(c.coin_price, 0) > 0
   order by c.coin_price asc;
end;
$$;

-- 2) 兑换：扣 Coin → 发券 → 记流水。整套必须在服务端做，
--    否则前端可以直接改余额白拿券（anon key 是公开的）。
create or replace function public.rpc_redeem_coupon(
  p_member_id uuid, p_session_token text, p_coupon_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_coupon  record;
  v_coins   int;
  v_new_id  uuid;
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
    values (p_member_id, p_coupon_id, 'unused', now() + (v_coupon.valid_days || ' days')::interval)
    returning id into v_new_id;

  return v_new_id;
end;
$$;

-- 3) 「我的优惠券」补上甜品券要显示的商品名，和商城售价
drop function if exists public.rpc_get_my_coupons(uuid, text);
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
   where mc.member_id = p_member_id and mc.status = 'unused' and mc.expires_at < now();
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

grant execute on function public.rpc_list_mall_coupons() to anon;
grant execute on function public.rpc_redeem_coupon(uuid, text, uuid) to anon;
grant execute on function public.rpc_get_my_coupons(uuid, text) to anon;

-- 完成。POS「优惠券管理」建券时选类型、填 Coin 售价（甜品券再选一个商品），
-- 填了售价的券就会出现在小程序积分商城里。
