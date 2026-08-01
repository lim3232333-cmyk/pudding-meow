-- ============================================================================
--  布丁喵 — 邀请中心 v2：二级邀请 + 好友侧奖励 + 抽奖券，奖励数值搬进后台
--  用法：Supabase Dashboard → SQL Editor → New query → 粘贴 → Run（跑一次）
--  前置：supabase-membership.sql、supabase-membership-phase2.sql、
--        supabase-lucky-draw.sql、supabase-wallet-rules.sql 都已跑过。
--
--  跟旧版的三处不同：
--   ① 奖励在「好友完成首单」那一刻一次性结算，注册当下不发。
--      邀请步骤图上写得很清楚：分享 → 注册 → 首单 → 才获得奖励。
--      注册就发的话，注册一堆空号就能刷奖励。
--   ② 一次结算发三份：邀请人、好友自己、邀请人的邀请人（二级）。
--   ③ 数值不再写死在 referral_rules 的两个阶段里，改成 referral_settings 一行，
--      POS「会员运营 → 邀请规则」维护，小程序的「邀请奖励」弹窗直接读这张表——
--      这样弹窗上写的和实际发的永远是同一组数，不会各说各话。
--
--  旧的 referral_rules 表不删（万一你还想看历史配置），但新流程不再读它。
-- ============================================================================

-- ---------------------------------------------------------------------------
--  1) 奖励数值（单行表）。种子就是设计稿弹窗上那组数。
-- ---------------------------------------------------------------------------
create table if not exists public.referral_settings (
  id                 int primary key default 1,
  l1_inviter_coins   int not null default 100,  -- 直推：邀请人拿多少 Paw Coin
  l1_inviter_xp      int not null default 100,  -- 直推：邀请人拿多少 XP
  l1_inviter_tickets int not null default 1,    -- 直推：邀请人拿几次幸运抽奖
  l1_invitee_coins   int not null default 50,   -- 直推：好友自己拿多少 Coin
  l1_invitee_xp      int not null default 50,   -- 直推：好友自己拿多少 XP
  l2_inviter_coins   int not null default 20,   -- 二级：邀请人的邀请人拿多少 Coin
  l2_inviter_xp      int not null default 20,   -- 二级：邀请人的邀请人拿多少 XP
  enabled            boolean not null default true,
  updated_at         timestamptz not null default now(),
  constraint referral_settings_single_row check (id = 1)
);
insert into public.referral_settings (id) values (1) on conflict (id) do nothing;

alter table public.referral_settings enable row level security;
drop policy if exists referral_settings_anon_read on public.referral_settings;
create policy referral_settings_anon_read on public.referral_settings for select to anon using (true);
drop policy if exists referral_settings_anon_write on public.referral_settings;
create policy referral_settings_anon_write on public.referral_settings for all to anon using (true) with check (true);

do $$
begin
  alter publication supabase_realtime add table public.referral_settings;
exception when duplicate_object then null;
end $$;

