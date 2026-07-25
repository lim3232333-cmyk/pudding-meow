-- ============================================================================
--  布丁喵 — ORDER CODE 改为「按取餐方式分别编号」
--  用法：Supabase Dashboard → SQL Editor → New query → 粘贴 → Run（跑一次）
--  前置：必须先跑过 supabase-order-numbers.sql（本脚本在它建的 order_counters 上加列）
--
--  改动原因：原本 TA/DL 后面接的是当天「全类型共用」的流水号，今天只有 3 单外卖
--  也可能编到 DL07，顾客会误以为前面排了很多单。改成每种方式各自从 01 开始：
--
--    堂食      Table 1、Table 2 ...      （直接用桌号，不占用序号）
--    自取      TA01、TA02、TA03 ...      （每天从 01 起）
--    外卖      DL01、DL02、DL03 ...      （每天从 01 起）
--    Receipt No RC000001 ...             （永久递增、不分类型，财务用）
--    Order No   #0001、#0002 ...         （当天全类型流水，报表用）
--
--  三个计数器都按马来西亚时区 Asia/Kuala_Lumpur 的「今天」重置。
--  充值单/预约单传 p_kind = null，不占用 TA/DL 序号。
-- ============================================================================

-- 1) 计数器表加两列：自取、外卖各自的当天序号
alter table public.order_counters
  add column if not exists ta_seq int not null default 0,
  add column if not exists dl_seq int not null default 0;

-- 2) 订单表存下这一单的「类型内序号」，重印/跨设备显示才不会变
alter table public.orders add column if not exists kind_seq int;

-- 3) 换掉旧的无参版本。
--    注意必须先 drop：create or replace 遇到不同签名会变成「重载」，
--    两个同名函数并存时不带参数的调用会 ambiguous 而报错。
drop function if exists public.rpc_next_order_num();
drop function if exists public.rpc_next_order_num(text);

--    p_kind: 'takeaway' 自取/打包 | 'delivery' 外卖 | 其他/null 不占类型序号
--    一次原子返回 (receipt_no, order_no, kind_seq)
create or replace function public.rpc_next_order_num(p_kind text default null)
returns table(receipt_no bigint, order_no int, kind_seq int)
language plpgsql
security definer
set search_path = public
as $$
declare
  d       date := (now() at time zone 'Asia/Kuala_Lumpur')::date;
  inc_ta  int  := case when p_kind = 'takeaway' then 1 else 0 end;
  inc_dl  int  := case when p_kind = 'delivery' then 1 else 0 end;
begin
  return query
  update public.order_counters
     set receipt_seq = receipt_seq + 1,
         -- 跨天则重置为「本单是否属于该类型」，否则在原值上累加
         day_seq     = case when day = d then day_seq + 1 else 1      end,
         ta_seq      = case when day = d then ta_seq  + inc_ta else inc_ta end,
         dl_seq      = case when day = d then dl_seq  + inc_dl else inc_dl end,
         day         = d
   where id = 1
   returning order_counters.receipt_seq,
             order_counters.day_seq,
             case p_kind
               when 'takeaway' then order_counters.ta_seq
               when 'delivery' then order_counters.dl_seq
               else null
             end;
end;
$$;

grant execute on function public.rpc_next_order_num(text) to anon, authenticated;

-- 完成。之后下单：自取拿 TA01/TA02…，外卖拿 DL01/DL02…，堂食仍直接显示桌号。
-- 已存在的历史订单没有 kind_seq，前端会退回用当天流水号显示，旧单重印不会变样。
