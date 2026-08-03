-- ============================================================================
--  布丁喵 — 待付款单核对：按 member_id 查会员资料
--  用法：Supabase Dashboard → SQL Editor → New query → 粘贴 → Run（跑一次）
--  前置：supabase-pos-member.sql 已跑过（本函数字段跟 rpc_pos_find_member 保持一致，
--  这样收银台的 _renderPosMember() 不用另写一套渲染逻辑）。
--
--  背景：POS「待付款 Pending Payment」队列点某一单的 Payment，会先把商品 + 会员资料
--  载入购物栏给店员核对（防止顾客手滑点了两次重复下单），再手动点收银台的 Payment 真正
--  收款。已有的 rpc_pos_find_member 只能按手机号查，但待付款单上存的是 member_id，
--  所以补一个按 id 查的版本。
-- ============================================================================

create or replace function public.rpc_pos_member_by_id(p_member_id uuid)
returns table(
  id uuid, phone text, nickname text, level_name text, level_color text,
  xp int, coins int, wallet_balance numeric, unused_coupons int)
language plpgsql
security definer
set search_path = public
as $$
begin
  return query
  select m.id, m.phone, m.nickname, l.name_cn, l.color_hex,
         m.xp, m.coins, m.wallet_balance,
         (select count(*)::int from public.member_coupons mc
           where mc.member_id = m.id and mc.status = 'unused'
             and (mc.expires_at is null or mc.expires_at > now()))
    from public.members m
    left join public.member_levels l on l.id = m.level_id
   where m.id = p_member_id
   limit 1;
end;
$$;

grant execute on function public.rpc_pos_member_by_id(uuid) to anon;

-- PostgREST 会缓存一份函数清单，新建的函数有时不会马上出现在缓存里
select pg_notify('pgrst', 'reload schema');

-- 完成。POS 待付款队列点 Payment 后，若这单绑了会员，购物栏上方会带出昵称/等级/余额，
-- 方便核对是不是本人的单。