-- ---------------------------------------------------------------------------
--  2) 发奖：Coin / XP / 抽奖券各写各的流水，XP 涨了顺带重算等级
--     跟 _wallet_grant_rewards 长得像，但那个把 reason 写死成 'recharge'，
--     邀请奖励用它会在流水里显示成充值。宁可多一个函数，也不改那个的签名
--     （加默认参数会变成重载，PostgREST 调用时会报函数不明确）。
-- ---------------------------------------------------------------------------
create or replace function public._referral_grant(
  p_member_id uuid, p_coins int, p_xp int, p_tickets int, p_reason text, p_ref_id text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_member_id is null then return; end if;

  if coalesce(p_coins,0) > 0 then
    insert into public.member_coin_ledger(member_id, delta, reason, ref_type, ref_id)
      values (p_member_id, p_coins, p_reason, 'referral', p_ref_id);
    update public.members set coins = coins + p_coins where id = p_member_id;
  end if;

  if coalesce(p_xp,0) > 0 then
    insert into public.member_xp_ledger(member_id, delta, reason, ref_type, ref_id)
      values (p_member_id, p_xp, p_reason, 'referral', p_ref_id);
    update public.members set xp = xp + p_xp where id = p_member_id;
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

-- ---------------------------------------------------------------------------
--  3) 好友完成首单 → 一次性结算三份奖励
--     first_order_rewarded 当幂等锁：先抢着置位，抢不到就直接返回，
--     所以 webhook 重发、店员多点几次「已付款」都不会重复发。
-- ---------------------------------------------------------------------------
create or replace function public._referral_payout(p_invitee uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare s record; v_ref record; v_l2 uuid;
begin
  if p_invitee is null then return; end if;

  select * into s from public.referral_settings where id = 1;
  if not found or s.enabled is false then return; end if;

  -- 判「查到没有」一律用 found。record 的 IS NOT NULL 是「每个字段都非空」才成立，
  -- 这张表里 created_at 之外的布尔字段就算有值也未必都非空，写 IS NOT NULL 会误判。
  update public.referrals set first_order_rewarded = true
   where referred_id = p_invitee and first_order_rewarded = false
   returning * into v_ref;
  if not found then return; end if;

  -- ① 直推：邀请人
  perform public._referral_grant(v_ref.referrer_id,
    s.l1_inviter_coins, s.l1_inviter_xp, s.l1_inviter_tickets, 'referral_l1', p_invitee::text);

  -- ② 好友自己（旧版没有这一份）
  perform public._referral_grant(p_invitee,
    s.l1_invitee_coins, s.l1_invitee_xp, 0, 'referral_welcome', p_invitee::text);

  -- ③ 二级：邀请人的邀请人。members.referred_by 本来就记了上线，不用另建表
  select referred_by into v_l2 from public.members where id = v_ref.referrer_id;
  if v_l2 is not null and v_l2 <> p_invitee and v_l2 <> v_ref.referrer_id then
    perform public._referral_grant(v_l2,
      s.l2_inviter_coins, s.l2_inviter_xp, 0, 'referral_l2', p_invitee::text);
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
--  4) 注册：只记邀请关系，不发奖（奖励挪到首单）
-- ---------------------------------------------------------------------------
create or replace function public.rpc_member_register(
  p_phone text, p_pin text, p_nickname text default null, p_referral_code text default null)
returns table(member_id uuid, session_token text)
language plpgsql security definer
set search_path = public
as $$
declare v_id uuid; v_token text; v_referrer uuid; v_default_level uuid;
begin
  if p_phone is null or length(trim(p_phone)) < 6 then raise exception '请填写有效的手机号'; end if;
  if p_pin is null or length(p_pin) < 4 then raise exception 'PIN 至少 4 位'; end if;
  if exists (select 1 from public.members where phone = p_phone) then
    raise exception '该手机号已注册，请直接登录';
  end if;
  select id into v_default_level from public.member_levels order by sort_order asc limit 1;
  if p_referral_code is not null and length(trim(p_referral_code)) > 0 then
    select id into v_referrer from public.members where referral_code = upper(trim(p_referral_code));
  end if;
  v_token := encode(gen_random_bytes(24), 'hex');
  insert into public.members (phone, pin_hash, session_token, nickname, level_id, referral_code, referred_by, last_active_at)
  values (p_phone, crypt(p_pin, gen_salt('bf')), v_token,
          coalesce(nullif(trim(p_nickname),''), '喵星人'), v_default_level,
          public._gen_referral_code(), v_referrer, now())
  returning id into v_id;
  if v_referrer is not null and v_referrer <> v_id then
    insert into public.referrals(referrer_id, referred_id) values (v_referrer, v_id);
  end if;
  return query select v_id, v_token;
end;
$$;

