-- ============================================================================
--  布丁喵 — 手续费（把 HitPay 的支付手续费转嫁给顾客）
--  用法：Supabase Dashboard → SQL Editor → 整段粘贴 → Run。跑一次就好，可重复跑。
--
--  为什么只有 HitPay 收：
--    这笔钱不是店家的营业额，是原封不动付给 HitPay 的通道费。所以只有真的走了
--    HitPay 的单才收——钱包支付扣的是店内余额、柜台收的是现金，店家零成本，
--    再收手续费就是乱收钱了。这个判断在两个前端里都做（付款方式以 hp_ 开头才收）。
--
--  费率照抄 HitPay 公开费率表（马来西亚），有固定几毛就照收几毛：
--    Touch n Go            1.9%
--    Online Banking (FPX)  1.8% + RM0.40
--    信用卡/借记卡（本地）  1.2% + RM1.00
--
--  ⚠ 信用卡那一行只能按**本地卡**算。HitPay 的外国卡是 3% + RM1，但顾客点
--    「信用卡」的时候还没刷卡，前端无从知道是哪种；按 3% 收会让本地卡的顾客
--    多付 1.8%。所以按本地卡收，外国卡的差价店家自己吃。要改就改下面的 pct。
--
--  ⚠ 严格来说店家还是差一点点：手续费加上去之后，HitPay 是按**加完的新总额**
--    抽的，所以照抄 1.9% 实际只收回 1.9/(1+1.9%) ≈ 1.864%。一张 RM30 的 TNG 单
--    差 RM0.01。刻意不做这个 gross-up——为了那一分钱把费率写成 1.937% 这种数字，
--    顾客看着莫名其妙，解释成本比那一分钱贵。
-- ============================================================================

-- ── 1) 费率表：放在 shop_settings（单行配置表），POS 后台可改 ────────────────
--     用 jsonb 而不是一堆列：以后 HitPay 加一种付款方式，加一个 key 就行，
--     不用再动表结构、也不用两个前端一起改。
alter table public.shop_settings
  add column if not exists admin_fee_rates jsonb not null default '{
    "hp_tng":  {"pct": 1.9, "fixed": 0},
    "hp_fpx":  {"pct": 1.8, "fixed": 0.40},
    "hp_card": {"pct": 1.2, "fixed": 1.00}
  }'::jsonb;

--     兜底：add column ... default 会把默认值补进已有的行，所以正常情况下这句
--     一行都不会动（跑出来是 UPDATE 0，正常）。它是为了那种「以前手工加过这一列、
--     但没给默认值」的库。刻意只在 null / 空对象时才写——你在 POS 改过的费率
--     不能被重跑这份脚本冲回默认值。
update public.shop_settings
   set admin_fee_rates = '{
    "hp_tng":  {"pct": 1.9, "fixed": 0},
    "hp_fpx":  {"pct": 1.8, "fixed": 0.40},
    "hp_card": {"pct": 1.2, "fixed": 1.00}
  }'::jsonb
 where id = 1 and (admin_fee_rates is null or admin_fee_rates = '{}'::jsonb);

-- ── 2) 订单上单独存一份手续费 ──────────────────────────────────────────────
--     它已经含在 orders.total 里（顾客付的就是含手续费的总额），单独再存一列是
--     为了事后能把它拆出来：营业额要扣掉它（那笔钱转手就给 HitPay 了），会员的
--     XP/Coin 也要按扣掉它之后的金额发，不然等于替通道费倒贴积分。
--     不重算而是存下来：费率以后会改，重算会把历史单的账改掉。
alter table public.orders
  add column if not exists admin_fee numeric(10,2) not null default 0;

comment on column public.orders.admin_fee is
  '本单向顾客收取的支付手续费（HitPay 通道费转嫁），已含在 total 里。非 HitPay 支付为 0。';

-- ── 3) 对账用：看看费率现在是什么、今天收了多少手续费 ──────────────────────
select (select admin_fee_rates from public.shop_settings where id = 1) as 当前费率,
       coalesce(sum(o.admin_fee), 0)                                   as 今天收到的手续费,
       count(*) filter (where o.admin_fee > 0)                         as 收了手续费的单数
  from public.orders o
 where (o.created_at at time zone 'Asia/Kuala_Lumpur')::date
       = (now() at time zone 'Asia/Kuala_Lumpur')::date
   and coalesce(o.status,'') <> 'void';
