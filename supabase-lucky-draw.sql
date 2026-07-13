-- ============================================================================
--  布丁喵 Meow Club 会员系统 — 幸运抽奖（转盘）
--  用法：Supabase Dashboard → SQL Editor → New query → 粘贴全部 → Run
--  依赖 supabase-membership.sql 已经跑过（members.draw_tickets 字段已存在，
--  当初就是为这个功能预留的）。只新增表/函数，不清空、不改动任何已有数据。
-- ============================================================================

-- ---------- 1) 转盘奖品配置 ----------
-- sort_order 0-7 对应小程序转盘上固定的 8 个格子位置（顺时针从正上方开始）：
--   0=100 Coin  1=100 XP  2=50 Coin  3=任意商品  4=20 Coin  5=再来一次  6=经典布丁  7=50 XP
-- 小程序端的格子文案/颜色/位置是写死的（保证 100% 还原 Figma），这张表只决定
-- 「抽中概率(weight)」和「奖品类型/数值」，两边靠 sort_order 对应。
drop table if exists public.lucky_draw_prizes cascade;
create table public.lucky_draw_prizes (
  id uuid primary key default gen_random_uuid(),
  label text not null,
  type text not null,              -- 'coin' | 'xp' | 'redraw'(再来一次，退还本次抽奖券) | 'item'(实物/优惠券，店员线下核实兑换)
  value int,                       -- coin/xp 的数量；redraw/item 为 null
  weight int not null default 1,   -- 权重，数字越大越容易抽中
  sort_order int not null unique,
  enabled boolean not null default true
);
alter table public.lucky_draw_prizes enable row level security;
drop policy if exists lucky_draw_prizes_anon_read on public.lucky_draw_prizes;
create policy lucky_draw_prizes_anon_read on public.lucky_draw_prizes for select to anon using (true);
drop policy if exists lucky_draw_prizes_anon_write on public.lucky_draw_prizes;
create policy lucky_draw_prizes_anon_write on public.lucky_draw_prizes for all to anon using (true) with check (true);

insert into public.lucky_draw_prizes (label, type, value, weight, sort_order) values
  ('100 Coin', 'coin', 100, 1, 0),
  ('100 XP',   'xp',   100, 1, 1),
  ('50 Coin',  'coin', 50,  3, 2),
  ('任意商品', 'item', null,1, 3),
  ('20 Coin',  'coin', 20,  6, 4),
  ('再来一次', 'redraw', null, 3, 5),
  ('经典布丁', 'item', null, 2, 6),
  ('50 XP',    'xp',   50,  3, 7);

-- ---------- 2) 抽奖纪录 ----------
drop table if exists public.lucky_draw_history cascade;
create table public.lucky_draw_history (
  id bigint generated always as identity primary key,
  member_id uuid not null references public.members(id),
  prize_id uuid references public.lucky_draw_prizes(id),
  prize_label text not null,
  prize_type text not null,
  prize_value int,
  created_at timestamptz not null default now()
);
create index if not exists lucky_draw_history_member_idx on public.lucky_draw_history (member_id, created_at desc);
alter table public.lucky_draw_history enable row level security;
-- 有意不建 anon policy：只能走下面的 RPC 读写，不给前端直连改抽奖纪录。

-- ---------- 3) 对外 RPC：查询剩余抽奖次数 ----------
create or replace function public.rpc_get_my_draw_status(p_member_id uuid, p_session_token text)
returns table(draw_tickets int)
language plpgsql security definer as $$
begin
  perform public._auth_member(p_member_id, p_session_token);
  return query select m.draw_tickets from public.members m where m.id = p_member_id;
end; $$;

-- ---------- 4) 对外 RPC：抽奖 ----------
-- 扣 1 张券 -> 按权重抽一个奖 -> 发放奖励（coin/xp 直接加余额+写流水；redraw 把券退还；
-- item 只记一笔纪录，实物/优惠券由店员核对纪录后线下兑现）-> 写入抽奖纪录 -> 把中奖结果
-- （含 sort_order，让前端知道转盘要停在第几格）返回给前端播放动画。
create or replace function public.rpc_lucky_draw(p_member_id uuid, p_session_token text)
returns table(prize_id uuid, prize_label text, prize_type text, prize_value int, sort_order int, draw_tickets_left int)
language plpgsql security definer as $$
declare
  v_tickets int;
  v_total_weight int;
  v_pick int;
  v_prize record;
  v_xp int;