-- ---------------------------------------------------------------------------
--  5) 订单完成：消费奖励 + 邀请结算
--     ⚠️ supabase-wallet-rules.sql 那一版重写这个函数时把邀请那段弄丢了，
--        等于「好友完成首单」的奖励一直没发。这里补回来，别再漏。
-- ---------------------------------------------------------------------------
create or replace function public.rpc_on_order_completed(p_member_id uuid, p_order_id text, p_amount numeric)
returns void
language plpgsql security definer
set search_path = public
as $$
declare v_pay text; v_earns boolean;
begin
  if p_member_id is null then return; end if;

  -- 「用余额付款还累不累积 XP/Coin」由服务端自己去 orders 查，不听前端传什么
  select pay_method into v_pay from public.orders where id = p_order_id;
  if v_pay = 'wallet' then
    select wallet_earns into v_earns from public.wallet_settings where id = 1;
    if v_earns is false then
      perform public._referral_payout(p_member_id);   -- 消费奖励不发，邀请照结
      return;
    end if;
  end if;

  -- 同一单只结一次消费奖励。邀请那边有 first_order_rewarded 当锁，消费这边一直没有锁——
  -- webhook 重发、店员多点几次「已付款」，Coin/XP 就发两遍。拿流水当凭据补上。
  if not exists (select 1 from public.member_coin_ledger cl
                  where cl.member_id = p_member_id and cl.ref_type = 'order' and cl.ref_id = p_order_id)
     and not exists (select 1 from public.member_xp_ledger xl
                  where xl.member_id = p_member_id and xl.ref_type = 'order' and xl.ref_id = p_order_id)
  then
    perform public._grant_xp(p_member_id, 'purchase_per_rm', 'order', p_order_id, p_amount);
    perform public._grant_coin(p_member_id, 'purchase_per_rm', 'order', p_order_id, p_amount);
  end if;

  perform public._referral_payout(p_member_id);
end;
$$;

-- ---------------------------------------------------------------------------
--  6) 邀请中心要的数据，一个 RPC 全给（Figma 645:796）
--     返回列名和表列名撞了会 42702 ambiguous，所以 OUT 参数一律加 out_ 前缀。
-- ---------------------------------------------------------------------------
drop function if exists public.rpc_get_my_referral(uuid, text);
create or replace function public.rpc_get_my_referral(p_member_id uuid, p_session_token text)
returns table(out_code text, out_nickname text, out_l1 int, out_l2 int,
              out_coins int, out_xp int, out_friends jsonb)
language plpgsql security definer
set search_path = public
as $$
begin
  perform public._auth_member(p_member_id, p_session_token);
  return query
  select
    m.referral_code,
    m.nickname,
    -- 直推：我直接邀请的
    (select count(*)::int from public.members d where d.referred_by = p_member_id),
    -- 二级：我直推的人各自又邀请了谁
    (select count(*)::int from public.members g
      where g.referred_by in (select d2.id from public.members d2 where d2.referred_by = p_member_id)),
    -- 累计获得：所有 ref_type='referral' 的流水（直推/二级/好友礼都算我头上的那几笔）
    coalesce((select sum(cl.delta)::int from public.member_coin_ledger cl
               where cl.member_id = p_member_id and cl.ref_type = 'referral'), 0),
    coalesce((select sum(xl.delta)::int from public.member_xp_ledger xl
               where xl.member_id = p_member_id and xl.ref_type = 'referral'), 0),
    coalesce((select jsonb_agg(jsonb_build_object(
        'nickname', fm.nickname,
        'registeredAt', r.created_at,
        'firstOrderDone', r.first_order_rewarded
      ) order by r.created_at desc)
      from public.referrals r join public.members fm on fm.id = r.referred_id
      where r.referrer_id = p_member_id), '[]'::jsonb)
  from public.members m where m.id = p_member_id;
end;
$$;

grant execute on function public.rpc_member_register(text, text, text, text) to anon;
grant execute on function public.rpc_on_order_completed(uuid, text, numeric) to anon;
grant execute on function public.rpc_get_my_referral(uuid, text) to anon;

select pg_notify('pgrst', 'reload schema');

-- 完成。POS「会员运营 → 邀请规则」改数值，小程序邀请中心的弹窗和实际发放同时跟着变。
