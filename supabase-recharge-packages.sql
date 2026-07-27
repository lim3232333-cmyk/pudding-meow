-- ============================================================================
--  布丁喵 — 充值套餐搬进数据库（POS 可改，小程序跟着走）
--  用法：Supabase Dashboard → SQL Editor → New query → 粘贴 → Run（跑一次）
--
--  原本这六档是分别写死在 pudding-meow.html 的 RECHARGE_PACKAGES 和
--  pos.html 的 POS_TOPUP_PKGS 里——两份，改价得改两个文件、还容易改漏一边。
--  现在统一放这张表，POS「会员运营 → 充值套餐」维护，小程序和收银台都读它。
--
--  gifts 是「更多赠品」，就是充值卡左下角那个小图标点开的浮层，
--  存成一个字符串数组，如 ["50 XP","1x 幸运抽奖"]。纯展示文案：
--  真正发 XP / 抽奖券要另外接规则，这里不代表系统会自动发。
-- ============================================================================

create table if not exists public.recharge_packages (
  id         uuid primary key default gen_random_uuid(),
  price      numeric not null,          -- 顾客实付 RM，钱包按这个数 1:1 到账
  coins      int not null default 0,    -- 额外送的 Meow Coin
  tag        text,                      -- 卡片右上角的小标签，如「首充双倍」；留空不显示
  first_only boolean not null default false,  -- 标签只在顾客还没充过值时显示
  gifts      jsonb not null default '[]'::jsonb,
  enabled    boolean not null default true,
  sort_order int not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists recharge_packages_sort_idx on public.recharge_packages (sort_order);

alter table public.recharge_packages enable row level security;
drop policy if exists recharge_packages_anon_read on public.recharge_packages;
create policy recharge_packages_anon_read on public.recharge_packages for select to anon using (true);
drop policy if exists recharge_packages_anon_write on public.recharge_packages;
create policy recharge_packages_anon_write on public.recharge_packages for all to anon using (true) with check (true);

do $$
begin
  alter publication supabase_realtime add table public.recharge_packages;
exception when duplicate_object then null;
end $$;

-- 种子：跟原本写死的六档一模一样，跑完线上行为不变。
-- 表里已经有数据就不动（避免重复跑覆盖掉店家改过的价）。
insert into public.recharge_packages (price, coins, tag, first_only, gifts, sort_order)
select * from (values
  ( 50::numeric,  50, '首充双倍', true,  '["50 XP","1x 幸运抽奖"]'::jsonb, 10),
  (100::numeric, 120, null,       false, '[]'::jsonb, 20),
  (150::numeric, 200, null,       false, '[]'::jsonb, 30),
  (200::numeric, 300, null,       false, '[]'::jsonb, 40),
  (250::numeric, 450, null,       false, '[]'::jsonb, 50),
  (300::numeric, 600, null,       false, '[]'::jsonb, 60)
) as v(price, coins, tag, first_only, gifts, sort_order)
where not exists (select 1 from public.recharge_packages);

-- 完成。POS「会员运营 → 充值套餐」改价改赠品，小程序充值页和收银台 Top up 都跟着变。
