-- ============================================================================
--  布丁喵 — 储值规则：钱包使用限制 + 充值按套餐发奖励
--  用法：Supabase Dashboard → SQL Editor → New query → 粘贴 → Run（跑一次）
--  前置：supabase-membership*.sql、supabase-pos-member.sql、
--        supabase-recharge-packages.sql 都已跑过。
--
--  奖励是「包」在套餐里的，不是全店一个倍率：一档套餐就是一整包，
--  充 RM50 → 钱包进 RM50 + 500 Coin + 1 次幸运抽奖 + 50 XP。
--  所以奖励数值在 recharge_packages 那一行上，这里只负责：
--    ① 充值时按套餐那一行把 Coin / XP / 抽奖券发下去
--    ② 钱包使用上的限制（最低/最高充值额、余额上限、余额付款算不算消费奖励）
--
--  关键：发多少一律由服务端去 recharge_packages 查，不听前端传的数。
--  anon key 是写在网页里的，谁都能改请求，前端说「送我 99999 Coin」不能算数。
-- ============================================================================

create table if not exists public.wallet_settings (
  id             int primary key default 1,
  wallet_earns   boolean not null default true, -- 用余额付款是否照常累积 XP/Coin
  min_topup      numeric,                       -- 单次最低充值额，null = 不限
  max_topup      numeric,                       -- 单次最高充值额，null = 不限
  max_balance    numeric,                       -- 余额上限，null = 不限
  refundable     boolean not null default false,-- 余额可否退款（店规，给顾客看的说明）
  updated_at     timestamptz not null default now(),
  constraint wallet_settings_single_row check (id = 1)
);
insert into public.wallet_settings (id) values (1) on conflict (id) do nothing;

-- 上一版把奖励做成了全店「每 RM1 送多少」，方向错了——奖励属于套餐。
-- 跑过那一版的，把这几列去掉；没跑过的这几句什么也不做。
alter table public.wallet_settings
  drop column if exists xp_per_rm,
  drop column if exists coin_per_rm,
  drop column if exists first_bonus_xp,
  drop column if exists first_bonus_coin,
  drop column if exists draw_tickets,
  drop column if exists first_draw_tickets;

alter table public.wallet_settings enable row level security;
drop policy if exists wallet_settings_anon_read on public.wallet_settings;
create policy wallet_settings_anon_read on public.wallet_settings for select to anon using (true);
drop policy if exists wallet_settings_anon_write on public.wallet_settings;
create policy wallet_settings_anon_write on public.wallet_settings for all to anon using (true) with check (true);

do $$
begin
  alter publication supabase_realtime add table public.wallet_settings;
exception when duplicate_object then null;
end $$;

