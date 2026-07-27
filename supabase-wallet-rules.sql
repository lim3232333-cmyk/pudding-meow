-- ============================================================================
--  布丁喵 — 储值规则：充值奖励 + 钱包使用限制
--  用法：Supabase Dashboard → SQL Editor → New query → 粘贴 → Run（跑一次）
--  前置：supabase-membership*.sql、supabase-pos-member.sql、
--        supabase-recharge-packages.sql 都已跑过。
--
--  背景：充值原本只做两件事——钱包 1:1 到账、送套餐自带的那点 Coin。
--  不发 XP、不发抽奖券，所以充值套餐里那栏「更多赠品」一直只是给顾客看的文字。
--  这份脚本把它变成真的：奖励在这里配，rpc_complete_recharge / rpc_pos_topup
--  照着发。另外顺带把最低/最高充值额、余额上限这些限制也落到服务端——
--  只在前端拦是拦不住的，anon key 是公开的。
--
--  只有一行设置，不做成多行规则表：这几个数是店里的统一口径，
--  不像 xp_rules 那样按 action 一条条配。
-- ============================================================================

create table if not exists public.wallet_settings (
  id                 int primary key default 1,
  -- ── 充值奖励 ──
  xp_per_rm          numeric not null default 0,   -- 每充 RM1 送多少 XP
  coin_per_rm        numeric not null default 0,   -- 每充 RM1 送多少 Coin（套餐自带的之外）
  first_bonus_xp     int     not null default 0,   -- 首次充值额外送 XP
  first_bonus_coin   int     not null default 0,   -- 首次充值额外送 Coin
  draw_tickets       int     not null default 0,   -- 每次充值送几张抽奖券
  first_draw_tickets int     not null default 0,   -- 首次充值额外送几张
  -- ── 钱包使用 ──
  wallet_earns       boolean not null default true, -- 用余额付款是否照常累积 XP/Coin
  min_topup          numeric,                       -- 单次最低充值额，null = 不限
  max_topup          numeric,                       -- 单次最高充值额，null = 不限
  max_balance        numeric,                       -- 余额上限，null = 不限
  refundable         boolean not null default false,-- 余额可否退款（店规，给顾客看的说明）
  updated_at         timestamptz not null default now(),
  constraint wallet_settings_single_row check (id = 1)
);
insert into public.wallet_settings (id) values (1) on conflict (id) do nothing;

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
--  共用：一次充值该发的东西。v_first = 这是不是这个会员的第一次充值。
--  member_wallet_ledger 里 reason='topup' 的记录就是充值历史，查它最准。
-- ---------------------------------------------------------------------------
create or replace function public._wallet_grant_rewards(
  p_member_id uuid, p_price numeric, p_ref_type text, p_ref_id text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare s record; v_first boolean; v_xp int; v_coin int; v_tickets int;
begin
  select * into s from public.wallet_settings where id = 1;
  if s is null then return; end if;

  -- 本次这笔已经写进流水了，所以「之前有没有充过」要排除掉这一笔
  select not exists (
    select 1 from public.member_wallet_ledger
     where member_id = p_member_id and reason = 'topup'
       and not (ref_type = p_ref_type and ref_id = p_ref_id)
  ) into v_first;

  v_xp      := floor(coalesce(p_price,0) * s.xp_per_rm)::int   + (case when v_first then s.first_bonus_xp   else 0 end);
  v_coin    := floor(coalesce(p_price,0) * s.coin_per_rm)::int + (case when v_first then s.first_bonus_coin else 0 end);
  v_tickets := s.draw_tickets + (case when v_first then s.first_draw_tickets else 0 end);

  if v_xp > 0 then
    insert into public.member_xp_ledger(member_id, delta, reason, ref_type, ref_id)
      values (p_member_id, v_xp, 'recharge', p_ref_type, p_ref_id);
    update public.members set xp = xp + v_xp where id = p_member_id;
    -- 涨了 XP 可能就升级了，跟 _grant_xp 一个口径
    update public.members set level_id = (
      select id from public.member_levels
       where xp_required <= (select xp from public.members where id = p_member_id)
       order by sort_order desc limit 1
    ) where id = p_member_id;
  end if;

  if v_coin > 0 then
    insert into public.member_coin_ledger(member_id, delta, reason, ref_type, ref_id)
      values (p_member_id, v_coin, 'recharge', p_ref_type, p_ref_id);
    update public.members set coins = coins + v_coin where id = p_member_id;
  end if;

  if v_tickets > 0 then
    update public.members set draw_tickets = draw_tickets + v_tickets where id = p_member_id;
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
  if s is null then return; end if;
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
--  接进两个充值入口
-- ---------------------------------------------------------------------------
create or replace function public.rpc_complete_recharge(p_order_id text)
returns numeric language plpgsql security definer
set search_path = public
as $$
declare v_member uuid; v_price numeric; v_coins int; v_di jsonb; v_bal numeric;
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

  -- 套餐自带的 Meow Coin
  v_coins := coalesce((v_di->'recharge'->>'coins')::int, 0);
  if v_coins > 0 then
    insert into public.member_coin_ledger(member_id, delta, reason, ref_type, ref_id)
      values (v_member, v_coins, 'recharge_bonus', 'recharge', p_order_id);
    update public.members set coins = coins + v_coins where id = v_member;
  end if;

  -- 储值规则里配的额外奖励（XP / Coin / 抽奖券，含首充加成）
  perform public._wallet_grant_rewards(v_member, v_price, 'recharge', p_order_id);

  select wallet_balance into v_bal from public.members where id = v_member;
  return v_bal;
end; $$;

create or replace function public.rpc_pos_topup(
  p_member_id uuid, p_price numeric, p_bonus_coins int default 0, p_note text default null)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare v_bal numeric; v_ref text;
begin
  if p_price is null or p_price <= 0 then raise exception '充值金额无效'; end if;
  if not exists (select 1 from public.members where id = p_member_id) then
    raise exception '会员不存在';
  end if;

  perform public._wallet_check_limits(p_member_id, p_price);

  -- 柜台充值没有订单号，用一个唯一串当流水引用，首充判断才不会把自己算进去
  v_ref := coalesce(nullif(trim(p_note),''), 'POS 柜台充值') || '#' || gen_random_uuid()::text;

  update public.members
     set wallet_balance = wallet_balance + p_price,
         coins          = coins + greatest(coalesce(p_bonus_coins, 0), 0)
   where id = p_member_id
   returning wallet_balance into v_bal;

  insert into public.member_wallet_ledger(member_id, delta, reason, ref_type, ref_id)
    values (p_member_id, p_price, 'topup', 'pos', v_ref);

  if coalesce(p_bonus_coins, 0) > 0 then
    insert into public.member_coin_ledger(member_id, delta, reason, ref_type, ref_id)
      values (p_member_id, p_bonus_coins, 'topup_bonus', 'pos', v_ref);
  end if;

  perform public._wallet_grant_rewards(p_member_id, p_price, 'pos', v_ref);

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
grant execute on function public.rpc_pos_topup(uuid, numeric, int, text) to anon;
grant execute on function public.rpc_on_order_completed(uuid, text, numeric) to anon;

select pg_notify('pgrst', 'reload schema');

-- 完成。POS「会员运营 → 储值规则」配奖励和限制，充值时服务端照着发、照着拦。
