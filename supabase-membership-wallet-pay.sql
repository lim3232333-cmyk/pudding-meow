-- ============================================================================
--  布丁喵 Meow Club — 钱包「付款」+「充值到账」两个 RPC
--  用法：Supabase Dashboard → SQL Editor → New query → 粘贴全部 → Run（可重复执行）
--  依赖：supabase-membership.sql（member_coin_ledger、_auth_member）、
--        supabase-membership-wallet.sql（wallet_balance、member_wallet_ledger）、
--        supabase-orders-delivery.sql（orders.delivery_info）已经跑过。
-- ============================================================================

-- ---------- 1) 用余额付款：结算时从会员钱包扣钱 ----------
-- 前端（小程序结算页）先生成订单号 order_id，再调本函数扣款；成功后前端才把订单
-- 落库成 preparing。幂等：同一个 order_id 只扣一次（防重复点、防重试）。
create or replace function public.rpc_pay_with_wallet(
  p_member_id uuid, p_session_token text, p_order_id text, p_amount numeric)
returns numeric language plpgsql security definer as $$
declare v_bal numeric;
begin
  perform public._auth_member(p_member_id, p_session_token);
  if p_amount is null or p_amount <= 0 then raise exception '金额无效'; end if;

  -- 幂等：这笔订单已经扣过，直接返回当前余额，不重复扣
  if exists(select 1 from public.member_wallet_ledger
              where member_id = p_member_id and ref_type = 'order' and ref_id = p_order_id) then
    select wallet_balance into v_bal from public.members where id = p_member_id;
    return v_bal;
  end if;

  select wallet_balance into v_bal from public.members where id = p_member_id for update;
  if v_bal is null then raise exception '会员不存在'; end if;
  if v_bal < p_amount then raise exception '余额不足'; end if;

  update public.members set wallet_balance = wallet_balance - p_amount where id = p_member_id;
  insert into public.member_wallet_ledger(member_id, delta, reason, ref_type, ref_id)
    values (p_member_id, -p_amount, 'order', 'order', p_order_id);

  select wallet_balance into v_bal from public.members where id = p_member_id;
  return v_bal;
end; $$;

-- ---------- 2) 充值到账：POS 收到柜台现金后调用，钱包 1:1 到账 + 赠送 coin ----------
-- 充值单是一条 orders 行：ta_mode='recharge'、total=顾客付的钱（=钱包到账，1:1）、
-- delivery_info={"recharge":{"price":100,"coins":120}}（coins=赠送的 Meow Coin）。
-- 幂等：只在订单仍是 pending 时处理一次（防店员重复点、防实时重渲染重复入账）。
create or replace function public.rpc_complete_recharge(p_order_id text)
returns numeric language plpgsql security definer as $$
declare v_member uuid; v_price numeric; v_coins int; v_di jsonb; v_bal numeric;
begin
  select member_id, total, delivery_info into v_member, v_price, v_di
    from public.orders where id = p_order_id and ta_mode = 'recharge';
  if v_member is null then raise exception '充值订单不存在或未绑定会员'; end if;

  -- 幂等锁：只有仍是 pending 才处理
  update public.orders set status = 'done' where id = p_order_id and status = 'pending';
  if not found then
    select wallet_balance into v_bal from public.members where id = v_member;
    return v_bal;
  end if;

  -- 钱包 1:1 到账（= 顾客在柜台付的钱）
  insert into public.member_wallet_ledger(member_id, delta, reason, ref_type, ref_id)
    values (v_member, v_price, 'topup', 'recharge', p_order_id);
  update public.members set wallet_balance = wallet_balance + v_price where id = v_member;

  -- 赠送 Meow Coin
  v_coins := coalesce((v_di->'recharge'->>'coins')::int, 0);
  if v_coins > 0 then
    insert into public.member_coin_ledger(member_id, delta, reason, ref_type, ref_id)
      values (v_member, v_coins, 'recharge_bonus', 'recharge', p_order_id);
    update public.members set coins = coins + v_coins where id = v_member;
  end if;

  select wallet_balance into v_bal from public.members where id = v_member;
  return v_bal;
end; $$;

-- ---------- 3) 授权 ----------
grant execute on function public.rpc_pay_with_wallet(uuid, text, text, numeric) to anon;
grant execute on function public.rpc_complete_recharge(text) to anon;

-- 完成。
-- - 小程序结算「余额支付」→ rpc_pay_with_wallet 扣钱；
-- - 小程序「充值」发起柜台充值单进 POS 待付款，店员收款点「已付款」→
--   rpc_complete_recharge 给钱包加钱 + 送 coin。
