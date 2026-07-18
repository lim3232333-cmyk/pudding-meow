-- ============================================================================
--  布丁喵 — 取号：永久收据号 RECEIPT NO + 每日订单号 ORDER NO
--  用法：Supabase Dashboard → SQL Editor → New query → 粘贴 → Run（跑一次）
--
--  RECEIPT NO：全局永久递增、不重置、跨设备唯一（财务/退款/报表/重印）。
--  ORDER NO  ：按天重置（每天从 1 开始），用马来西亚时区 Asia/Kuala_Lumpur 判断「今天」。
--  下单时调用 rpc_next_order_num() 原子取号，POS 与小程序共用一套号，不会撞号。
-- ============================================================================

-- 单行计数器表
create table if not exists public.order_counters (
  id          int      primary key default 1 check (id = 1),
  receipt_seq bigint   not null default 0,   -- 永久收据号
  day         date,                          -- 当前统计的日期（本地时区）
  day_seq     int      not null default 0    -- 当天订单号
);
insert into public.order_counters (id) values (1) on conflict (id) do nothing;

-- 订单表加一列存永久收据号（order_num 列继续存当天订单号）
alter table public.orders add column if not exists receipt_no bigint;

-- 原子取号：一次返回 (receipt_no, order_no)
create or replace function public.rpc_next_order_num()
returns table(receipt_no bigint, order_no int)
language plpgsql
security definer
set search_path = public
as $$
declare d date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
begin
  return query
  update public.order_counters
     set receipt_seq = receipt_seq + 1,
         day_seq     = case when day = d then day_seq + 1 else 1 end,
         day         = d
   where id = 1
   returning order_counters.receipt_seq, order_counters.day_seq;
end;
$$;

grant execute on function public.rpc_next_order_num() to anon, authenticated;

-- 完成。之后下单会自动取号；收据抬头 RECEIPT NO 用永久号，信息行 ORDER NO 用当天号。
