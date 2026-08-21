-- ============================================================================
--  布丁喵 — 充值在线支付也收手续费，不再是店家自己吃
--  用法：Supabase Dashboard → SQL Editor → New query → 整段粘贴 → Run。
--        跑一次就好，可以重复跑（幂等）。
--  前置：supabase-admin-fee.sql（加了 orders.admin_fee + shop_settings.admin_fee_rates）
--        supabase-wallet-rules.sql（rpc_complete_recharge / _wallet_check_limits 现在的版本）
--
--  背景：结算页（点单）早就把 HitPay 的手续费转嫁给顾客了——客人选 Touch n Go /
--  Online Banking / 信用卡，各自看到费率，手续费加进要付的钱。但「充值」那条路
--  只是笼统跳一个 HitPay 收银页，从不算手续费、也不存 admin_fee，等于店家自己在
--  贴 HitPay 的通道费。这份脚本把充值也接上同一套 _adminFee 机制（前端已经改好）。
--
--  ⚠ 唯一要小心的地方：钱包到账金额**不能**等于 orders.total。total 现在含了
--    手续费（客人多付的那一点），那笔钱转手就给 HitPay 了，不是充进钱包的钱——
--    照旧按 total 1:1 到账，等于把手续费变成免费送的余额。所以到账金额改成
--    total − admin_fee（= 套餐原价）。柜台充值走的还是 rpc_pos_topup，从来没有
--    admin_fee 这回事，不受影响。
--
--  充值额/余额上限（_wallet_check_limits）也跟着改用「到账金额」而不是「客人付的
--  总额」去判：那几个上限本来管的就是「钱包里会有多少钱」，手续费从没进过钱包，
--  拿含手续费的总额去比会让客人在上限边界上被多拦一点点。
-- ============================================================================

do $$
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='orders' and column_name='admin_fee') then
    raise exception '请先跑 supabase-admin-fee.sql —— orders 还没有 admin_fee 列';
  end if;
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname='public' and p.proname='_wallet_check_limits') then
    raise exception '请先跑 supabase-wallet-rules.sql —— 还没有 _wallet_check_limits() 这个函数';
  end if;
end $$;

create or replace function public.rpc_complete_recharge(p_order_id text)
returns numeric language plpgsql security definer
set search_path = public
as $$
declare
  v_member uuid; v_total numeric; v_fee numeric; v_credit numeric; v_di jsonb; v_bal numeric;
  v_pkg record; v_coins int; v_xp int; v_tickets int;
begin
  select member_id, total, coalesce(admin_fee,0), delivery_info
    into v_member, v_total, v_fee, v_di
    from public.orders where id = p_order_id and ta_mode = 'recharge';
  if v_member is null then raise exception '充值订单不存在或未绑定会员'; end if;

  -- 到账金额 = 客人付的总额 − 手续费。柜台充值 admin_fee 恒为 0，v_credit = v_total，
  -- 行为跟以前一模一样；只有在线支付选了 HitPay 方式才会有这笔差额。
  v_credit := v_total - v_fee;
  perform public._wallet_check_limits(v_member, v_credit);

  -- 幂等锁：只有仍是 pending 才处理
  update public.orders set status = 'done' where id = p_order_id and status = 'pending';
  if not found then
    select wallet_balance into v_bal from public.members where id = v_member;
    return v_bal;
  end if;

  insert into public.member_wallet_ledger(member_id, delta, reason, ref_type, ref_id)
    values (v_member, v_credit, 'topup', 'recharge', p_order_id);
  update public.members set wallet_balance = wallet_balance + v_credit where id = v_member;

  -- 送什么，以套餐那一行为准，不听下单时前端写进来的数。
  -- 判「查到没有」必须用 found，不能写 if v_pkg is not null——record 的 IS NOT NULL
  -- 是「每个字段都非空」才成立，套餐的 tag 一般是 null，那样会被误判成没查到。
  select * into v_pkg from public.recharge_packages
   where id = (v_di->'recharge'->>'package_id')::uuid;
  if found then
    v_coins := v_pkg.coins; v_xp := v_pkg.xp; v_tickets := v_pkg.draw_tickets;
  else
    -- 套餐后来被删了：退回下单时存的那份快照。金额已经由顾客实付兜底，
    -- 与其让人家白付钱拿不到东西，不如按快照发。
    v_coins   := coalesce((v_di->'recharge'->>'coins')::int, 0);
    v_xp      := coalesce((v_di->'recharge'->>'xp')::int, 0);
    v_tickets := coalesce((v_di->'recharge'->>'draw_tickets')::int, 0);
  end if;

  perform public._wallet_grant_rewards(v_member, v_coins, v_xp, v_tickets, 'recharge', p_order_id);

  select wallet_balance into v_bal from public.members where id = v_member;
  return v_bal;
end; $$;

comment on function public.rpc_complete_recharge(text) is
  'recharge-admin-fee-v1: 钱包到账 = orders.total - orders.admin_fee，不是 total 本身（见 supabase-recharge-admin-fee.sql）';

grant execute on function public.rpc_complete_recharge(text) to anon;

select pg_notify('pgrst', 'reload schema');

-- 对账：最近几笔在线充值，手续费和到账金额分得开吗
select o.id, o.created_at, o.total as 客人付了, o.admin_fee as 手续费,
       (o.total - o.admin_fee) as 应到账,
       coalesce((select sum(l.delta) from public.member_wallet_ledger l
                  where l.ref_type='recharge' and l.ref_id=o.id), 0) as 实际到账流水
  from public.orders o
 where o.ta_mode='recharge' and o.pay_method='hitpay'
 order by o.created_at desc
 limit 10;
