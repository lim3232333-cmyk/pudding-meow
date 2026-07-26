-- ============================================================================
--  布丁喵 — POS 幸运抽奖管理页所需：奖品库存 + 抽奖统计
--  用法：Supabase Dashboard → SQL Editor → New query → 粘贴 → Run（跑一次）
--  前置：supabase-lucky-draw.sql 已跑过。
--
--  1) 奖品加 stock（库存）：null = 不限量；0 = 已抽完，不再中出
--  2) 奖品加 'none' 类型的说明（谢谢参与）——原表 type 只有 coin/xp/redraw/item
--  3) rpc_admin_draw_stats：今日参与人数 / 今日抽奖次数 / 中奖率 / 库存合计
-- ============================================================================

-- 1) 库存。null 表示不限量（多数 Coin 类奖品都该是 null）
alter table public.lucky_draw_prizes add column if not exists stock int;

-- 2) 抽奖统计
--    中奖率口径：抽到「实际奖励」的比例 —— 排除 redraw（再来一次）和 none（谢谢参与），
--    这两种拿不到东西，不该算进中奖。
create or replace function public.rpc_admin_draw_stats()
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  d date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
  result json;
begin
  select json_build_object(
    'today_members', (
      select count(distinct h.member_id) from public.lucky_draw_history h
       where (h.created_at at time zone 'Asia/Kuala_Lumpur')::date = d),
    'today_draws', (
      select count(*) from public.lucky_draw_history h
       where (h.created_at at time zone 'Asia/Kuala_Lumpur')::date = d),
    -- 中奖率用全部历史算，今日样本太小没参考价值
    'win_rate', (
      select case when count(*) = 0 then 0
                  else round(100.0 * count(*) filter (
                         where h.prize_type not in ('redraw', 'none')) / count(*), 1)
             end
        from public.lucky_draw_history h),
    'total_draws', (select count(*) from public.lucky_draw_history),
    -- 库存合计：只统计有限量的奖品（stock 非空）
    'stock_left', (
      select coalesce(sum(p.stock), 0) from public.lucky_draw_prizes p
       where p.stock is not null and p.enabled),
    'unlimited_count', (
      select count(*) from public.lucky_draw_prizes p
       where p.stock is null and p.enabled)
  ) into result;
  return result;
end;
$$;

grant execute on function public.rpc_admin_draw_stats() to anon;

-- 完成。POS「会员运营 → 幸运抽奖」可以看统计、改奖品和概率权重、设库存。