-- ---------------------------------------------------------------------------
--  发奖励：Coin / XP / 抽奖券各写各的流水，XP 涨了顺带重算等级
-- ---------------------------------------------------------------------------
drop function if exists public._wallet_grant_rewards(uuid, numeric, text, text);
create or replace function public._wallet_grant_rewards(
  p_member_id uuid, p_coins int, p_xp int, p_tickets int, p_ref_type text, p_ref_id text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(p_coins,0) > 0 then
    insert into public.member_coin_ledger(member_id, delta, reason, ref_type, ref_id)
      values (p_member_id, p_coins, 'recharge', p_ref_type, p_ref_id);
    update public.members set coins = coins + p_coins where id = p_member_id;
  end if;

  if coalesce(p_xp,0) > 0 then
    insert into public.member_xp_ledger(member_id, delta, reason, ref_type, ref_id)
      values (p_member_id, p_xp, 'recharge', p_ref_type, p_ref_id);
    update public.members set xp = xp + p_xp where id = p_member_id;
    -- 跟 _grant_xp 一个口径：涨了 XP 可能就升级了
    update public.members set level_id = (
      select id from public.member_levels
       where xp_required <= (select xp from public.members where id = p_member_id)
       order by sort_order desc limit 1
    ) where id = p_member_id;
  end if;

  if coalesce(p_tickets,0) > 0 then
    update public.members set draw_tickets = draw_tickets + p_tickets where id = p_member_id;
  end if;
end;
$$;

-- 充值额 / 余额上限检查。不合规直接 raise，前端会把这句话原样显示出来。
create or replace function public._wallet_check_limits(p_member_id uuid, p_price numeric)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare s record; v_bal numeric;
begin
  select * into s from public.wallet_settings where id = 1;
  if not found then return; end if;
  if s.min_topup is not null and p_price < s.min_topup then
    raise exception '单次充值不能低于 RM%', s.min_topup;
  end if;
  if s.max_topup is not null and p_price > s.max_topup then
    raise exception '单次充值不能超过 RM%', s.max_topup;
  end if;
  if s.max_balance is not null then
    select wallet_balance into v_bal from public.members where id = p_member_id;
    if coalesce(v_bal,0) + p_price > s.max_balance then
      raise exception '充值后余额会超过上限 RM%（当前 RM%）', s.max_balance, coalesce(v_bal,0);
    end if;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
--  小程序充值单：顾客选好套餐 → 下单 → 店员收款点「已付款」
--  ⚠ 只有在 supabase-recharge-admin-fee.sql 还没跑过时才重建它。那份脚本让
--    在线充值的手续费不再由店家自己吃，钱包到账金额改成 total − admin_fee；
--    这里是旧版（到账 = total），重复跑这份会把那处修复悄悄抹掉（跟
--    coupon_rules.per_member_period 栽过的坑一模一样）。用它留在函数上的注释
--    当标记，检测到了就跳过、只打一条 notice。
-- ---------------------------------------------------------------------------
do $guard$
begin
  if exists (
    select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public' and p.proname = 'rpc_complete_recharge'
       and obj_description(p.oid, 'pg_proc') = 'recharge-admin-fee-v1: 钱包到账 = orders.total - orders.admin_fee，不是 total 本身（见 supabase-recharge-admin-fee.sql）'
  ) then
    raise notice '已检测到 supabase-recharge-admin-fee.sql 跑过 —— 它那版 rpc_complete_recharge 会扣掉充值手续费再到账，这里跳过重建，不覆盖它';
  else
    execute $sql$
      create or replace function public.rpc_complete_recharge(p_order_id text)
      returns numeric language plpgsql security definer
      set search_path = public
      as $$
      declare
        v_member uuid; v_price numeric; v_di jsonb; v_bal numeric;
        v_pkg record; v_coins int; v_xp int; v_tickets int;
      begin
        select member_id, total, delivery_info into v_member, v_price, v_di
          from public.orders where id = p_order_id and ta_mode = 'recharge';
        if v_member is null then raise exception '充值订单不存在或未绑定会员'; end if;

        perform public._wallet_check_limits(v_member, v_price);

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
    $sql$;
  end if;
end
$guard$;


-- ---------------------------------------------------------------------------
--  柜台直接充：店员选一档套餐，收钱，到账
--  签名从 (uuid, numeric, int, text) 改成 (uuid, uuid, text)——金额和奖励都
--  由套餐 id 决定，不再由收银台传。旧签名必须先 drop，不然会变成重载、
--  PostgREST 调用时会报函数不明确。
-- ---------------------------------------------------------------------------
drop function if exists public.rpc_pos_topup(uuid, numeric, int, text);
create or replace function public.rpc_pos_topup(
  p_member_id uuid, p_package_id uuid, p_note text default null)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare v_bal numeric; v_ref text; v_pkg record;
begin
  if not exists (select 1 from public.members where id = p_member_id) then
    raise exception '会员不存在';
  end if;
  select * into v_pkg from public.recharge_packages where id = p_package_id;
  if not found then raise exception '充值套餐不存在'; end if;   -- 同上，用 found 不用 IS NULL
  if v_pkg.enabled is false then raise exception '该充值套餐已停用'; end if;

  perform public._wallet_check_limits(p_member_id, v_pkg.price);

  -- 柜台充值没有订单号，用一个唯一串当流水引用，同一天多次充值才分得开
  v_ref := coalesce(nullif(trim(p_note),''), 'POS 柜台充值') || '#' || gen_random_uuid()::text;

  insert into public.member_wallet_ledger(member_id, delta, reason, ref_type, ref_id)
    values (p_member_id, v_pkg.price, 'topup', 'pos', v_ref);
  update public.members set wallet_balance = wallet_balance + v_pkg.price where id = p_member_id;

  perform public._wallet_grant_rewards(p_member_id, v_pkg.coins, v_pkg.xp, v_pkg.draw_tickets, 'pos', v_ref);

  select wallet_balance into v_bal from public.members where id = p_member_id;
  return v_bal;
end;
$$;

-- 「用余额付款还累不累积 XP/Coin」放服务端判：这个函数拿得到 p_order_id，
-- 自己去 orders 查这单是不是钱包付的，不用改签名、也不用信前端传什么。
-- 查不到订单就按原样发（有些流程先结算后落库，别因此把奖励吞了）。
create or replace function public.rpc_on_order_completed(p_member_id uuid, p_order_id text, p_amount numeric)
returns void language plpgsql security definer
set search_path = public
as $$
declare v_pay text; v_earns boolean;
begin
  if p_member_id is null then return; end if;
  select pay_method into v_pay from public.orders where id = p_order_id;
  if v_pay = 'wallet' then
    select wallet_earns into v_earns from public.wallet_settings where id = 1;
    if v_earns is false then return; end if;
  end if;
  perform public._grant_xp(p_member_id, 'purchase_per_rm', 'order', p_order_id, p_amount);
  perform public._grant_coin(p_member_id, 'purchase_per_rm', 'order', p_order_id, p_amount);
end; $$;

grant execute on function public.rpc_complete_recharge(text) to anon;
grant execute on function public.rpc_pos_topup(uuid, uuid, text) to anon;
grant execute on function public.rpc_on_order_completed(uuid, text, numeric) to anon;

select pg_notify('pgrst', 'reload schema');

-- 完成。套餐里配的 Coin / XP / 抽奖券，充值时由服务端照着那一行发；
-- POS「会员运营 → 储值规则」只管钱包使用上的限制。
