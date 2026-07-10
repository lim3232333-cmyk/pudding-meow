-- ============================================================================
--  布丁喵 Meow Club 会员系统 — Phase 1：身份 · 等级 · 成长值 · Meow Coin · 每日签到
--  用法：Supabase Dashboard → SQL Editor → New query → 粘贴全部 → Run
--  依赖 supabase-setup.sql 已经跑过（用到 public.menu_items / public.orders）。
--  可安全重复运行（幂等：drop table 再重建）——⚠️ 重复运行会清空已注册的会员数据，
--  上线稳定后若要保留会员数据，请勿重跑第 1-6 节，只追加新内容。
--
--  登录方式：手机号 + 自设 PIN（不接短信验证码，避免短信费用；PIN 用 bcrypt 哈希存储，
--  不存明文）。会员写操作（签到/兑换等）一律走下面的 RPC 函数校验身份，不直接开放
--  members 表给前端写入——因为这里面是真金白银的余额，不能像 menu_items 那样直接放开。
-- ============================================================================

create extension if not exists pgcrypto;

-- ---------- 1) 会员主表 ----------
drop table if exists public.members cascade;
create table public.members (
  id             uuid primary key default gen_random_uuid(),
  phone          text unique not null,
  pin_hash       text not null,                    -- crypt(pin, gen_salt('bf'))，不存明文
  session_token  text,                              -- 登录后签发；写操作 RPC 用它校验身份
  nickname       text,
  avatar_url     text,
  level_id       uuid,                              -- 外键在 member_levels 建好后再加
  xp             int not null default 0,
  coins          int not null default 0,
  draw_tickets   int not null default 0,             -- 抽奖券余量（Phase 3 用，先建好字段）
  referral_code  text unique not null,               -- Phase 2 邀请裂变用，Phase 1 先生成好
  referred_by    uuid references public.members(id),
  birthday       date,
  created_at     timestamptz not null default now(),
  last_active_at timestamptz
);
create index if not exists members_phone_idx on public.members (phone);

-- ---------- 2) 等级配置（后台"会员等级"页可自由增删改）----------
drop table if exists public.member_levels cascade;
create table public.member_levels (
  id            uuid primary key default gen_random_uuid(),
  name_cn       text not null,
  name_en       text,
  sort_order    int not null,
  xp_required   int not null,
  color_hex     text not null default '#8D0505',
  badge_icon    text,                                -- emoji 或图标名
  perks         jsonb not null default '[]'::jsonb,  -- ["生日月双倍金币","每月8折券",...]
  birthday_coupon_id uuid                             -- Phase 2 优惠券表建好后再加外键
);
alter table public.members
  add constraint members_level_fk foreign key (level_id) references public.member_levels(id);
create index if not exists member_levels_sort_idx on public.member_levels (sort_order);

-- ---------- 3) 成长值 / 金币规则（后台可自由增删改，新增行为无需改代码）----------
drop table if exists public.xp_rules cascade;
create table public.xp_rules (
  id          uuid primary key default gen_random_uuid(),
  action_key  text unique not null,   -- 'purchase_per_rm' | 'checkin' | 'review' | 'photo_review' | 'birthday_order' ...
  name        text not null,
  xp_value    numeric not null,
  daily_cap   int,                    -- null = 不限
  enabled     boolean not null default true
);
drop table if exists public.coin_rules cascade;
create table public.coin_rules (
  id          uuid primary key default gen_random_uuid(),
  action_key  text unique not null,
  name        text not null,
  coin_value  numeric not null,
  daily_cap   int,
  enabled     boolean not null default true
);

-- ---------- 4) 流水账（个人中心"成长纪录"/"金币纪录"读这两张表）----------
drop table if exists public.member_xp_ledger cascade;
create table public.member_xp_ledger (
  id bigint generated always as identity primary key,
  member_id uuid not null references public.members(id),
  delta int not null,
  reason text not null,             -- 对应 xp_rules.action_key，或 'admin_adjust'/'checkin_milestone'
  ref_type text, ref_id text,       -- 关联订单号等来源
  created_at timestamptz not null default now()
);
drop table if exists public.member_coin_ledger cascade;
create table public.member_coin_ledger (
  id bigint generated always as identity primary key,
  member_id uuid not null references public.members(id),
  delta int not null,
  reason text not null,
  ref_type text, ref_id text,
  created_at timestamptz not null default now()
);
create index if not exists xp_ledger_member_idx on public.member_xp_ledger (member_id, created_at desc);
create index if not exists coin_ledger_member_idx on public.member_coin_ledger (member_id, created_at desc);

