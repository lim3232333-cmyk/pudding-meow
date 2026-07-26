-- ============================================================================
--  布丁喵 — POS 收银台绑定会员：查会员 / 看券 / 直接充值
--  用法：Supabase Dashboard → SQL Editor → New query → 粘贴 → Run（跑一次）
--  前置：supabase-membership*.sql、supabase-coupon-*.sql 都已跑过。
--
--  背景（重要）：POS 收银台原本完全不绑定会员——「顾客 Customer」只是一段纯文字，
--  下单时只存 customerName，从不设 member_id。而 markPaid() 里是
--  「if (o.memberId) rpc_on_order_completed(...)」，所以柜台单一直不给顾客
--  累积 XP 和 Coin，等级永远涨不动。收银台接上会员后这个洞就补上了。
-- ============================================================================

-- 1) 按手机号查会员（收银台输入电话后带出资料）
--    只回收银台要显示的字段，不含 pin_hash / session_token。
create or replace function public.rpc_pos_find_member(p_phone text)
returns table(
  id uuid, phone text, nickname text, level_name text, level_color text,
  xp int, coins int, wallet_balance numeric, unused_coupons int)
language plpgsql
security definer
set search_path = public
as $$
begin
  return query
  select m.id, m.phone, m.nickname, l.name_cn, l.color_hex,
         m.xp, m.coins, m.wallet_balance,
         (select count(*)::int from public.member_coupons mc
           where mc.member_id = m.id and mc.status = 'unused'
             and (mc.expires_at is null or mc.expires_at > now()))
    from public.members m
    left join public.member_levels l on l.id = m.level_id
   where regexp_replace(m.phone, '\D', '', 'g') = regexp_replace(p_phone, '\D', '', 'g')
   limit 1;
end;
$$;

-- 2) 该会员手上还没用的券（收银台 Voucher 按钮点开）
create or replace function public.rpc_pos_member_coupons(p_member_id uuid)
returns table(
  id uuid, name text, type text, value numeric, min_spend numeric,
  expires_at timestamptz, menu_item_id uuid, menu_item_name text)
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.member_coupons set status = 'expired'
   where member_id = p_member_id and status = 'unused'
     and expires_at is not null and expires_at < now();
  return query
  select mc.id, c.name, c.type, c.value, c.min_spend, mc.expires_at,
         c.menu_item_id, mi.name
    from public.member_coupons mc
    join public.coupons c on c.id = mc.coupon_id
    left join public.menu_items mi on mi.id = c.menu_item_id
   where mc.member_id = p_member_id and mc.status = 'unused'
   order by mc.issued_at desc;
end;
$$;

-- 3) 柜台直接充值：钱包按付款金额 1:1 入账 + 送 Coin，两条流水都写。
--    与小程序充值口径一致（那边是 rpc_complete_recharge），只是不用先建待付款单。
create or replace function public.rpc_pos_topup(
  p_member_id uuid, p_price numeric, p_bonus_coins int default 0, p_note text default null)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare v_bal numeric;
begin
  if p_price is null or p_price <= 0 then raise exception '充值金额无效'; end if;
  if not exists (select 1 from public.members where id = p_member_id) then
    raise exception '会员不存在';
  end if;

  update public.members
     set wallet_balance = wallet_balance + p_price,
         coins          = coins + greatest(coalesce(p_bonus_coins, 0), 0)
   where id = p_member_id
   returning wallet_balance into v_bal;

  insert into public.member_wallet_ledger(member_id, delta, reason, ref_type, ref_id)
    values (p_member_id, p_price, 'topup', 'pos', coalesce(p_note, 'POS 柜台充值'));

  if coalesce(p_bonus_coins, 0) > 0 then
    insert into public.member_coin_ledger(member_id, delta, reason, ref_type, ref_id)
      values (p_member_id, p_bonus_coins, 'topup_bonus', 'pos', coalesce(p_note, 'POS 柜台充值'));
  end if;

  return v_bal;
end;
$$;

grant execute on function public.rpc_pos_find_member(text) to anon;
grant execute on function public.rpc_pos_member_coupons(uuid) to anon;
grant execute on function public.rpc_pos_topup(uuid, numeric, int, text) to anon;

-- PostgREST 会缓存一份函数清单，新建的函数有时不会马上出现在缓存里，
-- 前端就会收到「Could not find the function ... in the schema cache」。
-- 主动通知它重新加载，省得干等。
select pg_notify('pgrst', 'reload schema');

-- 完成。收银台输入电话即可带出会员，结账时订单会带上 member_id，
-- 顾客在柜台消费也能累积 XP / Coin。
--
-- 跑完还是查不到会员的话，在 SQL Editor 里跑这句确认函数在不在：
--   select proname, pg_get_function_identity_arguments(oid)
--     from pg_proc where proname like 'rpc_pos_%';
-- 应该看到 rpc_pos_find_member(text) / rpc_pos_member_coupons(uuid) / rpc_pos_topup(uuid, numeric, integer, text)