begin
  perform public._auth_member(p_member_id, p_session_token);

  select draw_tickets into v_tickets from public.members where id = p_member_id for update;
  if v_tickets is null or v_tickets <= 0 then
    raise exception '抽奖次数不足';
  end if;

  update public.members set draw_tickets = draw_tickets - 1 where id = p_member_id;

  select coalesce(sum(weight),0) into v_total_weight from public.lucky_draw_prizes where enabled = true;
  if v_total_weight <= 0 then
    raise exception '转盘暂未配置奖品';
  end if;
  v_pick := floor(random() * v_total_weight);

  select * into v_prize from (
    select p.*, sum(p.weight) over (order by p.sort_order) as running_weight
    from public.lucky_draw_prizes p where p.enabled = true
  ) t where t.running_weight > v_pick order by t.sort_order limit 1;

  if v_prize.type = 'coin' then
    insert into public.member_coin_ledger(member_id, delta, reason, ref_type) values (p_member_id, v_prize.value, 'lucky_draw', 'lucky_draw');
    update public.members set coins = coins + v_prize.value where id = p_member_id;
  elsif v_prize.type = 'xp' then
    insert into public.member_xp_ledger(member_id, delta, reason, ref_type) values (p_member_id, v_prize.value, 'lucky_draw', 'lucky_draw');
    update public.members set xp = xp + v_prize.value where id = p_member_id;
    update public.members set level_id = (
      select id from public.member_levels where xp_required <= (select xp from public.members where id = p_member_id)
      order by sort_order desc limit 1
    ) where id = p_member_id;
  elsif v_prize.type = 'redraw' then
    update public.members set draw_tickets = draw_tickets + 1 where id = p_member_id;
  end if;
  -- type = 'item'：不动余额，只留一笔纪录，店里核对纪录后线下兑现

  insert into public.lucky_draw_history(member_id, prize_id, prize_label, prize_type, prize_value)
    values (p_member_id, v_prize.id, v_prize.label, v_prize.type, v_prize.value);

  return query select v_prize.id, v_prize.label, v_prize.type, v_prize.value, v_prize.sort_order,
    (select draw_tickets from public.members where id = p_member_id);
end; $$;

-- ---------- 5) 对外 RPC：我的抽奖纪录 ----------
create or replace function public.rpc_get_my_draw_history(p_member_id uuid, p_session_token text)
returns table(id bigint, prize_label text, prize_type text, prize_value int, created_at timestamptz)
language plpgsql security definer as $$
begin
  perform public._auth_member(p_member_id, p_session_token);
  return query select h.id, h.prize_label, h.prize_type, h.prize_value, h.created_at
    from public.lucky_draw_history h
    where h.member_id = p_member_id
    order by h.created_at desc
    limit 50;
end; $$;

-- ---------- 6) 对外 RPC：POS 后台给会员补发抽奖次数 ----------
create or replace function public.rpc_admin_grant_draw_tickets(p_member_id uuid, p_amount int)
returns void language plpgsql security definer as $$
begin
  if p_amount is null or p_amount = 0 then return; end if;
  update public.members set draw_tickets = greatest(0, draw_tickets + p_amount) where id = p_member_id;
end; $$;

-- ---------- 7) 授权 ----------
grant execute on function public.rpc_get_my_draw_status(uuid, text) to anon;
grant execute on function public.rpc_lucky_draw(uuid, text) to anon;
grant execute on function public.rpc_get_my_draw_history(uuid, text) to anon;
grant execute on function public.rpc_admin_grant_draw_tickets(uuid, int) to anon;

-- 完成。小程序幸运抽奖页可以真实抽奖、发放奖励、看抽奖纪录了。
-- 会员现在暂时都是 0 抽奖次数（没有任何入口发放）——先在 POS 用
-- rpc_admin_grant_draw_tickets 手动给测试会员发几次，或者告诉我你想怎么
-- 让顾客获得抽奖次数（比如签到里程碑、消费满额等），我再接上自动发放。