-- ---------- 5) 每日签到 ----------
drop table if exists public.checkins cascade;
create table public.checkins (
  member_id uuid not null references public.members(id),
  checkin_date date not null,
  streak_count int not null,
  primary key (member_id, checkin_date)
);
drop table if exists public.checkin_milestones cascade;
create table public.checkin_milestones (
  id uuid primary key default gen_random_uuid(),
  streak_days int unique not null,       -- 7 / 14 / 30
  reward jsonb not null                  -- {"coin":50,"xp":0}
);

-- ---------- 6) Row Level Security ----------
-- members / 流水 / 签到：不给 anon 任何直接读写权限——全部必须经过下面的 security definer
-- RPC 函数（函数内部会校验 session_token）。这样即使 anon key 是公开的，前端也没办法
-- 直接对着 members 表 update 金币/改等级。
alter table public.members enable row level security;
alter table public.member_xp_ledger enable row level security;
alter table public.member_coin_ledger enable row level security;
alter table public.checkins enable row level security;
-- 有意不建 anon policy：默认拒绝所有直接访问。

-- 配置类表（等级/规则/签到里程碑）：不含个人数据，anon 可读；写权限跟现有 menu_items
-- 一样先放开给 anon（POS 目前只有本机 PIN、无真实店员账号体系，属于已知 MVP 限制）。
alter table public.member_levels enable row level security;
alter table public.xp_rules enable row level security;
alter table public.coin_rules enable row level security;
alter table public.checkin_milestones enable row level security;

drop policy if exists member_levels_anon_read on public.member_levels;
create policy member_levels_anon_read on public.member_levels for select to anon using (true);
drop policy if exists member_levels_anon_write on public.member_levels;
create policy member_levels_anon_write on public.member_levels for all to anon using (true) with check (true);

drop policy if exists xp_rules_anon_read on public.xp_rules;
create policy xp_rules_anon_read on public.xp_rules for select to anon using (true);
drop policy if exists xp_rules_anon_write on public.xp_rules;
create policy xp_rules_anon_write on public.xp_rules for all to anon using (true) with check (true);

drop policy if exists coin_rules_anon_read on public.coin_rules;
create policy coin_rules_anon_read on public.coin_rules for select to anon using (true);
drop policy if exists coin_rules_anon_write on public.coin_rules;
create policy coin_rules_anon_write on public.coin_rules for all to anon using (true) with check (true);

drop policy if exists checkin_milestones_anon_read on public.checkin_milestones;
create policy checkin_milestones_anon_read on public.checkin_milestones for select to anon using (true);
drop policy if exists checkin_milestones_anon_write on public.checkin_milestones;
create policy checkin_milestones_anon_write on public.checkin_milestones for all to anon using (true) with check (true);

-- ---------- 7) 内部小工具函数 ----------
create or replace function public._gen_referral_code() returns text
language plpgsql as $$
declare code text;
begin
  loop
    code := upper(substr(md5(random()::text || clock_timestamp()::text), 1, 6));
    exit when not exists (select 1 from public.members where referral_code = code);
  end loop;
  return code;
end; $$;

create or replace function public._auth_member(p_member_id uuid, p_session_token text) returns void
language plpgsql as $$
begin
  if p_member_id is null or p_session_token is null or not exists (
    select 1 from public.members where id = p_member_id and session_token = p_session_token
  ) then
    raise exception '登录状态无效，请重新登录';
  end if;
end; $$;

-- 发放 XP：查规则、校验当日上限、写流水、加余额、检查是否需要升级
-- p_multiplier：一般传 1；消费场景传订单金额（因为 xp_value 语义是"每 RM1 多少 XP"）
create or replace function public._grant_xp(p_member_id uuid, p_action_key text, p_ref_type text default null, p_ref_id text default null, p_multiplier numeric default 1)
returns int language plpgsql security definer as $$
declare v_rule record; v_today_total numeric; v_amount int;
begin
  select * into v_rule from public.xp_rules where action_key = p_action_key and enabled = true;
  if v_rule is null then return 0; end if;
  if v_rule.daily_cap is not null then
    select coalesce(sum(delta),0) into v_today_total from public.member_xp_ledger
      where member_id = p_member_id and reason = p_action_key and created_at::date = current_date;
    if v_today_total >= v_rule.daily_cap then return 0; end if;
  end if;
  v_amount := round(v_rule.xp_value * p_multiplier);
  if v_amount = 0 then return 0; end if;
  insert into public.member_xp_ledger(member_id, delta, reason, ref_type, ref_id) values (p_member_id, v_amount, p_action_key, p_ref_type, p_ref_id);
  update public.members set xp = xp + v_amount where id = p_member_id;
  update public.members set level_id = (
    select id from public.member_levels where xp_required <= (select xp from public.members where id = p_member_id)
    order by sort_order desc limit 1
  ) where id = p_member_id;
  return v_amount;
