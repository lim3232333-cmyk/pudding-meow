-- ============================================================================
--  布丁喵 POS 收据 — 会员区块数据
--  用法：Supabase Dashboard → SQL Editor → New query → 粘贴全部 → Run
--  依赖 supabase-membership.sql 已经跑过。只新增一个只读 RPC，不动任何数据。
--
--  新版收据（Figma 326-187）底部有 MEMBER 区块：
--    Jia Hui (Kitten)          Coins: 1280
--    +26 XP                    Next Lv: 220 XP
--    +53 Coins
--  这个 RPC 一次拿齐这些数字：会员昵称、当前等级名、金币余额、
--  本单获得的 XP/Coins（从流水表按订单号汇总）、距离下一等级还差多少 XP。
-- ============================================================================

create or replace function public.rpc_pos_receipt_member_info(p_member_id uuid, p_order_id text)
returns table(
  nickname text,
  level_name text,
  coins int,
  order_xp int,
  order_coins int,
  next_level_xp_gap int   -- null = 已是最高等级
)
language plpgsql security definer as $$
begin
  return query
  select
    m.nickname,
    coalesce(lv.name_en, lv.name_cn) as level_name,
    m.coins,
    coalesce((select sum(x.delta)::int from public.member_xp_ledger x
              where x.member_id = m.id and x.ref_type = 'order' and x.ref_id = p_order_id), 0) as order_xp,
    coalesce((select sum(c.delta)::int from public.member_coin_ledger c
              where c.member_id = m.id and c.ref_type = 'order' and c.ref_id = p_order_id), 0) as order_coins,
    (select min(l2.xp_required) - m.xp from public.member_levels l2
      where l2.xp_required > m.xp) as next_level_xp_gap
  from public.members m
  left join public.member_levels lv on lv.id = m.level_id
  where m.id = p_member_id;
end; $$;

grant execute on function public.rpc_pos_receipt_member_info(uuid, text) to anon;

-- 完成。POS 打印带会员的订单时，收据底部会显示会员昵称/等级/本单积分/金币余额。
