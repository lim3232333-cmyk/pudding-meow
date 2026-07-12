-- ============================================================================
--  布丁喵 Meow Club 会员系统 — Meow Wallet 交易明细（小程序"充值"页用）
--  用法：Supabase Dashboard → SQL Editor → New query → 粘贴全部 → Run
--  依赖 supabase-membership-wallet.sql 已经跑过（member_wallet_ledger 表已存在）。
--  只新增一个只读 RPC，不改动、不清空任何已有表/数据，可安全重复执行。
-- ============================================================================

create or replace function public.rpc_get_my_wallet_ledger(p_member_id uuid, p_session_token text)
returns table(id bigint, delta numeric, reason text, created_at timestamptz)
language plpgsql security definer as $$
begin
  perform public._auth_member(p_member_id, p_session_token);
  return query select l.id, l.delta, l.reason, l.created_at
    from public.member_wallet_ledger l
    where l.member_id = p_member_id
    order by l.created_at desc
    limit 50;
end; $$;

grant execute on function public.rpc_get_my_wallet_ledger(uuid, text) to anon;

-- 完成。小程序"充值"页的「交易明细」会显示会员自己的钱包流水（充值/消费）。
