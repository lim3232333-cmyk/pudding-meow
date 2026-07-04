-- ============================================================================
--  布丁喵 PUDDING MEOW — Supabase 建表脚本
--  用法：Supabase Dashboard → 左侧 SQL Editor → New query → 粘贴全部 → Run
--  可安全重复运行（幂等：先 drop table 再重建，菜单随之重新灌入）
--  ⚠️ 重复运行会清空 orders 里已有的订单——上线后若要保数据，勿重跑第 1 节。
-- ============================================================================

-- ---------- 1) 订单表 orders ----------
drop table if exists public.orders cascade;
create table public.orders (
  id          text primary key,                 -- app: 'o'+timestamp / pos: 'pos'+timestamp
  order_num   text,
  created_at  timestamptz not null default now(),
  items       jsonb       not null default '[]'::jsonb,
  total       numeric     not null default 0,
  pay_method  text,                             -- tng | counter | cash | card
  status      text        not null default 'pending', -- pending|preparing|paid|ready|done
  source      text        not null default 'app',     -- app | pos
  table_name  text,
  ta_mode     text                              -- dinein | takeaway
);
create index if not exists orders_created_idx on public.orders (created_at desc);
create index if not exists orders_status_idx  on public.orders (status);

-- ---------- 2) 菜单表 menu_items ----------
drop table if exists public.menu_items cascade;
create table public.menu_items (
  id          uuid primary key default gen_random_uuid(),
  cat         text not null,                    -- special|classic|toast|boat|ice|drinks
  name        text not null,
  en          text,
  price       numeric not null default 0,
  descr       text,
  flavors     jsonb   not null default '["Original"]'::jsonb,
  sold_out    boolean not null default false,
  sort_order  int     not null default 0
);
create index if not exists menu_cat_idx on public.menu_items (cat, sort_order);

-- ---------- 3) Row Level Security（MVP 权限）----------
-- 说明：anon key 是公开的。以下策略为“先能用”的最小方案：
--   orders     : 允许任何人 下单(insert)/查看(select)/改状态(update)
--   menu_items : 人人可读(select)；写入(insert/update/delete)MVP 也放开给 anon
--   ⚠️ POS 目前仅本机 PIN、无真实登录；上线稳定后应加“店员鉴权”收紧 menu 写权限。
alter table public.orders     enable row level security;
alter table public.menu_items enable row level security;

drop policy if exists orders_anon_all on public.orders;
create policy orders_anon_all on public.orders
  for all to anon using (true) with check (true);

drop policy if exists menu_anon_read on public.menu_items;
create policy menu_anon_read on public.menu_items
  for select to anon using (true);

drop policy if exists menu_anon_write on public.menu_items;
create policy menu_anon_write on public.menu_items
  for all to anon using (true) with check (true);

-- ---------- 4) 开启 Realtime（实时推送）----------
-- 让 orders / menu_items 的变化实时推到小程序和 POS
alter publication supabase_realtime add table public.orders;
alter publication supabase_realtime add table public.menu_items;

-- ---------- 5) 灌入当前菜单 ----------
insert into public.menu_items (cat, name, en, price, descr, flavors, sold_out, sort_order) values
  ('special', '布丁芭菲杯', 'Pudding Parfait', 19.8, '香滑布丁配新鲜水果与奶油，层层堆叠的甜蜜芭菲杯。', '["Original", "Matcha", "Peach Oolong", "Black Sesame", "Chocolate", "Genmaicha"]'::jsonb, false, 10),
  ('special', '香蕉布丁烧', 'Banana Pudding Cake', 11.0, '焦糖香蕉搭配绵密布丁烧，香气十足的人气甜点。', '["Original", "Chocolate"]'::jsonb, false, 20),
  ('special', '招牌焦糖布丁喵', 'Signature Caramel Meow', 9.5, '招牌猫咪造型焦糖布丁，浓郁顺滑。', '["Original"]'::jsonb, false, 30),
  ('classic', '原味鸡蛋布丁', 'Classic Egg Pudding', 7.5, '传统鸡蛋布丁，口感扎实细腻。', '["Original"]'::jsonb, false, 40),
  ('classic', '抹茶布丁', 'Matcha Pudding', 8.5, '选用优质抹茶粉，微苦回甘。', '["Original"]'::jsonb, false, 50),
  ('classic', '巧克力布丁', 'Chocolate Pudding', 8.5, '浓郁巧克力布丁，丝滑入口即化。', '["Original"]'::jsonb, false, 60),
  ('toast', '布丁厚吐司', 'Pudding Thick Toast', 6.9, '厚切吐司配自家制布丁酱，外酥内软。', '["Original", "Chocolate"]'::jsonb, false, 70),
  ('toast', '炼乳厚吐司', 'Condensed Milk Toast', 6.5, '香浓炼乳淋面，香甜不腻。', '["Original"]'::jsonb, false, 80),
  ('boat', '综合水果布丁船', 'Mixed Fruit Pudding Boat', 13.9, '当季水果搭配布丁与鲜奶油，清爽多层次。', '["Original"]'::jsonb, false, 90),
  ('boat', '草莓布丁船', 'Strawberry Pudding Boat', 12.9, '新鲜草莓铺满布丁船，酸甜可口。', '["Original"]'::jsonb, false, 100),
  ('ice', '香草冰激凌布丁', 'Vanilla Ice Cream Pudding', 10.9, '香草冰激凌配布丁，冰火交融的双重口感。', '["Original", "Chocolate"]'::jsonb, false, 110),
  ('drinks', '布丁喵奶茶', 'Meow Milk Tea', 6.0, '香浓奶茶加入布丁丁，喝得到惊喜。', '["Original"]'::jsonb, false, 120),
  ('drinks', '柠檬蜜', 'Honey Lemon', 5.0, '新鲜柠檬蜂蜜调制，酸甜解腻。', '["Original"]'::jsonb, false, 130);

-- 完成。回到应用刷新即可看到菜单，下单会实时出现在 POS 待付款列表。