end; $$;

-- 发放 Coin：结构同上（不涉及升级判断）
create or replace function public._grant_coin(p_member_id uuid, p_action_key text, p_ref_type text default null, p_ref_id text default null, p_multiplier numeric default 1)
returns int language plpgsql security definer as $$
declare v_rule record; v_today_total numeric; v_amount int;
begin
  select * into v_rule from public.coin_rules where action_key = p_action_key and enabled = true;
  if v_rule is null then return 0; end if;
  if v_rule.daily_cap is not null then
    select coalesce(sum(delta),0) into v_today_total from public.member_coin_ledger
      where member_id = p_member_id and reason = p_action_key and created_at::date = current_date;
    if v_today_total >= v_rule.daily_cap then return 0; end if;
  end if;
  v_amount := round(v_rule.coin_value * p_multiplier);
  if v_amount = 0 then return 0; end if;
  insert into public.member_coin_ledger(member_id, delta, reason, ref_type, ref_id) values (p_member_id, v_amount, p_action_key, p_ref_type, p_ref_id);
  update public.members set coins = coins + v_amount where id = p_member_id;
  return v_amount;
end; $$;

-- ---------- 8) 对外 RPC：注册 / 登录 / 资料 ----------
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
  return query select v_id, v_token;
end; $$;

create or replace function public.rpc_member_login(p_phone text, p_pin text)
returns table(member_id uuid, session_token text) language plpgsql security definer as $$
declare v_id uuid; v_hash text; v_token text;
begin
  select id, pin_hash into v_id, v_hash from public.members where phone = p_phone;
  if v_id is null or crypt(p_pin, v_hash) <> v_hash then
    raise exception '手机号或 PIN 不正确';
  end if;
  v_token := encode(gen_random_bytes(24), 'hex');
  update public.members set session_token = v_token, last_active_at = now() where id = v_id;
  return query select v_id, v_token;
end; $$;

create or replace function public.rpc_get_my_profile(p_member_id uuid, p_session_token text)
returns table(id uuid, phone text, nickname text, avatar_url text, level_id uuid, xp int, coins int,
              draw_tickets int, referral_code text, birthday date, created_at timestamptz)
language plpgsql security definer as $$
begin
  perform public._auth_member(p_member_id, p_session_token);
  return query select m.id, m.phone, m.nickname, m.avatar_url, m.level_id, m.xp, m.coins,
                      m.draw_tickets, m.referral_code, m.birthday, m.created_at
               from public.members m where m.id = p_member_id;
end; $$;

create or replace function public.rpc_update_my_profile(p_member_id uuid, p_session_token text, p_nickname text default null, p_avatar_url text default null, p_birthday date default null)
returns void language plpgsql security definer as $$
begin
  perform public._auth_member(p_member_id, p_session_token);
  update public.members set
    nickname = coalesce(nullif(trim(p_nickname),''), nickname),
    avatar_url = coalesce(p_avatar_url, avatar_url),
    birthday = coalesce(p_birthday, birthday)
  where id = p_member_id;
end; $$;

-- ---------- 9) 对外 RPC：每日签到 ----------
create or replace function public.rpc_get_checkin_status(p_member_id uuid, p_session_token text)
returns table(checked_in_today boolean, current_streak int, last_7_days jsonb)
language plpgsql security definer as $$
declare v_checked boolean; v_streak int; v_days jsonb;
begin
  perform public._auth_member(p_member_id, p_session_token);
  select true, c.streak_count into v_checked, v_streak from public.checkins c
    where c.member_id = p_member_id and c.checkin_date = current_date;
  if v_checked is null then
    v_checked := false;
    select c.streak_count into v_streak from public.checkins c
      where c.member_id = p_member_id and c.checkin_date = current_date - 1;
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('date', d::date, 'checked', exists(
      select 1 from public.checkins c where c.member_id = p_member_id and c.checkin_date = d::date
    )) order by d), '[]'::jsonb) into v_days
    from generate_series(current_date - 6, current_date, interval '1 day') d;
  return query select v_checked, coalesce(v_streak, 0), v_days;
end; $$;

