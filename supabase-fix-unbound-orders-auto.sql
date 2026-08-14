-- ============================================================================
--  布丁喵 — 自动补单：把「漏绑会员」的订单接回去，不用你填任何东西
--
--  用法：Supabase Dashboard → SQL Editor → 整段粘贴 → Run。就一次，没有第二步。
--        跑完最下面会出一张对账表，告诉你补了哪几单、每单发了多少分。
--
--  ⚠ Supabase 的 SQL Editor 只显示**最后一条语句**的结果，所以这份脚本
--    刻意把 commit 放在中间、把报告放在最后——不然你只会看到一句 success，
--    什么都看不到。
--
--  为什么不用填手机号：订单里带 device_id（顾客那台手机）。同一台手机以前
--  登录着下过的单是绑了会员的，靠这个就能把今天漏绑的单认回同一个人，
--  不需要你去查、去抄、去替换。
--
--  会做三件事：
--    ① 冲销你今天在 POS「调整余额」手工补的那些分（写反向流水，不删原记录）
--    ② 把认得出主人的订单补上 member_id
--    ③ 按积分规则正常结算，让消费次数/金额/每周任务也跟着对
--
--  安全措施：
--    · 只认「同一台手机、以前登录着下过单」的订单；认不出来的一律不动，
--      最后的报告里会单独列出来
--    · 只补 member_id 还是空的单，不碰已经绑好的
--    · 冲销按「会员 + 日期」幂等，结算按订单幂等——整段重复跑不会翻倍
--    · 充值单、预约单、已作废的单一律不碰
--
--  想先看看会动哪些单再决定？把下面 /* */ 里那段选中单独 Run（只读，不改数据）。
-- ============================================================================
/*
select o.order_num as 单号, o.total as 金额,
       coalesce(m.nickname || '（' || m.phone || '）', '❌ 认不出来') as 会认给谁
  from public.orders o
  left join public.members m on m.id = (
       select o2.member_id from public.orders o2
        where o2.device_id = o.device_id and o2.member_id is not null
        order by o2.created_at desc limit 1)
 where (o.created_at at time zone 'Asia/Kuala_Lumpur')::date
       = (now() at time zone 'Asia/Kuala_Lumpur')::date
   and o.member_id is null and o.device_id is not null
   and coalesce(o.ta_mode,'') not in ('recharge','reservation')
   and coalesce(o.status,'') <> 'void'
 order by o.order_num;
*/

begin;

-- ── ① 冲销今天手工补的 admin_adjust（只针对认得出主人的那些会员）──────────
--    幂等键是「会员 + 今天的日期」：同一天重复跑不会重复冲。
--    insert ... returning 出来多少就扣多少，不会照着原始那笔再冲一遍。
with tofix as (
  select (select o2.member_id from public.orders o2
           where o2.device_id = o.device_id and o2.member_id is not null
           order by o2.created_at desc limit 1) as guess
    from public.orders o
   where (o.created_at at time zone 'Asia/Kuala_Lumpur')::date
         = (now() at time zone 'Asia/Kuala_Lumpur')::date
     and o.member_id is null and o.device_id is not null
     and coalesce(o.ta_mode,'') not in ('recharge','reservation')
     and coalesce(o.status,'') <> 'void'),
     mems  as (select distinct guess as mid from tofix where guess is not null),
     today as (select to_char(now() at time zone 'Asia/Kuala_Lumpur','YYYY-MM-DD') as d),
     amt   as (select l.member_id, sum(l.delta) as delta
                 from public.member_xp_ledger l join mems on mems.mid = l.member_id
                where l.reason = 'admin_adjust'
                  and (l.created_at at time zone 'Asia/Kuala_Lumpur')::date
                      = (now() at time zone 'Asia/Kuala_Lumpur')::date
                group by 1),
     ins   as (
       insert into public.member_xp_ledger(member_id, delta, reason, ref_type, ref_id)
       select a.member_id, -a.delta, 'admin_adjust_revert', 'auto', (select d from today)
         from amt a
        where a.delta <> 0
          and not exists (select 1 from public.member_xp_ledger r
                           where r.member_id = a.member_id
                             and r.reason = 'admin_adjust_revert'
                             and r.ref_id = (select d from today))
       returning member_id, delta)
update public.members m set xp = m.xp + i.delta from ins i where m.id = i.member_id;

