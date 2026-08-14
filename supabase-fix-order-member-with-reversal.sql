-- ============================================================================
--  布丁喵 — 补单（已经用 POS「调整余额」手工补过分的版本）
--  用法：Supabase Dashboard → SQL Editor → 替换两个占位 → 选中整段 Run
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
--    · 手机号匹配到**多于一个会员就整段什么都不做**（第 1 步会告诉你匹配到几个）
--      ——补错人比补不上严重得多
--    · 只冲销「今天、这个会员、reason='admin_adjust'」的流水
--    · 补 member_id 只补空的，不覆盖已经绑好的单
--    · 冲销和发分都是幂等的，整段重复跑不会翻倍
-- ============================================================================

--  要替换的两个占位（用编辑器「全部替换」，每个出现好几处）：
--    '这里填单号'    ← POS 交易明细里那个 #0007 就填 '0007'（不带 #）
--    '这里填手机号'  ← 顾客手机号。格式不用管：+60 / 0 开头 / 空格横杠都会先归一
--                      再精确比对，不是模糊匹配（模糊会撞到后几位相同的另一个人）
--
--  ── 第 0 步：不确定该填什么？把下面这段**选中**单独 Run ────────────────────
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
-- ─────────────────────────────────────────────────────────────────────────────

begin;

-- ── 1) 先看清楚：匹配到几个会员、要冲掉多少、要把哪一单接给谁 ──────────────
--    「匹配到的会员数」不是 1 的话，下面几步会自动跳过，先把手机号填完整再来。
with cand as (
       select id, phone, nickname, xp, coins from public.members
        where regexp_replace(regexp_replace(regexp_replace(phone,'\D','','g'),'^60',''),'^0','')
              = regexp_replace(regexp_replace(regexp_replace('这里填手机号','\D','','g'),'^60',''),'^0','')),
     mem  as (select * from cand where (select count(*) from cand) = 1),
     ord  as (select o.id, o.order_num, o.total, o.member_id
                from public.orders o
               where o.order_num = '这里填单号'
                 and coalesce(o.ta_mode,'') not in ('recharge','reservation')
               order by o.created_at desc limit 1)
select '这里填单号'                                       as 你填的单号,
       '这里填手机号'                                     as 你填的手机号,
       (select count(*) from cand)                        as 匹配到的会员数,
       (select string_agg(phone||'('||nickname||')', '、') from cand) as 匹配到谁,
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
       case when regexp_replace('这里填手机号','\D','','g') = ''
                 then '❌ 手机号占位符没替换（填的内容里一个数字都没有）。用编辑器的「全部替换」——它在文件里出现好几处，只改第一处是不够的'
            when (select count(*) from cand) = 0 then '❌ 这个手机号在会员表里找不到（对一下上面「你填的手机号」，再用第 0 步查真实号码）'
            when (select count(*) from cand) > 1 then '❌ 匹配到多个会员，请把手机号填完整（本次不会改动任何数据）'
            when (select id from ord) is null    then '❌ 找不到这个单号（对一下上面「你填的单号」：别带 #，也别漏了替换）'
            when (select member_id from ord) is not null then '⚠ 这单已经绑了会员，只会冲销、不会重绑'
            else '✅ 可以补' end                            as 检查;

-- ── 2) 冲销今天那几笔手工 admin_adjust（写反向流水，不删原记录）────────────
--    写入和扣余额放在同一条语句里：insert ... returning 出来多少就扣多少。
--    这样整段重复跑也安全——已经冲销过（同一单已有 admin_adjust_revert）就
--    什么都不插，update 也跟着落空。分两步写的话，第二次跑会照着原始那笔
--    admin_adjust 再冲一次，余额直接冲成负数。
with cand as (
       select id from public.members
        where regexp_replace(regexp_replace(regexp_replace(phone,'\D','','g'),'^60',''),'^0','')
              = regexp_replace(regexp_replace(regexp_replace('这里填手机号','\D','','g'),'^60',''),'^0','')),
     mem  as (select * from cand where (select count(*) from cand) = 1),
     amt  as (select coalesce(sum(l.delta),0) as d
                from public.member_xp_ledger l
               where l.member_id = (select id from mem) and l.reason = 'admin_adjust'
                 and (l.created_at at time zone 'Asia/Kuala_Lumpur')::date
                     = (now() at time zone 'Asia/Kuala_Lumpur')::date),
     ins  as (
       insert into public.member_xp_ledger(member_id, delta, reason, ref_type, ref_id)
       select (select id from mem), -(select d from amt), 'admin_adjust_revert', 'order', '这里填单号'
        where (select id from mem) is not null
          and (select d from amt) <> 0
          and not exists (select 1 from public.member_xp_ledger r
                           where r.member_id = (select id from mem)
                             and r.reason = 'admin_adjust_revert' and r.ref_id = '这里填单号')
       returning member_id, delta)
update public.members m set xp = m.xp + (select delta from ins)
 where m.id = (select member_id from ins);

with cand as (
       select id from public.members
        where regexp_replace(regexp_replace(regexp_replace(phone,'\D','','g'),'^60',''),'^0','')
              = regexp_replace(regexp_replace(regexp_replace('这里填手机号','\D','','g'),'^60',''),'^0','')),
     mem  as (select * from cand where (select count(*) from cand) = 1),
     amt  as (select coalesce(sum(l.delta),0) as d
                from public.member_coin_ledger l
               where l.member_id = (select id from mem) and l.reason = 'admin_adjust'
                 and (l.created_at at time zone 'Asia/Kuala_Lumpur')::date
                     = (now() at time zone 'Asia/Kuala_Lumpur')::date),
     ins  as (
       insert into public.member_coin_ledger(member_id, delta, reason, ref_type, ref_id)
       select (select id from mem), -(select d from amt), 'admin_adjust_revert', 'order', '这里填单号'
        where (select id from mem) is not null
          and (select d from amt) <> 0
          and not exists (select 1 from public.member_coin_ledger r
                           where r.member_id = (select id from mem)
                             and r.reason = 'admin_adjust_revert' and r.ref_id = '这里填单号')
       returning member_id, delta)
update public.members m set coins = m.coins + (select delta from ins)
 where m.id = (select member_id from ins);

-- ── 3) 把订单接回会员名下（只补空的），再按规则正常结算 ────────────────────
with cand as (
       select id from public.members
        where regexp_replace(regexp_replace(regexp_replace(phone,'\D','','g'),'^60',''),'^0','')
              = regexp_replace(regexp_replace(regexp_replace('这里填手机号','\D','','g'),'^60',''),'^0','')),
     mem  as (select * from cand where (select count(*) from cand) = 1)
update public.orders o
   set member_id = (select id from mem)
 where o.id = (select id from public.orders
                where order_num = '这里填单号'
                  and coalesce(ta_mode,'') not in ('recharge','reservation')
                order by created_at desc limit 1)
   and o.member_id is null
   and (select id from mem) is not null;

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
