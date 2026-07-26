-- ============================================================================
--  布丁喵 — 会员数据即时刷新（POS 改了，顾客手机上立刻变）
--  用法：Supabase Dashboard → SQL Editor → New query → 粘贴 → Run（跑一次）
--  前置：supabase-membership.sql、supabase-membership-phase2.sql、
--        supabase-membership-wallet.sql 都已跑过。
--
--  为什么不直接订阅 members 表：
--    members 表是有意「不给 anon 任何 RLS policy」的（见 supabase-membership.sql 的
--    RLS 段注释）——anon key 写在网页里、人人可见，一旦放开直接读，任何人都能拿它
--    把全部会员的手机号、余额、等级拉走。会员数据一律只经 security definer 的
--    rpc_* 函数出入，函数内部校验 session_token。
--    而 Supabase Realtime 是走 RLS 的：anon 对 members 没有 select 权限，
--    直接订阅 members 一条消息都收不到。
--
--  所以这里用「门铃」模式：
--    member_events 只存 (member_id, updated_at) 两个字段，不含任何个人资料，
--    anon 可读、可安全订阅。members / member_coupons 一有变动，数据库触发器就
--    更新对应会员的这一行；前端收到通知后，再用原来那个鉴权 RPC 去取真实数据。
--    也就是说：realtime 只负责喊一声「你的数据变了」，数据本身仍旧要过鉴权。
-- ============================================================================

-- 1) 门铃表：每个会员一行，只有 id 和时间戳
create table if not exists public.member_events (
  member_id  uuid primary key references public.members(id) on delete cascade,
  updated_at timestamptz not null default now()
);

-- anon 只读。member_id 是 uuid（不可枚举猜测），且这里没有任何个人资料，
-- 泄露面仅限「某个 uuid 在某时刻有过变动」。不给 anon 写权限——由触发器代写。
alter table public.member_events enable row level security;
drop policy if exists member_events_anon_read on public.member_events;
create policy member_events_anon_read on public.member_events for select to anon using (true);

-- 2) 触发器函数：把变动会员的 id 敲进门铃表
--    security definer：调用方（anon）对 member_events 没有写权限，靠它代写。
create or replace function public.trg_touch_member_event()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare mid uuid;
begin
  -- DELETE 取 OLD，其余取 NEW；members 表主键是 id，明细表用 member_id
  if (tg_op = 'DELETE') then
    mid := case when tg_table_name = 'members' then old.id else old.member_id end;
  else
    mid := case when tg_table_name = 'members' then new.id else new.member_id end;
  end if;

  if mid is null then
    return null;
  end if;

  insert into public.member_events (member_id, updated_at)
  values (mid, now())
  on conflict (member_id) do update set updated_at = excluded.updated_at;

  return null;   -- AFTER 触发器，返回值不影响本次写入
end;
$$;

-- 3) 挂到会员余额/等级会变的表上
--    members：xp / coins / wallet_balance / level_id / nickname 都在这张表
--    只在这些字段真的变了才敲门铃——否则每次登录刷新 session_token 都会误触发。
drop trigger if exists members_touch_event on public.members;
create trigger members_touch_event
  after update of xp, coins, wallet_balance, level_id, nickname on public.members
  for each row execute function public.trg_touch_member_event();

--    member_coupons：发券 / 核销 / 过期，会员卡上的优惠券数量要跟着变
drop trigger if exists member_coupons_touch_event on public.member_coupons;
create trigger member_coupons_touch_event
  after insert or update or delete on public.member_coupons
  for each row execute function public.trg_touch_member_event();

-- 4) 加进 realtime 发布
do $$
begin
  alter publication supabase_realtime add table public.member_events;
exception when duplicate_object then null;   -- 重复跑本脚本时忽略
end $$;

-- 完成。之后店员在 POS 调 XP / 加币 / 充值 / 发券，顾客手机上的会员卡会立刻刷新。
