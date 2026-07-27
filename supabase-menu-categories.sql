-- ============================================================================
--  布丁喵 — 菜单分类：分类本身搬进数据库，后台可自己增删，并且支持两级
--  用法：Supabase Dashboard → SQL Editor → New query → 粘贴 → Run（跑一次）
--
--  背景：分类原本写死在两个 HTML 里（小程序 CAT_ORDER/CAT_META、收银 POS_CATS/POS_CATN），
--  想把「饮料」拆成奶茶 / 咖啡 / 果茶气泡就得改代码。现在分类是数据行：
--    parent_code 为 null  = 顶级分类（小程序左侧分类栏 / 收银首页的大卡片）
--    parent_code 有值      = 该顶级分类下的子分类（如 饮料 → 奶茶）
--  商品用 menu_items.cat 认顶级分类、menu_items.subcat 认子分类（可留空 = 不分子分类）。
--
--  code 和销售渠道一样：建好之后不给改——商品行存的是 code，改了就全部对不上。
--  改中英文名、排序、停用都可以。
--  enabled=false = 顾客端和收银台都不显示，但后台还看得见（临时下架整个分类用）。
-- ============================================================================

create table if not exists public.menu_categories (
  id          uuid primary key default gen_random_uuid(),
  code        text unique not null,
  name        text not null,
  name_en     text,
  parent_code text,                                -- null = 顶级；有值 = 挂在这个顶级分类下
  enabled     boolean not null default true,
  sort_order  int not null default 0,
  created_at  timestamptz not null default now()
);
create index if not exists menu_categories_parent_idx on public.menu_categories (parent_code, sort_order);

alter table public.menu_categories enable row level security;
drop policy if exists menu_categories_anon_read on public.menu_categories;
create policy menu_categories_anon_read on public.menu_categories for select to anon using (true);
drop policy if exists menu_categories_anon_write on public.menu_categories;
create policy menu_categories_anon_write on public.menu_categories for all to anon using (true) with check (true);

-- 商品挂在哪个子分类（存子分类的 code；null/'' = 只挂在顶级分类下，不分子分类）
alter table public.menu_items add column if not exists subcat text;
create index if not exists menu_items_subcat_idx on public.menu_items (subcat);

-- 把现在写死的 7 个顶级分类灌进来。已存在就不动（保住店家改过的名字和排序）
insert into public.menu_categories (code, name, name_en, parent_code, sort_order) values
  ('special',  '精选系列',     'Special',            null, 10),
  ('classic',  '经典系列',     'Classic',            null, 20),
  ('toast',    '吐司',         'Toast',              null, 30),
  ('boat',     '布丁船',       'Pudding Boat',       null, 40),
  ('ice',      '冰激凌布丁',   'Ice Cream Pudding',  null, 50),
  ('preorder', '预订',         'Preorder',           null, 60),
  ('drinks',   '饮料',         'Drinks',             null, 70)
on conflict (code) do nothing;

-- ── 可选：饮料的子分类范例 ────────────────────────────────────────────────
-- 这几行故意注释掉：子分类在 POS「菜单管理 → 分类管理」里点两下就能加，
-- 想直接用这套分法的话，把下面三行的注释去掉再 Run 一次即可。
-- insert into public.menu_categories (code, name, name_en, parent_code, sort_order) values
--   ('dk_milktea', '奶茶·鲜奶',  'Milk Tea',     'drinks', 10),
--   ('dk_coffee',  '咖啡',       'Coffee',       'drinks', 20),
--   ('dk_fruit',   '果茶·气泡',  'Fruit & Soda', 'drinks', 30)
-- on conflict (code) do nothing;

-- 分类表也进实时推送，后台改完小程序/收银台不用刷新
do $$
begin
  alter publication supabase_realtime add table public.menu_categories;
exception when duplicate_object then null;
end $$;

-- 完成。POS「菜单管理 → 分类管理」维护分类；商品表单里选顶级分类 + 子分类。