create or replace function public.rpc_daily_checkin(p_member_id uuid, p_session_token text)
returns table(streak_count int, coin_awarded int, xp_awarded int, milestone jsonb)
language plpgsql security definer as $$
declare v_yesterday_streak int; v_streak int; v_milestone record; v_coin int; v_xp int;
begin
  perform public._auth_member(p_member_id, p_session_token);
  if exists (select 1 from public.checkins where member_id = p_member_id and checkin_date = current_date) then
    raise exception '今天已经签到过了';
  end if;
  select c.streak_count into v_yesterday_streak from public.checkins c
    where c.member_id = p_member_id and c.checkin_date = current_date - 1;
  v_streak := coalesce(v_yesterday_streak, 0) + 1;
  insert into public.checkins(member_id, checkin_date, streak_count) values (p_member_id, current_date, v_streak);
  v_xp := public._grant_xp(p_member_id, 'checkin');
  v_coin := public._grant_coin(p_member_id, 'checkin');
  select * into v_milestone from public.checkin_milestones where streak_days = v_streak;
  if v_milestone is not null then
    if (v_milestone.reward->>'coin') is not null and (v_milestone.reward->>'coin')::int <> 0 then
      insert into public.member_coin_ledger(member_id, delta, reason) values (p_member_id, (v_milestone.reward->>'coin')::int, 'checkin_milestone');
      update public.members set coins = coins + (v_milestone.reward->>'coin')::int where id = p_member_id;
      v_coin := v_coin + (v_milestone.reward->>'coin')::int;
    end if;
    if (v_milestone.reward->>'xp') is not null and (v_milestone.reward->>'xp')::int <> 0 then
      insert into public.member_xp_ledger(member_id, delta, reason) values (p_member_id, (v_milestone.reward->>'xp')::int, 'checkin_milestone');
      update public.members set xp = xp + (v_milestone.reward->>'xp')::int where id = p_member_id;
      v_xp := v_xp + (v_milestone.reward->>'xp')::int;
    end if;
  end if;
  return query select v_streak, v_coin, v_xp, v_milestone.reward;
end; $$;

-- ---------- 9b) 订单挂钩会员：给 orders 表加 member_id，方便结算消费 XP/Coin、以后统计消费分析 ----------
alter table public.orders add column if not exists member_id uuid references public.members(id);
create index if not exists orders_member_idx on public.orders (member_id);

-- ---------- 10) 对外 RPC：订单完成结算消费 XP/Coin ----------
-- POS 标记「已付款」、小程序 TNG 支付成功时调用（订单里已经有 member_id 就传，没有就传 null 直接跳过）
create or replace function public.rpc_on_order_completed(p_member_id uuid, p_order_id text, p_amount numeric)
returns void language plpgsql security definer as $$
begin
  if p_member_id is null then return; end if;
  perform public._grant_xp(p_member_id, 'purchase_per_rm', 'order', p_order_id, p_amount);
  perform public._grant_coin(p_member_id, 'purchase_per_rm', 'order', p_order_id, p_amount);
end; $$;

-- ---------- 10b) 对外 RPC：POS 后台用（查会员列表 / 人工调整余额）----------
-- POS 目前没有真正的店员账号体系（只有本机 PIN），跟 menu_items 现有的 MVP 尺度一致：
-- 这两个 RPC 对 anon 开放，但只返回/只影响余额相关字段，不会泄露 pin_hash/session_token。
create or replace function public.rpc_admin_list_members(p_search text default null)
returns table(id uuid, phone text, nickname text, level_id uuid, xp int, coins int, created_at timestamptz, last_active_at timestamptz)
language plpgsql security definer as $$
begin
  return query select m.id, m.phone, m.nickname, m.level_id, m.xp, m.coins, m.created_at, m.last_active_at
    from public.members m
    where p_search is null or p_search = '' or m.phone ilike '%'||p_search||'%' or m.nickname ilike '%'||p_search||'%'
    order by m.created_at desc
    limit 200;
end; $$;

create or replace function public.rpc_admin_adjust_balance(p_member_id uuid, p_xp_delta int, p_coin_delta int, p_reason text default null)
returns void language plpgsql security definer as $$
begin
  if p_xp_delta is not null and p_xp_delta <> 0 then
    insert into public.member_xp_ledger(member_id, delta, reason) values (p_member_id, p_xp_delta, coalesce(nullif(trim(p_reason),''),'admin_adjust'));
    update public.members set xp = xp + p_xp_delta where id = p_member_id;
    update public.members set level_id = (
      select id from public.member_levels where xp_required <= (select xp from public.members where id = p_member_id)
      order by sort_order desc limit 1
    ) where id = p_member_id;
  end if;
  if p_coin_delta is not null and p_coin_delta <> 0 then
    insert into public.member_coin_ledger(member_id, delta, reason) values (p_member_id, p_coin_delta, coalesce(nullif(trim(p_reason),''),'admin_adjust'));
    update public.members set coins = coins + p_coin_delta where id = p_member_id;
  end if;
