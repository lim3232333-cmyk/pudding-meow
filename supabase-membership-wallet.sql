-- ============================================================================
--  布丁喵 Meow Club 会员系统 — Meow Wallet 预存余额
--  用法：Supabase Dashboard → SQL Editor → New query → 粘贴全部 → Run
--  依赖 supabase-setup.sql + supabase-membership.sql（Phase 1）已经跑过。
--  只新增列/表 + 改写函数，不会清空已注册的会员数据。
-- ============================================================================

-- ---------- 1) members 表加钱包余额列 ----------
alter table public.members add column if not exists wallet_balance numeric not null default 0;

-- ---------- 2) 钱包流水（个人中心以后要看"钱包纪录"读这张表）----------
drop table if exists public.member_wallet_ledger cascade;
create table public.member_wallet_ledger (
  id bigint generated always as identity primary key,
  member_id uuid not null references public.members(id),
  delta numeric not null,           -- 正数=充值/退款，负数=消费
  reason text not null,             -- 'topup' | 'admin_adjust' | 'order' ...
  ref_type text, ref_id text,
  created_at timestamptz not null default now()
);
create index if not exists wallet_ledger_member_idx on public.member_wallet_ledger (member_id, created_at desc);
alter table public.member_wallet_ledger enable row level security;
-- 有意不建 anon policy：跟 xp/coin 流水一样，不给 anon 直接读写权限，只能走下面的 RPC。

-- ---------- 3) 改写 Phase 1 的资料读取函数：把钱包余额也带上 ----------
-- 返回的列变了（多了 wallet_balance），Postgres 不允许 create or replace 直接改列结构，要先 drop 掉旧的
drop function if exists public.rpc_get_my_profile(uuid, text);
create or replace function public.rpc_get_my_profile(p_member_id uuid, p_session_token text)
returns table(id uuid, phone text, nickname text, avatar_url text, level_id uuid, xp int, coins int,
              draw_tickets int, referral_code text, birthday date, created_at timestamptz, wallet_balance numeric)
language plpgsql security definer as $$
begin
  perform public._auth_member(p_member_id, p_session_token);
  return query select m.id, m.phone, m.nickname, m.avatar_url, m.level_id, m.xp, m.coins,
                      m.draw_tickets, m.referral_code, m.birthday, m.created_at, m.wallet_balance
               from public.members m where m.id = p_member_id;
end; $$;

-- ---------- 4) 对外 RPC：POS 后台给会员钱包充值/扣款（柜台收到现金/TnG 后人工充值）----------
create or replace function public.rpc_admin_topup_wallet(p_member_id uuid, p_amount numeric, p_reason text default null)
returns void language plpgsql security definer as $$
begin
  if p_amount is null or p_amount = 0 then return; end if;
  insert into public.member_wallet_ledger(member_id, delta, reason)
    values (p_member_id, p_amount, coalesce(nullif(trim(p_reason),''), 'admin_adjust'));
  update public.members set wallet_balance = wallet_balance + p_amount where id = p_member_id;
end; $$;

-- ---------- 5) 改写 Phase 1 的后台会员列表函数：把钱包余额也带上 ----------
drop function if exists public.rpc_admin_list_members(text);
create or replace function public.rpc_admin_list_members(p_search text default null)
returns table(id uuid, phone text, nickname text, level_id uuid, xp int, coins int, created_at timestamptz, last_active_at timestamptz, wallet_balance numeric)
language plpgsql security definer as $$
begin
  return query select m.id, m.phone, m.nickname, m.level_id, m.xp, m.coins, m.created_at, m.last_active_at, m.wallet_balance
    from public.members m
    where p_search is null or p_search = '' or m.phone ilike '%'||p_search||'%' or m.nickname ilike '%'||p_search||'%'
    order by m.created_at desc
    limit 200;
end; $$;

-- ---------- 6) 授权 ----------
grant execute on function public.rpc_get_my_profile(uuid, text) to anon;
grant execute on function public.rpc_admin_topup_wallet(uuid, numeric, text) to anon;
grant execute on function public.rpc_admin_list_members(text) to anon;

-- 完成。小程序会员卡片会显示真实的 Meow Wallet 余额；
-- 后台会员列表新增钱包余额列，「调整余额」弹窗新增钱包充值/扣款栏位。
