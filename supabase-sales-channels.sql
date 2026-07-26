-- ============================================================================
--  布丁喵 — 销售渠道：商品 / 规格组可以只开放给某些点餐方式
--  用法：Supabase Dashboard → SQL Editor → New query → 粘贴 → Run（跑一次）
--
--  背景：有些品项不适合打包或外送（冰淇淋化、吐司软掉），但系统原本没地方表达，
--  只有一个「下架」是全渠道一刀切。现在商品和规格组都能勾选开放给哪些渠道。
--
--  三个内置渠道 dinein / pickup / delivery 的 code 跟小程序的 currentMode 一一对应，
--  改名可以，code 不能改——改了小程序就对不上，等于把商品藏起来。
--  自建渠道（预订、团购…）现在只是后台标签：小程序只有堂食/自取/外卖三个入口，
--  勾了自建渠道不会让商品在小程序多出来一个卖法，等以后真做了对应入口才生效。
--
--  channels 为 null 或空数组 = 全渠道开放。老数据不用回填，默认继续到处都能卖。
-- ============================================================================

create table if not exists public.sales_channels (
  id         uuid primary key default gen_random_uuid(),
  code       text unique not null,
  name       text not null,
  name_en    text,
  builtin    boolean not null default false,   -- 内置三个：能改名、不能删、code 锁死
  enabled    boolean not null default true,
  sort_order int not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists sales_channels_sort_idx on public.sales_channels (sort_order);

alter table public.sales_channels enable row level security;
drop policy if exists sales_channels_anon_read on public.sales_channels;
create policy sales_channels_anon_read on public.sales_channels for select to anon using (true);
drop policy if exists sales_channels_anon_write on public.sales_channels;
create policy sales_channels_anon_write on public.sales_channels for all to anon using (true) with check (true);

-- 内置三个渠道。已经存在就不动（保住店家改过的名字和排序）
insert into public.sales_channels (code, name, name_en, builtin, sort_order) values
  ('dinein',   '堂食', 'Dine In',   true, 10),
  ('pickup',   '自取', 'Pickup',    true, 20),
  ('delivery', '外卖', 'Delivery',  true, 30)
on conflict (code) do nothing;

-- 商品 / 规格组各自的开放渠道（存 code 数组，如 ["dinein","pickup"]）
alter table public.menu_items add column if not exists channels jsonb;
alter table public.spec_defs  add column if not exists channels jsonb;

-- 渠道表也进实时推送，后台改完小程序不用刷新
do $$
begin
  alter publication supabase_realtime add table public.sales_channels;
exception when duplicate_object then null;
end $$;

-- 完成。POS「菜单管理 → 销售方式」维护渠道；商品表单和规格组里勾选开放范围。
