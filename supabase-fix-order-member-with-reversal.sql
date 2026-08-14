-- ============================================================================
--  布丁喵 — 补单（已经用 POS「调整余额」手工补过分的版本）
--  用法：Supabase Dashboard → SQL Editor → 改下面三处占位 → 选中整段 Run
--
--  什么时候用这一份：顾客那单漏绑会员、你已经在 POS 后台用「调整余额」
--  手工把 XP/Coin 加上去了，现在想让这单在系统里也真正归到会员名下
--  （会员的消费次数、消费金额、每周任务进度才跟着对）。
--
--  直接跑 supabase-fix-order-member.sql 会变成双份：手工那笔还在，
--  订单结算又发一笔。所以这一份先把手工那笔冲掉，再走正常结算。
--
--  冲销方式是**写一笔相反的流水**，不是删掉原记录——账要留痕，
--  以后翻流水能看到「补过、又冲掉、然后按订单正常发」这条完整链路。
--
--  安全措施：
--    · 默认结尾是 rollback：先空跑一遍看四步输出，确认无误再改成 commit
--    · 只冲销「今天、这个会员、reason='admin_adjust'」的流水；第 1 步会把
--      它们列出来给你核对，别的调整不受影响
--    · 补 member_id 只补空的，不覆盖已经绑好的单
--    · 发分走 rpc_on_order_completed，按订单号幂等，重复跑不会多发
-- ============================================================================

--  要改的三处（每处只出现一次，用编辑器替换即可）：
--    '这里填单号'    ← POS 交易明细里那个 #0007 就填 '0007'
--    '这里填手机号'  ← 会员注册用的手机号，照 members 表里存的样子填

begin;

-- ── 1) 先看清楚：要冲掉哪几笔手工调整、要把哪一单接给谁 ────────────────────
with mem as (select id, nickname, xp, coins from public.members where phone = '这里填手机号'),
     ord as (select o.id, o.order_num, o.total, o.member_id
               from public.orders o
              where o.order_num = '这里填单号'
                and coalesce(o.ta_mode,'') not in ('recharge','reservation')
              order by o.created_at desc limit 1)
select (select nickname from mem)                         as 会员,
       (select order_num from ord)                        as 单号,
       (select total from ord)                            as 金额,
       ((select member_id from ord) is not null)          as 单子已绑会员,
       coalesce((select sum(l.delta) from public.member_xp_ledger l
                  where l.member_id = (select id from mem) and l.reason = 'admin_adjust'
                    and (l.created_at at time zone 'Asia/Kuala_Lumpur')::date
                        = (now() at time zone 'Asia/Kuala_Lumpur')::date), 0)  as 今天手工补的XP,
       coalesce((select sum(l.delta) from public.member_coin_ledger l
                  where l.member_id = (select id from mem) and l.reason = 'admin_adjust'
                    and (l.created_at at time zone 'Asia/Kuala_Lumpur')::date
                        = (now() at time zone 'Asia/Kuala_Lumpur')::date), 0)  as 今天手工补的Coin,
       (select xp from mem)                               as 当前总XP,
       (select coins from mem)                            as 当前总Coin,
       case when (select id from mem) is null   then '❌ 找不到这个手机号的会员'
            when (select id from ord) is null   then '❌ 找不到这个单号'
            when (select member_id from ord) is not null then '⚠ 这单已经绑了会员，只会冲销、不会重绑'
            else '✅ 可以补' end                            as 检查;

-- ── 2) 冲销今天那几笔手工 admin_adjust（写反向流水，不删原记录）────────────
--    写入和扣余额放在同一条语句里：insert ... returning 出来多少就扣多少。
--    这样整段重复跑也安全——已经冲销过（同一单已有 admin_adjust_revert）就
--    什么都不插，update 也跟着落空。分两步写的话，第二次跑会照着原始那笔
--    admin_adjust 再冲一次，余额直接冲成负数。
with mem as (select id from public.members where phone = '这里填手机号'),
     amt as (
       select coalesce(sum(l.delta),0) as d
         from public.member_xp_ledger l
        where l.member_id = (select id from mem) and l.reason = 'admin_adjust'
          and (l.created_at at time zone 'Asia/Kuala_Lumpur')::date
              = (now() at time zone 'Asia/Kuala_Lumpur')::date
     ),
     ins as (
       insert into public.member_xp_ledger(member_id, delta, reason, ref_type, ref_id)
       select (select id from mem), -(select d from amt), 'admin_adjust_revert', 'order', '这里填单号'
        where (select d from amt) <> 0
          and not exists (select 1 from public.member_xp_ledger r
                           where r.member_id = (select id from mem)
                             and r.reason = 'admin_adjust_revert' and r.ref_id = '这里填单号')
       returning member_id, delta
     )
update public.members m set xp = m.xp + (select delta from ins)
 where m.id = (select member_id from ins);

with mem as (select id from public.members where phone = '这里填手机号'),
     amt as (
       select coalesce(sum(l.delta),0) as d
         from public.member_coin_ledger l
        where l.member_id = (select id from mem) and l.reason = 'admin_adjust'
          and (l.created_at at time zone 'Asia/Kuala_Lumpur')::date
              = (now() at time zone 'Asia/Kuala_Lumpur')::date
     ),
     ins as (
       insert into public.member_coin_ledger(member_id, delta, reason, ref_type, ref_id)
       select (select id from mem), -(select d from amt), 'admin_adjust_revert', 'order', '这里填单号'
        where (select d from amt) <> 0
          and not exists (select 1 from public.member_coin_ledger r
                           where r.member_id = (select id from mem)
                             and r.reason = 'admin_adjust_revert' and r.ref_id = '这里填单号')
       returning member_id, delta
     )
update public.members m set coins = m.coins + (select delta from ins)
 where m.id = (select member_id from ins);

-- ── 3) 把订单接回会员名下（只补空的），再按规则正常结算 ────────────────────
update public.orders o
   set member_id = (select id from public.members where phone = '这里填手机号')
 where o.id = (select id from public.orders
                where order_num = '这里填单号'
                  and coalesce(ta_mode,'') not in ('recharge','reservation')
                order by created_at desc limit 1)
   and o.member_id is null
   and exists (select 1 from public.members where phone = '这里填手机号');

select public.rpc_on_order_completed(o.member_id, o.id::text, o.total)
  from public.orders o
 where o.order_num = '这里填单号'
   and o.member_id is not null
 order by o.created_at desc limit 1;

-- ── 4) 核对：这一单发了多少、会员最终余额 ──────────────────────────────────
select o.order_num as 单号, m.nickname as 会员, o.total as 金额,
       coalesce((select sum(l.delta) from public.member_xp_ledger l
                  where l.ref_type='order' and l.ref_id=o.id::text
                    and l.reason <> 'admin_adjust_revert'), 0)  as 本单XP,
       coalesce((select sum(l.delta) from public.member_coin_ledger l
                  where l.ref_type='order' and l.ref_id=o.id::text
                    and l.reason <> 'admin_adjust_revert'), 0)  as 本单Coin,
       m.xp as 会员总XP, m.coins as 会员总Coin
  from public.orders o join public.members m on m.id = o.member_id
 where o.order_num = '这里填单号'
 order by o.created_at desc limit 1;

-- ── 看完上面四步，数字对了就把下面两行对调（注释掉 rollback、放开 commit）──
-- commit;
rollback;
