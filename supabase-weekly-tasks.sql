-- ============================================================================
--  布丁喵 — 每周任务（Figma 227:126）
--  用法：Supabase Dashboard → SQL Editor → New query → 粘贴 → Run（跑一次）
--  前置：supabase-membership.sql、supabase-business-day.sql 已跑过。
--
--  三项任务（数量和目标值都能在 POS 改）：连续签到 N 天 / 消费 N 次 / 累计消费 RM N。
--  三项全做完 → 发一份奖励（Coin / XP / 抽奖券，也在 POS 设）。
--  不是每项各发一份——稿子上只有一个总进度百分比，没有逐项的领取标记。
--
--  「本周」按营业日算周一到周日：凌晨 2 点那单属于前一天，自然也属于前一天所在的那周。
--  跟 Transaction 看板同一个口径，不然店家会看到「这周消费 2 次」和交易明细对不上。
-- ============================================================================

-- ---------------------------------------------------------------------------
--  1) 任务本身
-- ---------------------------------------------------------------------------
create table if not exists public.weekly_tasks (
  id         uuid primary key default gen_random_uuid(),
  code       text not null,          -- checkin_streak（本周内连续签到天数）| order_count（完成单数）| spend_amount（消费额 RM）
  name       text not null,          -- 顾客看到的文案，如「连续签到 7 天」
  target     numeric not null,
  enabled    boolean not null default true,
  sort_order int not null default 0,
  created_at timestamptz not null default now(),
  constraint weekly_tasks_code_chk check (code in ('checkin_streak','order_count','spend_amount'))
);
create index if not exists weekly_tasks_sort_idx on public.weekly_tasks (sort_order);

insert into public.weekly_tasks (code, name, target, sort_order)
select * from (values
  ('checkin_streak', '连续签到 7 天',  7::numeric, 10),
  ('order_count',    '消费 2 次',      2::numeric, 20),
  ('spend_amount',   '累计消费 RM50', 50::numeric, 30)
) as v(code, name, target, sort_order)
where not exists (select 1 from public.weekly_tasks);

-- ---------------------------------------------------------------------------
--  2) 全部完成后发什么（单行表）
-- ---------------------------------------------------------------------------
create table if not exists public.weekly_task_settings (
  id           int primary key default 1,
  coins        int not null default 50,
  xp           int not null default 50,
  draw_tickets int not null default 0,
  enabled      boolean not null default true,
  updated_at   timestamptz not null default now(),
  constraint weekly_task_settings_single_row check (id = 1)
);
insert into public.weekly_task_settings (id) values (1) on conflict (id) do nothing;

-- 已经发过的周（member_id + 周一那天为主键，天然防重复发）
create table if not exists public.member_weekly_rewards (
  member_id  uuid not null references public.members(id),
  week_start date not null,
  coins      int not null default 0,
  xp         int not null default 0,
  tickets    int not null default 0,
  granted_at timestamptz not null default now(),
  primary key (member_id, week_start)
);

alter table public.weekly_tasks enable row level security;
drop policy if exists weekly_tasks_anon_read on public.weekly_tasks;
create policy weekly_tasks_anon_read on public.weekly_tasks for select to anon using (true);
drop policy if exists weekly_tasks_anon_write on public.weekly_tasks;
create policy weekly_tasks_anon_write on public.weekly_tasks for all to anon using (true) with check (true);

alter table public.weekly_task_settings enable row level security;
drop policy if exists weekly_task_settings_anon_read on public.weekly_task_settings;
create policy weekly_task_settings_anon_read on public.weekly_task_settings for select to anon using (true);
drop policy if exists weekly_task_settings_anon_write on public.weekly_task_settings;
create policy weekly_task_settings_anon_write on public.weekly_task_settings for all to anon using (true) with check (true);

-- 谁完成了哪周是会员个人数据，不给 anon 直接读，一律走下面的 RPC
alter table public.member_weekly_rewards enable row level security;

do $$
begin
  alter publication supabase_realtime add table public.weekly_tasks;
exception when duplicate_object then null;
end $$;
do $$
begin
  alter publication supabase_realtime add table public.weekly_task_settings;
exception when duplicate_object then null;
end $$;

-- ---------------------------------------------------------------------------
--  3) 本周的周一（按营业日）
-- ---------------------------------------------------------------------------
create or replace function public.week_start(p_day date default null)
returns date language sql stable
set search_path = public
as $$ select (date_trunc('week', coalesce(p_day, public.biz_date(now()))::timestamp))::date; $$;
grant execute on function public.week_start(date) to anon, authenticated;

