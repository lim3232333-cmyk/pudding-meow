-- ============================================================================
--  布丁喵 — 撤销已发放的优惠券（后台「优惠券管理 → 已发放优惠券」用）
--  用法：Supabase Dashboard → SQL Editor → New query → 粘贴 → Run（跑一次）
--
--  member_coupons 有 RLS、anon 不能直接删，所以走这个 security definer RPC。
--  只允许撤销「未使用 / 已过期」的券；已使用的是真实消费记录，不给删（保留账目）。
-- ============================================================================

create or replace function public.rpc_admin_revoke_member_coupon(p_member_coupon_id uuid)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare v_status text; v_count int;
begin
  select status into v_status from public.member_coupons where id = p_member_coupon_id;
  if v_status is null then raise exception '这张券不存在（可能已被撤销）'; end if;
  if v_status = 'used' then raise exception '已使用的券不能撤销（那是真实消费记录）'; end if;
  delete from public.member_coupons where id = p_member_coupon_id;
  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

grant execute on function public.rpc_admin_revoke_member_coupon(uuid) to anon;

-- 完成。后台「已发放优惠券」列表里未使用/已过期的券会多一个「撤销」按钮。