end; $$;

-- ---------- 11) 授权：让 anon 角色可以调用这些 RPC ----------
grant execute on function public.rpc_member_register(text, text, text, text) to anon;
grant execute on function public.rpc_member_login(text, text) to anon;
grant execute on function public.rpc_get_my_profile(uuid, text) to anon;
grant execute on function public.rpc_update_my_profile(uuid, text, text, text, date) to anon;
grant execute on function public.rpc_get_checkin_status(uuid, text) to anon;
grant execute on function public.rpc_daily_checkin(uuid, text) to anon;
grant execute on function public.rpc_on_order_completed(uuid, text, numeric) to anon;
grant execute on function public.rpc_admin_list_members(text) to anon;
grant execute on function public.rpc_admin_adjust_balance(uuid, int, int, text) to anon;

-- ---------- 12) 开启 Realtime（等级/规则改动后台一改，小程序实时刷新）----------
alter publication supabase_realtime add table public.member_levels;
alter publication supabase_realtime add table public.xp_rules;
alter publication supabase_realtime add table public.coin_rules;
alter publication supabase_realtime add table public.checkin_milestones;

-- ---------- 13) 种子数据：五级等级（养猫主题：从小猫到成年猫）+ XP/Coin 规则 + 签到里程碑 ----------
insert into public.member_levels (name_cn, name_en, sort_order, xp_required, color_hex, badge_icon, perks) values
  ('新生小猫', 'Newborn Kitten', 0, 0,    '#C9B29B', '🐾', '["注册即得","生日提醒订阅"]'::jsonb),
  ('奶猫',     'Milk Kitten',    1, 200,  '#D99A5B', '🐱', '["生日月双倍 Meow Coin","每月1张8折券"]'::jsonb),
  ('幼猫',     'Young Cat',      2, 800,  '#B8703A', '😺', '["图鉴收集奖励 +50%","新品优先购"]'::jsonb),
  ('少年猫',   'Junior Cat',     3, 2000, '#6B4530', '🐈', '["专属客服备注","生日免单一份甜品"]'::jsonb),
  ('成年猫',   'Adult Cat',      4, 5000, '#B8933F', '🐈‍⬛', '["隐藏菜单解锁","年度回馈礼盒"]'::jsonb);

insert into public.xp_rules (action_key, name, xp_value, daily_cap, enabled) values
  ('purchase_per_rm', '消费（每 RM1）', 1, null, true),
  ('checkin',         '每日签到',        5, 5,    true),
  ('review',          '订单评价',        15, 45,  true),
  ('photo_review',    '晒图评价',        25, 50,  true),
  ('birthday_order',  '生日月首单',      100, 100, true);

insert into public.coin_rules (action_key, name, coin_value, daily_cap, enabled) values
  ('purchase_per_rm', '消费（每 RM1）', 1, null, true),
  ('checkin',         '每日签到',        2, 2,   true),
  ('share',           '分享小程序',      5, 15,  true),
  ('review',          '订单评价',        10, 30, true);

insert into public.checkin_milestones (streak_days, reward) values
  (7,  '{"coin":50,"xp":0}'::jsonb),
  (14, '{"coin":120,"xp":0}'::jsonb),
  (30, '{"coin":300,"xp":0}'::jsonb);

-- 完成。回到小程序刷新即可看到「我的」会员入口；后台「会员管理」页可以改等级/规则/签到奖励。

-- ---------- 14) 如果之前已经跑过一次本文件（等级已经是布丁主题的旧数据），
--              只想把等级改成养猫主题、不想清空已注册会员，单独跑下面这段即可 ----------
-- update public.member_levels set name_cn='新生小猫', name_en='Newborn Kitten', color_hex='#C9B29B', badge_icon='🐾' where sort_order=0;
-- update public.member_levels set name_cn='奶猫',     name_en='Milk Kitten',    color_hex='#D99A5B', badge_icon='🐱' where sort_order=1;
-- update public.member_levels set name_cn='幼猫',     name_en='Young Cat',      color_hex='#B8703A', badge_icon='😺' where sort_order=2;
-- update public.member_levels set name_cn='少年猫',   name_en='Junior Cat',     color_hex='#6B4530', badge_icon='🐈' where sort_order=3;
-- update public.member_levels set name_cn='成年猫',   name_en='Adult Cat',      color_hex='#B8933F', badge_icon='🐈‍⬛' where sort_order=4;
