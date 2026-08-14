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

-- ╔══════════════════════════════════════════════════════════════════════════╗
-- ║  ★ 只改这两行，别的地方一个字都不用动 ★                                  ║
-- ╚══════════════════════════════════════════════════════════════════════════╝
drop table if exists _fix;
create temp table _fix as
select '0007'::text        as ord_num,   -- ★ 订单号：POS 上 #0007 就写 0007（不要 #）
       '0123456789'::text  as phone;     -- ★ 顾客手机号：格式随便，+60 / 0 开头 / 带空格横杠都认
-- ─────────────────────────────────────────────────────────────────────────────
--  下面全部按上面这两个值跑，不用再替换任何东西。
--  （以前是把值散在十几处让你手动替换，太容易漏，所以改成收在这一张临时表里。）

--  ── 第 0 步：不知道该填什么？把下面这段**选中**单独 Run，照着抄 ───────────
/*
select '订单' as 类型, o.order_num as 单号或手机, o.created_at::text as 时间,
       o.total::text as 金额, coalesce(o.member_id::text,'(没绑会员)') as 备注
  from public.orders o
 where o.created_at >= now() - interval '2 days'
   and coalesce(o.ta_mode,'') not in ('recharge','reservation')
union all
select '会员', m.phone, m.nickname, m.xp::text || ' XP', m.coins::text || ' Coin'
  from public.members m
 order by 1, 3 desc;
*/

begin;

-- 1) 先看清楚要动哪一单、接给谁。两边都必须查得到，不然下面会报错停住。
with p    as (select * from _fix),
     cand as (select m.id, m.phone, m.nickname from public.members m, p
               where regexp_replace(regexp_replace(regexp_replace(m.phone,'\D','','g'),'^60',''),'^0','')
                   = regexp_replace(regexp_replace(regexp_replace(p.phone ,'\D','','g'),'^60',''),'^0','')),
     mem  as (select * from cand where (select count(*) from cand) = 1),
     tgt  as (select o.id as order_id, o.order_num, o.total, o.member_id as 原member
                from public.orders o, p
               where o.order_num = p.ord_num
                 and coalesce(o.ta_mode,'') not in ('recharge','reservation')
               order by o.created_at desc limit 1)
select (select ord_num from p) as 你填的单号, (select phone from p) as 你填的手机号,
       (select count(*) from cand) as 匹配到的会员数,
       (select string_agg(phone||'('||nickname||')','、') from cand) as 匹配到谁,
       t.order_num as 单号, t.total as 金额, (t.原member is not null) as 单子已绑会员,
       case when (select count(*) from cand) = 0 then '❌ 这个手机号在会员表里找不到（对一下上面「你填的手机号」，再用第 0 步查真实号码）'
            when (select count(*) from cand) > 1 then '❌ 匹配到多个会员，请把手机号填完整（本次不会改动任何数据）'
            when t.order_id is null   then '❌ 找不到这个单号（对一下上面「你填的单号」：别带 #，也别漏了替换）'
            when t.原member is not null then '⚠ 这单已经绑了会员，不会改动'
            else '✅ 可以补' end as 检查
  from tgt t;

-- 2) 补上 member_id（只补空的）
with p    as (select * from _fix),
     cand as (select m.id from public.members m, p
               where regexp_replace(regexp_replace(regexp_replace(m.phone,'\D','','g'),'^60',''),'^0','')
                   = regexp_replace(regexp_replace(regexp_replace(p.phone ,'\D','','g'),'^60',''),'^0','')),
     mem  as (select * from cand where (select count(*) from cand) = 1)
update public.orders o
   set member_id = (select id from mem)
 where o.id = (select o2.id from public.orders o2, p
                where o2.order_num = p.ord_num
                  and coalesce(o2.ta_mode,'') not in ('recharge','reservation')
                order by o2.created_at desc limit 1)
   and o.member_id is null
   and (select id from mem) is not null;

-- 3) 按规则结算 XP / Coin（金额从订单读，不手填；重复跑不会多发）
select public.rpc_on_order_completed(o.member_id, o.id::text, o.total)
  from public.orders o, _fix p
 where o.order_num = p.ord_num
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
  from public.orders o
  join public.members m on m.id = o.member_id
  join _fix p on o.order_num = p.ord_num
 order by o.created_at desc limit 1;

-- ── 看完上面四步的输出，没问题就把下面这行的注释去掉再 Run 一次整段 ──────────
-- commit;
rollback;   -- 默认回滚：先空跑一遍看结果，确认无误再改成 commit
