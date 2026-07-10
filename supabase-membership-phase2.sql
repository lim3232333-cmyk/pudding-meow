-- ============================================================================
--  布丁喵 Meow Club 会员系统 — Phase 2：邀请裂变 · 优惠券中心
--  用法：Supabase Dashboard → SQL Editor → New query → 粘贴全部 → Run
--  依赖 supabase-setup.sql + supabase-membership.sql（Phase 1）已经跑过。
--  只新建本期新增的表；Phase 1 的 members/member_levels 等表不会被 drop，
--  可以放心跑，不会清空已注册的会员数据。
-- ============================================================================

-- ---------- 1) 邀请裂变规则（后台可配置每个阶段奖励多少 XP/Coin）----------
drop table if exists public.referral_rules cascade;
create table public.referral_rules (
  id          uuid primary key default gen_random_uuid(),
  stage       text unique not null,     -- 'register'（好友注册成功）| 'first_order'（好友完成首单）
  name        text not null,
  xp_value    int not null default 0,
  coin_value  int not null default 0,
  enabled     boolean not null default true
);

-- ---------- 2) 邀请关系记录（谁邀请了谁 + 各阶段奖励是否已发放，防止重复发）----------
drop table if exists public.referrals cascade;
create table public.referrals (
  id                  uuid primary key default gen_random_uuid(),
  referrer_id         uuid not null references public.members(id),
  referred_id         uuid not null unique references public.members(id),
  register_rewarded   boolean not null default false,
  first_order_rewarded boolean not null default false,
  created_at          timestamptz not null default now()
);
create index if not exists referrals_referrer_idx on public.referrals (referrer_id);

-- ---------- 3) 优惠券模板（后台「优惠券管理」维护，如 满20减5 / 生日8折）----------
drop table if exists public.coupons cascade;
create table public.coupons (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  type        text not null,                    -- 'fixed_off'（减固定金额）| 'percent_off'（打折，value=20 表示8折/减20%）
  value       numeric not null,
  min_spend   numeric not null default 0,        -- 满多少才能用，0=无门槛
  valid_days  int not null default 30,           -- 发放后多少天内有效
  enabled     boolean not null default true,
  created_at  timestamptz not null default now()
);

-- ---------- 4) 会员实际持有的优惠券（每张券的具体实例）----------
drop table if exists public.member_coupons cascade;
create table public.member_coupons (
  id          uuid primary key default gen_random_uuid(),
  member_id   uuid not null references public.members(id),
  coupon_id   uuid not null references public.coupons(id),
  status      text not null default 'unused',    -- unused | used | expired
  issued_at   timestamptz not null default now(),
  expires_at  timestamptz not null,
  used_at     timestamptz,
  order_id    text
);
create index if not exists member_coupons_member_idx on public.member_coupons (member_id, status);

-- ---------- 5) Row Level Security ----------
-- 规则/券模板是配置类数据，跟 xp_rules/coin_rules 一样先放开给 anon（MVP，POS 无真实店员账号体系）。
alter table public.referral_rules enable row level security;
drop policy if exists referral_rules_anon_read on public.referral_rules;
create policy referral_rules_anon_read on public.referral_rules for select to anon using (true);
drop policy if exists referral_rules_anon_write on public.referral_rules;
create policy referral_rules_anon_write on public.referral_rules for all to anon using (true) with check (true);

alter table public.coupons enable row level security;
drop policy if exists coupons_anon_read on public.coupons;
create policy coupons_anon_read on public.coupons for select to anon using (true);
drop policy if exists coupons_anon_write on public.coupons;
create policy coupons_anon_write on public.coupons for all to anon using (true) with check (true);

-- referrals / member_coupons 涉及具体会员的权益，不给 anon 直接读写权限，一律走下面的 RPC。
alter table public.referrals enable row level security;
alter table public.member_coupons enable row level security;

-- ---------- 6) 内部函数：给邀请人发放某个阶段的奖励 ----------
create or replace function public._grant_referral_stage(p_referrer_id uuid, p_stage text, p_referred_id uuid)
returns void language plpgsql security definer as $$
declare v_rule record;
begin
  select * into v_rule from public.referral_rules where stage = p_stage and enabled = true;
  if v_rule is null then return; end if;
  if v_rule.xp_value <> 0 then
    insert into public.member_xp_ledger(member_id, delta, reason, ref_type, ref_id)
      values (p_referrer_id, v_rule.xp_value, 'referral_'||p_stage, 'referral', p_referred_id::text);
    update public.members set xp = xp + v_rule.xp_value where id = p_referrer_id;
    update public.members set level_id = (
      select id from public.member_levels where xp_required <= (select xp from public.members where id = p_referrer_id)
      order by sort_order desc limit 1
    ) where id = p_referrer_id;
  end if;
  if v_rule.coin_value <> 0 then
    insert into public.member_coin_ledger(member_id, delta, reason, ref_type, ref_id)
      values (p_referrer_id, v_rule.coin_value, 'referral_'||p_stage, 'referral', p_referred_id::text);
    update public.members set coins = coins + v_rule.coin_value where id = p_referrer_id;
  end if;
