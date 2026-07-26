-- ============================================================================
--  布丁喵 — POS 会员列表补齐字段 + 会员详情（点进去看各种记录）
--  用法：Supabase Dashboard → SQL Editor → New query → 粘贴 → Run（跑一次）
--  前置：supabase-membership.sql / -phase2.sql / -wallet.sql / -lucky-draw.sql 已跑过。
--
--  改动：
--   1) members 加 notes 列（店员备注）
--   2) rpc_admin_list_members 补上 头像/储值余额/累计消费/消费次数/最后消费时间/备注
--      —— 原版不返回 wallet_balance，而 POS 表格已经在渲染这一列，所以一直显示 RM 0.0
--   3) 新增 rpc_admin_member_detail：一次取回该会员的六种记录
--   4) 新增 rpc_admin_set_member_notes：保存备注
--
--  「消费」的口径：排除充值单与预约单（那不是营业额），也排除作废单和还没付款的单。
-- ============================================================================

-- 1) 店员备注
alter table public.members add column if not exists notes text;

-- 2) 会员列表
--    返回的列变了，Postgres 不允许 create or replace 直接改列结构，必须先 drop
drop function if exists public.rpc_admin_list_members(text);
create or replace function public.rpc_admin_list_members(p_search text default null)
returns table(
  id uuid, phone text, nickname text, avatar_url text, level_id uuid,
  xp int, coins int, wallet_balance numeric,
  total_spent numeric, order_count int, last_order_at timestamptz,
  notes text, created_at timestamptz, last_active_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
begin
  return query
  select m.id, m.phone, m.nickname, m.avatar_url, m.level_id,
         m.xp, m.coins, m.wallet_balance,
         coalesce(o.spent, 0)::numeric,
         coalesce(o.cnt, 0)::int,
         o.last_at,
         m.notes, m.created_at, m.last_active_at
    from public.members m
    left join lateral (
      select sum(x.total) as spent, count(*) as cnt, max(x.created_at) as last_at
        from public.orders x
       where x.member_id = m.id
         and coalesce(x.ta_mode, '') not in ('recharge', 'reservation')
         and coalesce(x.status, '') not in ('void', 'pending')
    ) o on true
   where p_search is null or p_search = ''
      or m.phone ilike '%' || p_search || '%'
      or m.nickname ilike '%' || p_search || '%'
   order by m.created_at desc
   limit 200;
end;
$$;

-- 3) 会员详情：六种记录一次取回，各自最多 100 条（够店员查，也不至于把响应撑爆）
create or replace function public.rpc_admin_member_detail(p_member_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare result json;
begin
  select json_build_object(
    -- 消费记录（不含充值/预约）
    'orders', (select coalesce(json_agg(t), '[]'::json) from (
        select o.id, o.order_num, o.receipt_no, o.created_at, o.total,
               o.pay_method, o.status, o.ta_mode, o.table_name, o.items
          from public.orders o
         where o.member_id = p_member_id
           and coalesce(o.ta_mode, '') not in ('recharge', 'reservation')
         order by o.created_at desc limit 100) t),
    -- 储值记录（正数=充值/退款，负数=消费抵扣）
    'wallet', (select coalesce(json_agg(t), '[]'::json) from (
        select w.delta, w.reason, w.ref_type, w.ref_id, w.created_at
          from public.member_wallet_ledger w
         where w.member_id = p_member_id
         order by w.created_at desc limit 100) t),
    'coins', (select coalesce(json_agg(t), '[]'::json) from (
        select c.delta, c.reason, c.ref_type, c.ref_id, c.created_at
          from public.member_coin_ledger c
         where c.member_id = p_member_id
         order by c.created_at desc limit 100) t),
    -- 成长记录（升级历史就看这条流水）
    'xp', (select coalesce(json_agg(t), '[]'::json) from (
        select x.delta, x.reason, x.ref_type, x.ref_id, x.created_at
          from public.member_xp_ledger x
         where x.member_id = p_member_id
         order by x.created_at desc limit 100) t),
    'draws', (select coalesce(json_agg(t), '[]'::json) from (
        select d.prize_label, d.prize_type, d.prize_value, d.created_at
          from public.lucky_draw_history d
         where d.member_id = p_member_id
         order by d.created_at desc limit 100) t),
    'coupons', (select coalesce(json_agg(t), '[]'::json) from (
        select mc.id, mc.status, mc.issued_at, mc.expires_at, mc.used_at, mc.order_id,
               c.name, c.type, c.value, c.min_spend
          from public.member_coupons mc
          join public.coupons c on c.id = mc.coupon_id
         where mc.member_id = p_member_id
         order by mc.issued_at desc limit 100) t)
  ) into result;
  return result;
end;
$$;

-- 4) 保存店员备注
create or replace function public.rpc_admin_set_member_notes(p_member_id uuid, p_notes text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.members set notes = nullif(trim(coalesce(p_notes, '')), '') where id = p_member_id;
end;
$$;

grant execute on function public.rpc_admin_list_members(text) to anon;
grant execute on function public.rpc_admin_member_detail(uuid) to anon;
grant execute on function public.rpc_admin_set_member_notes(uuid, text) to anon;

-- 完成。POS「会员运营 → 会员列表」会多出储值余额/累计消费/消费次数/最后消费，
-- 点某一行可以看到该会员的六种记录和备注。
