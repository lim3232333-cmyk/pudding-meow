-- ============================================================================
--  布丁喵 PUDDING MEOW — 顾客端"订单"页只看自己的单
--  用法：Supabase Dashboard → SQL Editor → New query → 粘贴全部 → Run
--  只加一列 + 两个索引，不清空、不改动任何已有订单数据，可安全重复执行。
--
--  背景：顾客端小程序的"订单"页原本是不带条件地拉 orders 表最近 50 笔——
--  也就是说不管谁扫桌上的二维码打开，看到的都是全店（包括店家自己测试下的单）
--  最近的订单，不是"自己的"。这一列用来给每台设备/每个会员的订单做区分。
-- ============================================================================

alter table public.orders add column if not exists device_id text;
create index if not exists orders_device_id_idx on public.orders (device_id, created_at desc);
create index if not exists orders_member_id_idx on public.orders (member_id, created_at desc);

-- 完成。配合已更新的 pudding-meow.html：
-- - 没登录会员的访客，按浏览器本机生成的匿名 device_id 只看自己下的单；
-- - 登录会员的顾客，按 member_id 看自己的单（换设备登录也能看到）。
-- - 之前已经存在的旧订单 device_id 是空的，不会出现在任何人的"订单"页里
--   （POS 后台的订单/交易记录不受影响，店员照旧能看到全部订单）。