end; $$;

-- ---------- 7) 改写 Phase 1 的注册函数：支持记录邀请关系 + 发放"好友注册成功"奖励 ----------
create or replace function public.rpc_member_register(p_phone text, p_pin text, p_nickname text default null, p_referral_code text default null)
returns table(member_id uuid, session_token text) language plpgsql security definer as $$
declare v_id uuid; v_token text; v_referrer uuid; v_default_level uuid;
begin
  if p_phone is null or length(trim(p_phone)) < 6 then
    raise exception '请填写有效的手机号';
  end if;
  if p_pin is null or length(p_pin) < 4 then
    raise exception 'PIN 至少 4 位';
  end if;
  if exists (select 1 from public.members where phone = p_phone) then
    raise exception '该手机号已注册，请直接登录';
  end if;
  select id into v_default_level from public.member_levels order by sort_order asc limit 1;
  if p_referral_code is not null and length(trim(p_referral_code)) > 0 then
    select id into v_referrer from public.members where referral_code = upper(p_referral_code);
  end if;
  v_token := encode(gen_random_bytes(24), 'hex');
  insert into public.members (phone, pin_hash, session_token, nickname, level_id, referral_code, referred_by, last_active_at)
  values (p_phone, crypt(p_pin, gen_salt('bf')), v_token, coalesce(nullif(trim(p_nickname),''), '喵星人'), v_default_level, public._gen_referral_code(), v_referrer, now())
  returning id into v_id;
  if v_referrer is not null and v_referrer <> v_id then
    insert into public.referrals(referrer_id, referred_id, register_rewarded) values (v_referrer, v_id, true);
    perform public._grant_referral_stage(v_referrer, 'register', v_id);
  end if;
  return query select v_id, v_token;
end; $$;

-- ---------- 8) 改写 Phase 1 的订单结算函数：完成首单时发放"好友首单"奖励给邀请人 ----------
create or replace function public.rpc_on_order_completed(p_member_id uuid, p_order_id text, p_amount numeric)
returns void language plpgsql security definer as $$
declare v_ref record;
begin
  if p_member_id is null then return; end if;
  perform public._grant_xp(p_member_id, 'purchase_per_rm', 'order', p_order_id, p_amount);
  perform public._grant_coin(p_member_id, 'purchase_per_rm', 'order', p_order_id, p_amount);
  select * into v_ref from public.referrals where referred_id = p_member_id and first_order_rewarded = false;
  if v_ref is not null then
    perform public._grant_referral_stage(v_ref.referrer_id, 'first_order', p_member_id);
    update public.referrals set first_order_rewarded = true where id = v_ref.id;
  end if;
end; $$;

-- ---------- 9) 对外 RPC：会员查看自己的邀请码 + 邀请战绩 ----------
create or replace function public.rpc_get_my_referrals(p_member_id uuid, p_session_token text)
returns table(referral_code text, total_referred int, friends jsonb)
language plpgsql security definer as $$
declare v_code text; v_friends jsonb;
begin
  perform public._auth_member(p_member_id, p_session_token);
  select m.referral_code into v_code from public.members m where m.id = p_member_id;
  select coalesce(jsonb_agg(jsonb_build_object(
      'nickname', fm.nickname,
      'registeredAt', r.created_at,
      'firstOrderDone', r.first_order_rewarded
    ) order by r.created_at desc), '[]'::jsonb) into v_friends
    from public.referrals r join public.members fm on fm.id = r.referred_id
    where r.referrer_id = p_member_id;
  return query select v_code, (select count(*)::int from public.referrals where referrer_id = p_member_id), v_friends;
end; $$;

-- ---------- 10) 对外 RPC：会员查看自己的优惠券钱包（顺带把过期的标记掉）----------
create or replace function public.rpc_get_my_coupons(p_member_id uuid, p_session_token text)
returns table(id uuid, coupon_id uuid, name text, type text, value numeric, min_spend numeric, status text, issued_at timestamptz, expires_at timestamptz)
language plpgsql security definer as $$
begin
  perform public._auth_member(p_member_id, p_session_token);
  update public.member_coupons set status = 'expired'
    where member_id = p_member_id and status = 'unused' and expires_at < now();
  return query select mc.id, mc.coupon_id, c.name, c.type, c.value, c.min_spend, mc.status, mc.issued_at, mc.expires_at
    from public.member_coupons mc join public.coupons c on c.id = mc.coupon_id
    where mc.member_id = p_member_id
    order by (mc.status = 'unused') desc, mc.issued_at desc;
