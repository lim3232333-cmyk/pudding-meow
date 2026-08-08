-- ============================================================================
--  布丁喵 — 订单加「制作单已打印」标记，做跨设备防重复出单
--  用法：Supabase Dashboard → SQL Editor → New query → 粘贴 → Run（跑一次）
--
--  问题：开了两台 POS（或两个浏览器标签）时，线上预付单进来每台都各自出一张制作单
--        —— 本地去重（pm_printed_kitchen）是每台各存一份、互不同步，所以会重复出 2 次。
--  解法：出单前先原子「认领」——把这一列从 NULL 改成时间戳，只有改成功的那台 POS 才打印，
--        WHERE kitchen_printed_at IS NULL 的条件保证并发下只有一台能认领成功。
--  orders 表已对 anon 开放 update（RLS for all），所以前端能直接做这个认领。
-- ============================================================================

alter table public.orders
  add column if not exists kitchen_printed_at timestamptz;

-- 完成。跑完后多台 POS / 多标签也只出一张制作单；没跑之前程序会自动退回本地去重（每台各出一张）。
