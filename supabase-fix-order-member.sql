-- ============================================================================
--  布丁喵 — 补单：把漏绑会员的订单接回会员名下，并按规则补发 XP / Coin
--  用法：Supabase Dashboard → SQL Editor → 改下面两个值 → 选中整段 Run
--
--  什么时候用：顾客下单时登录态掉了（见 supabase-diagnose-member-rewards.sql
--  第 10 行「今天绑了会员的单 = 0」），订单的 member_id 是空的，买单没加分。
--
--  为什么不直接用 POS 的「调整余额」：
--    那个是凭空补一笔 admin_adjust 流水，数字能对上，但这一单在系统里仍然
--    不属于任何会员——会员的消费次数、消费金额、每周任务进度都还是漏的。
--    把 member_id 补回去再让服务端按规则结算，才是把这单真正接回去。
--
--  安全措施：
--    · 只动 member_id 还是空的订单，不会覆盖已经绑好的单
--    · 发分走 rpc_on_order_completed，里面有按订单号的幂等锁，重复跑不会多发
--    · 整段包在事务里，最后那句 commit 你确认无误再执行
-- ============================================================================

-- ── 改这两个值 ───────────────────────────────────────────────────────────────
--   订单号：POS 待付款/交易明细里那个 #0007 就填 '0007'
--   手机号：会员注册用的手机号，照 members 表里存的样子填
\set order_num '0007'
\set phone     '0123456789'
-- ─────────────────────────────────────────────────────────────────────────────
--  Supabase 的 SQL Editor 不支持 \set，所以下面直接用字面量。
--  把这两处 '这里填单号' / '这里填手机号' 替换掉即可（各出现一次）。

begin;

-- 1) 先看清楚要动哪一单、接给谁。两边都必须查得到，不然下面会报错停住。
with tgt as (
  select o.id as order_id, o.order_num, o.total, o.member_id as 原member,
         (select m.id from public.members m where m.phone = '这里填手机号') as 目标member
    from public.orders o
   where o.order_num = '这里填单号'
     and coalesce(o.ta_mode,'') not in ('recharge','reservation')
   order by o.created_at desc
   limit 1
)
select case when order_id is null    then '❌ 找不到这个单号'
            when 目标member is null   then '❌ 找不到这个手机号的会员'
            when 原member is not null then '⚠ 这单已经绑了会员，不会改动'
            else '✅ 可以补：' || order_num || ' RM' || total
       end as 检查, *
  from tgt;

-- 2) 补上 member_id（只补空的）
update public.orders o
   set member_id = (select m.id from public.members m where m.phone = '这里填手机号')
 where o.id = (select id from public.orders
                where order_num = '这里填单号'
                  and coalesce(ta_mode,'') not in ('recharge','reservation')
                order by created_at desc limit 1)
   and o.member_id is null
   and exists (select 1 from public.members where phone = '这里填手机号');

-- 3) 按规则结算 XP / Coin（金额从订单读，不手填；重复跑不会多发）
select public.rpc_on_order_completed(o.member_id, o.id::text, o.total)
  from public.orders o
 where o.order_num = '这里填单号'
   and o.member_id is not null
 order by o.created_at desc
 limit 1;

-- 4) 结果对一下：这一单发了多少、会员现在的余额
select o.order_num as 单号, m.nickname as 会员, o.total as 金额,
       coalesce((select sum(l.delta) from public.member_xp_ledger l
                  where l.ref_type='order' and l.ref_id=o.id::text),0)   as 本单XP,
       coalesce((select sum(l.delta) from public.member_coin_ledger l
                  where l.ref_type='order' and l.ref_id=o.id::text),0)   as 本单Coin,
       m.xp as 会员总XP, m.coins as 会员总Coin
  from public.orders o join public.members m on m.id = o.member_id
 where o.order_num = '这里填单号'
 order by o.created_at desc limit 1;

-- ── 看完上面四步的输出，没问题就把下面这行的注释去掉再 Run 一次整段 ──────────
-- commit;
rollback;   -- 默认回滚：先空跑一遍看结果，确认无误再改成 commit