end; $$;

-- ---------- 11) 对外 RPC：POS 后台发券（发给单个会员，或不传 member_id 广播给全体会员）----------
create or replace function public.rpc_admin_issue_coupon(p_coupon_id uuid, p_member_id uuid default null)
returns int language plpgsql security definer as $$
declare v_coupon record; v_count int := 0;
begin
  select * into v_coupon from public.coupons where id = p_coupon_id and enabled = true;
  if v_coupon is null then raise exception '优惠券不存在或已停用'; end if;
  if p_member_id is not null then
    insert into public.member_coupons(member_id, coupon_id, expires_at)
      values (p_member_id, p_coupon_id, now() + (v_coupon.valid_days || ' days')::interval);
    v_count := 1;
  else
    insert into public.member_coupons(member_id, coupon_id, expires_at)
      select id, p_coupon_id, now() + (v_coupon.valid_days || ' days')::interval from public.members;
    get diagnostics v_count = row_count;
  end if;
  return v_count;
end; $$;

-- ---------- 12) 对外 RPC：POS 后台核销会员的某张券（结账时人工核销）----------
create or replace function public.rpc_pos_use_coupon(p_member_coupon_id uuid, p_order_id text default null)
returns void language plpgsql security definer as $$
declare v_row record;
begin
  select * into v_row from public.member_coupons where id = p_member_coupon_id;
  if v_row is null then raise exception '优惠券不存在'; end if;
  if v_row.status <> 'unused' then raise exception '该优惠券已使用或已失效'; end if;
  if v_row.expires_at < now() then
    update public.member_coupons set status = 'expired' where id = p_member_coupon_id;
    raise exception '该优惠券已过期';
  end if;
  update public.member_coupons set status = 'used', used_at = now(), order_id = p_order_id where id = p_member_coupon_id;
end; $$;

-- ---------- 13) 对外 RPC：POS 后台查已发出去的券（搜索会员手机号/昵称）----------
create or replace function public.rpc_admin_list_member_coupons(p_search text default null)
returns table(id uuid, member_id uuid, member_phone text, member_nickname text, coupon_name text, status text, issued_at timestamptz, expires_at timestamptz)
language plpgsql security definer as $$
begin
  update public.member_coupons set status = 'expired' where status = 'unused' and expires_at < now();
  return query select mc.id, mc.member_id, m.phone, m.nickname, c.name, mc.status, mc.issued_at, mc.expires_at
    from public.member_coupons mc
    join public.members m on m.id = mc.member_id
    join public.coupons c on c.id = mc.coupon_id
    where p_search is null or p_search = '' or m.phone ilike '%'||p_search||'%' or m.nickname ilike '%'||p_search||'%'
    order by mc.issued_at desc
    limit 200;
end; $$;

-- ---------- 14) 授权：让 anon 角色可以调用这些 RPC ----------
grant execute on function public.rpc_member_register(text, text, text, text) to anon;
grant execute on function public.rpc_on_order_completed(uuid, text, numeric) to anon;
grant execute on function public.rpc_get_my_referrals(uuid, text) to anon;
grant execute on function public.rpc_get_my_coupons(uuid, text) to anon;
grant execute on function public.rpc_admin_issue_coupon(uuid, uuid) to anon;
grant execute on function public.rpc_pos_use_coupon(uuid, text) to anon;
grant execute on function public.rpc_admin_list_member_coupons(text) to anon;

-- ---------- 15) 开启 Realtime（规则/券模板后台一改，小程序实时刷新）----------
alter publication supabase_realtime add table public.referral_rules;
alter publication supabase_realtime add table public.coupons;

-- ---------- 16) 种子数据：默认邀请奖励规则 + 两张示例优惠券 ----------
insert into public.referral_rules (stage, name, xp_value, coin_value, enabled) values
  ('register',    '好友注册成功', 0,  20, true),
  ('first_order', '好友完成首单', 30, 50, true);

insert into public.coupons (name, type, value, min_spend, valid_days, enabled) values
  ('新人优惠券', 'fixed_off',   5,  20, 30, true),
  ('生日专属券', 'percent_off', 20, 0,  30, true);

-- 完成。小程序「我的」页面会出现"邀请好友"卡片和优惠券钱包；
-- 后台 Loyalty 页面新增"邀请规则"和"优惠券管理"两个子页签。