-- 发奖：跟邀请那套一样各写各的流水，XP 涨了顺带重算等级
create or replace function public._weekly_grant(p_member_id uuid, p_coins int, p_xp int, p_tickets int, p_ref text)
returns void language plpgsql security definer
set search_path = public
as $$
begin
  if coalesce(p_coins,0) > 0 then
    insert into public.member_coin_ledger(member_id, delta, reason, ref_type, ref_id)
      values (p_member_id, p_coins, 'weekly_task', 'weekly', p_ref);
    update public.members set coins = coins + p_coins where id = p_member_id;
  end if;
  if coalesce(p_xp,0) > 0 then
    insert into public.member_xp_ledger(member_id, delta, reason, ref_type, ref_id)
      values (p_member_id, p_xp, 'weekly_task', 'weekly', p_ref);
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
--  4) 会员打开「我的」时读这个：每项进度 + 总百分比；全做完就地发奖
--     发奖幂等靠 member_weekly_rewards 的主键：插得进去才发，插不进去说明这周发过了。
--     顾客不用点「领取」——稿子上就没有那个按钮，进页面自动到账。
-- ---------------------------------------------------------------------------
drop function if exists public.rpc_get_my_weekly(uuid, text);
create or replace function public.rpc_get_my_weekly(p_member_id uuid, p_session_token text)
returns table(out_week_start date, out_pct int, out_done boolean, out_claimed boolean,
              out_reward jsonb, out_tasks jsonb)
language plpgsql security definer
set search_path = public
as $$
declare
  w_start date; w_end date;
  v_streak int; v_orders int; v_spend numeric;
  v_tasks jsonb := '[]'::jsonb; t record;
  v_total int := 0; v_ok int := 0; v_cur numeric; v_task_done boolean;
  s record; v_claimed boolean; v_ins int;
begin
  perform public._auth_member(p_member_id, p_session_token);

  w_start := public.week_start();
  w_end   := w_start + 6;

  -- 本周内最长的一段连续签到（gaps-and-islands：日期减去行号，同一段的差值相同）
  select coalesce(max(cnt), 0) into v_streak from (
    select count(*) as cnt from (
      select c.checkin_date - (row_number() over (order by c.checkin_date))::int as grp
        from public.checkins c
       where c.member_id = p_member_id and c.checkin_date between w_start and w_end
    ) t1 group by grp
  ) t2;

  -- 本周的单：按营业日落在本周内，作废/充值/预约都不算
  select count(*)::int, coalesce(sum(o.total), 0) into v_orders, v_spend
    from public.orders o
   where o.member_id = p_member_id
     and o.business_date between w_start and w_end
     and o.status not in ('void', 'pending')
     and coalesce(o.ta_mode, '') not in ('recharge', 'reservation');

  for t in select * from public.weekly_tasks where enabled order by sort_order, created_at loop
    v_cur := case t.code when 'checkin_streak' then v_streak
                         when 'order_count'    then v_orders
                         else v_spend end;
    v_task_done := v_cur >= t.target;
    v_total := v_total + 1;
    if v_task_done then v_ok := v_ok + 1; end if;
    v_tasks := v_tasks || jsonb_build_object(
      'code', t.code, 'name', t.name, 'target', t.target, 'current', v_cur, 'done', v_task_done);
  end loop;

  select * into s from public.weekly_task_settings where id = 1;

  -- 全做完 + 奖励启用 → 试着插一条领取记录，插进去了才真发
  if v_total > 0 and v_ok = v_total and found and s.enabled then
    insert into public.member_weekly_rewards(member_id, week_start, coins, xp, tickets)
      values (p_member_id, w_start, s.coins, s.xp, s.draw_tickets)
      on conflict (member_id, week_start) do nothing;
    get diagnostics v_ins = row_count;
    if v_ins > 0 then
      perform public._weekly_grant(p_member_id, s.coins, s.xp, s.draw_tickets,
                                   p_member_id::text || '#' || w_start::text);
    end if;
  end if;

  select exists(select 1 from public.member_weekly_rewards r
                 where r.member_id = p_member_id and r.week_start = w_start) into v_claimed;

  return query select
    w_start,
    case when v_total = 0 then 0 else (v_ok * 100 / v_total) end,
    (v_total > 0 and v_ok = v_total),
    v_claimed,
    jsonb_build_object('coins', coalesce(s.coins,0), 'xp', coalesce(s.xp,0),
                       'tickets', coalesce(s.draw_tickets,0), 'enabled', coalesce(s.enabled,false)),
    v_tasks;
end;
$$;
grant execute on function public.rpc_get_my_weekly(uuid, text) to anon;

select pg_notify('pgrst', 'reload schema');

-- 完成。POS「会员运营 → 每周任务」改任务和奖励，小程序「我的」那张卡跟着走。