with tofix as (
  select (select o2.member_id from public.orders o2
           where o2.device_id = o.device_id and o2.member_id is not null
           order by o2.created_at desc limit 1) as guess
    from public.orders o
   where (o.created_at at time zone 'Asia/Kuala_Lumpur')::date
         = (now() at time zone 'Asia/Kuala_Lumpur')::date
     and o.member_id is null and o.device_id is not null
     and coalesce(o.ta_mode,'') not in ('recharge','reservation')
     and coalesce(o.status,'') <> 'void'),
     mems  as (select distinct guess as mid from tofix where guess is not null),
     today as (select to_char(now() at time zone 'Asia/Kuala_Lumpur','YYYY-MM-DD') as d),
     amt   as (select l.member_id, sum(l.delta) as delta
                 from public.member_coin_ledger l join mems on mems.mid = l.member_id
                where l.reason = 'admin_adjust'
                  and (l.created_at at time zone 'Asia/Kuala_Lumpur')::date
                      = (now() at time zone 'Asia/Kuala_Lumpur')::date
                group by 1),
     ins   as (
       insert into public.member_coin_ledger(member_id, delta, reason, ref_type, ref_id)
       select a.member_id, -a.delta, 'admin_adjust_revert', 'auto', (select d from today)
         from amt a
        where a.delta <> 0
          and not exists (select 1 from public.member_coin_ledger r
                           where r.member_id = a.member_id
                             and r.reason = 'admin_adjust_revert'
                             and r.ref_id = (select d from today))
       returning member_id, delta)
update public.members m set coins = m.coins + i.delta from ins i where m.id = i.member_id;

-- ── ② 把认得出主人的订单补上 member_id ────────────────────────────────────
with tofix as (
  select o.id, (select o2.member_id from public.orders o2
                 where o2.device_id = o.device_id and o2.member_id is not null
                 order by o2.created_at desc limit 1) as guess
    from public.orders o
   where (o.created_at at time zone 'Asia/Kuala_Lumpur')::date
         = (now() at time zone 'Asia/Kuala_Lumpur')::date
     and o.member_id is null and o.device_id is not null
     and coalesce(o.ta_mode,'') not in ('recharge','reservation')
     and coalesce(o.status,'') <> 'void')
update public.orders o set member_id = t.guess
  from tofix t
 where o.id = t.id and t.guess is not null and o.member_id is null;

-- ── ③ 按规则结算（只结还没发过分的单；RPC 本身也是幂等的）─────────────────
select public.rpc_on_order_completed(o.member_id, o.id::text, o.total)
  from public.orders o
 where (o.created_at at time zone 'Asia/Kuala_Lumpur')::date
       = (now() at time zone 'Asia/Kuala_Lumpur')::date
   and o.member_id is not null
   and coalesce(o.ta_mode,'') not in ('recharge','reservation')
   and coalesce(o.status,'') <> 'void'
   and not exists (select 1 from public.member_xp_ledger l
                    where l.ref_type = 'order' and l.ref_id = o.id::text);

commit;

-- ════════════════════════════════════════════════════════════════════════════
--  报告（放在最后，Supabase 才显示得出来）：今天每一单现在什么情况
--    会员 = ✅ 已接回 / ❌ 认不出来（需要手工指定，用 supabase-fix-order-member.sql）
-- ════════════════════════════════════════════════════════════════════════════
select o.order_num                                  as 单号,
       o.total                                      as 金额,
       coalesce(m.nickname, '❌ 没绑会员（认不出主人）') as 会员,
       coalesce((select sum(l.delta) from public.member_xp_ledger l
                  where l.ref_type='order' and l.ref_id=o.id::text), 0)  as 本单XP,
       coalesce((select sum(l.delta) from public.member_coin_ledger l
                  where l.ref_type='order' and l.ref_id=o.id::text), 0)  as 本单Coin,
       m.xp                                         as 会员总XP,
       m.coins                                      as 会员总Coin
  from public.orders o
  left join public.members m on m.id = o.member_id
 where (o.created_at at time zone 'Asia/Kuala_Lumpur')::date
       = (now() at time zone 'Asia/Kuala_Lumpur')::date
   and coalesce(o.ta_mode,'') not in ('recharge','reservation')
   and coalesce(o.status,'') <> 'void'
 order by o.order_num;
