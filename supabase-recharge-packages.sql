-- ============================================================================
--  布丁喵 — 充值套餐搬进数据库（POS 可改，小程序跟着走）
--  用法：Supabase Dashboard → SQL Editor → New query → 粘贴 → Run（跑一次）
--
--  原本这六档是分别写死在 pudding-meow.html 的 RECHARGE_PACKAGES 和
--  pos.html 的 POS_TOPUP_PKGS 里——两份，改价得改两个文件、还容易改漏一边。
--  现在统一放这张表，POS「会员运营 → 充值套餐」维护，小程序和收银台都读它。
--
--  一档套餐＝一整包：充 RM50 → 钱包进 RM50 + 500 Coin + 1 次幸运抽奖 + 50 XP。
--  coins / xp / draw_tickets 是系统真会发的，充值时由服务端照着这一行发。
--  gifts 留给系统发不了的东西（如「送一杯饮料」），纯文案，需要店员另外兑现。
--  卡片左下角那个浮层会先自动列出 xp / 抽奖券，再接上 gifts 里的文案，
--  所以不用手写「50 XP」——写了反而容易跟实际发的对不上。
-- ============================================================================

create table if not exists public.recharge_packages (
  id         uuid primary key default gen_random_uuid(),
  price      numeric not null,          -- 顾客实付 RM，钱包按这个数 1:1 到账
  coins      int not null default 0,    -- 送的 Meow Coin
  xp         int not null default 0,    -- 送的成长值
  draw_tickets int not null default 0,  -- 送几次幸运抽奖
  tag        text,                      -- 卡片右上角的小标签，如「首充双倍」；留空不显示
  first_only boolean not null default false,  -- 标签只在顾客还没充过值时显示
  gifts      jsonb not null default '[]'::jsonb,
  enabled    boolean not null default true,
  sort_order int not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists recharge_packages_sort_idx on public.recharge_packages (sort_order);
-- 已经跑过旧版本的：把后加的两列补上
alter table public.recharge_packages add column if not exists xp int not null default 0;
alter table public.recharge_packages add column if not exists draw_tickets int not null default 0;

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
insert into public.recharge_packages (price, coins, xp, draw_tickets, tag, first_only, gifts, sort_order)
select * from (values
  ( 50::numeric,  50,  50, 1, '首充双倍', true,  '[]'::jsonb, 10),
  (100::numeric, 120, 100, 1, null,       false, '[]'::jsonb, 20),
  (150::numeric, 200, 150, 2, null,       false, '[]'::jsonb, 30),
  (200::numeric, 300, 200, 2, null,       false, '[]'::jsonb, 40),
  (250::numeric, 450, 250, 3, null,       false, '[]'::jsonb, 50),
  (300::numeric, 600, 300, 3, null,       false, '[]'::jsonb, 60)
) as v(price, coins, xp, draw_tickets, tag, first_only, gifts, sort_order)
where not exists (select 1 from public.recharge_packages);

-- 完成。POS「会员运营 → 充值套餐」改价改赠品，小程序充值页和收银台 Top up 都跟着变。
