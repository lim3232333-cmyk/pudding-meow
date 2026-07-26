-- ============================================================================
--  布丁喵 — 规格加价：同一个规格在不同商品上能收不同的钱
--  用法：Supabase Dashboard → SQL Editor → New query → 粘贴 → Run（跑一次）
--
--  原本价格只有商品这一层（menu_items.price），规格选项完全不带钱。现在两层：
--
--    spec_defs.option_prices        {"M":0,"L":2}   ← 规格库的「建议加价」，默认值
--    menu_items.specs[i].prices     {"L":3}         ← 这个商品自己说了算，覆盖默认
--
--  没填就跟默认走（跟 channels 的 null = 全渠道是同一套路子）。所以「大杯 +2」
--  在规格库填一次，只有那个要收 3 块的吐司才单独改。
--  specs 本来就是 jsonb，prices 塞在里面，menu_items 不用加列。
--
--  行价 = menu_items.price + 选中选项的加价之和。
--  优惠券一律按 menu_items.price（基础价）算：顾客加了料不该多抵，
--  而且服务端算折扣时不用信前端传上来的规格。_coupon_calc 不动就是这个口径。
-- ============================================================================

alter table public.spec_defs add column if not exists option_prices jsonb;

-- 完成。POS 规格管理每个选项多一个加价输入框；商品表单里可以逐个商品覆盖。
