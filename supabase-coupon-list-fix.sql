-- ============================================================================
--  布丁喵 — 修复「已发放优惠券」列表为空
--  用法：Supabase Dashboard → SQL Editor → New query → 粘贴 → Run（跑一次）
--
--  原因：旧版 rpc_admin_list_member_coupons 用 inner join 连 members / coupons。
--  如果优惠券模板表被重建过（有些迁移带 drop table coupons cascade），已发出去的券
--  coupon_id 就指向不存在的模板，被内连接整行丢掉 → 列表全空、也没法撤销。
--  改成 LEFT JOIN：不管模板/会员在不在，已发的券都列出来（模板没了就标「模板已删」）。
-- ============================================================================

create or replace function public.rpc_admin_list_member_coupons(p_search text default null)
returns table(id uuid, member_id uuid, member_phone text, member_nickname text,
              coupon_name text, status text, issued_at timestamptz, expires_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
begin
  -- 顺手把到期的未使用券标成 expired（跟原来一样）
  update public.member_coupons mc set status = 'expired'
   where mc.status = 'unused' and mc.expires_at is not null and mc.expires_at < now();

  return query
  select mc.id, mc.member_id, m.phone, m.nickname,
         coalesce(c.name, '（模板已删）') as coupon_name,
         mc.status, mc.issued_at, mc.expires_at
    from public.member_coupons mc
    left join public.members m on m.id = mc.member_id
    left join public.coupons c on c.id = mc.coupon_id
   where p_search is null or p_search = ''
      or m.phone ilike '%' || p_search || '%'
      or m.nickname ilike '%' || p_search || '%'
   order by mc.issued_at desc
   limit 200;
end;
$$;

grant execute on function public.rpc_admin_list_member_coupons(text) to anon;

-- 完成。回后台「优惠券管理」看「已发放优惠券」列表，之前发出去的券应该都回来了。
