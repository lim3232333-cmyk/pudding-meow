-- ============================================================================
--  布丁喵 PUDDING MEOW — 外卖订单收货信息入库（给 POS 叫 Lalamove 用）
--  用法：Supabase Dashboard → SQL Editor → New query → 粘贴全部 → Run
--  只加一列，不清空、不改动任何已有订单，可安全重复执行。
--
--  背景：外卖订单的收货地址、GPS 坐标、收货人电话原本只存在顾客手机本地，
--  没进数据库，所以店里的 POS 读不到——而叫 Lalamove 骑手必须要坐标和电话。
--  这一列把这些信息随订单存进云端，POS 才能点「叫车」。
--
--  delivery_info 里存什么（jsonb，只有外卖单才有）：
--    { address, lat, lng, recipientName, phone, remarks, fee, quotationId,
--      lalamove: { orderId, status, shareLink, driverName, driverPhone, price } }
--  其中 lalamove 那块是店员在 POS 点了「叫车」之后才写进去的。
-- ============================================================================

alter table public.orders add column if not exists delivery_info jsonb;

-- 完成。配合已更新的 pudding-meow.html / pos.html：
-- - 顾客下外卖单时，收货信息随单存进 delivery_info；
-- - POS 外卖配送面板读 delivery_info 显示地址/电话，并调 lalamove-order 叫车；
-- - 叫车结果（骑手、追踪链接）写回 delivery_info.lalamove。
-- - 旧订单 delivery_info 是空的，不受影响。
