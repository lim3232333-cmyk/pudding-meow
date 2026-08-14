-- ============================================================================
--  布丁喵 — 自动补单：把「漏绑会员」的订单接回去，不用你填任何东西
--  用法：Supabase Dashboard → SQL Editor → 整段粘贴 → Run。看结果，没问题
--        再把最后的 rollback 改成 commit 重跑一次。就这两步。
--
--  为什么不用填手机号：订单里带 device_id（顾客那台手机）。同一台手机以前
--  登录着下过的单是绑了会员的，靠这个就能把今天漏绑的单认回同一个人，
--  不需要你去查、去抄、去替换。
--
--  会做三件事：
--    ① 冲销你今天在 POS「调整余额」手工补的那些分（写一笔反向流水，不删原记录）
--    ② 把认得出主人的订单补上 member_id
--    ③ 按积分规则正常结算，让消费次数/金额/每周任务也跟着对
--
--  安全措施：
--    · 默认 rollback：先空跑看报告，确认了再改 commit
--    · 只认「同一台手机、以前登录着下过单」的订单；认不出来的会单独列出来，
--      绝不瞎猜绑给谁
--    · 只补 member_id 还是空的单，不动已经绑好的
--    · 冲销按「会员 + 日期」幂等，结算按订单幂等，整段重复跑不会翻倍
--    · 充值单、预约单、已作废的单一律不碰
-- ============================================================================

begin;

-- ── 报告 1：今天漏绑会员的单，以及系统认为它属于谁 ────────────────────────
--    「认出的会员」有值 = 待会会自动补给这个人；为空 = 认不出来（比如这台手机
--    从来没登录过），那种得用 supabase-fix-order-member.sql 手工指定。
with tofix as (
  select o.id, o.order_num, o.total, o.device_id,
         (select o2.member_id from public.orders o2
           where o2.device_id = o.device_id and o2.member_id is not null
           order by o2.created_at desc limit 1) as guess
    from public.orders o
   where (o.created_at at time zone 'Asia/Kuala_Lumpur')::date
         = (now() at time zone 'Asia/Kuala_Lumpur')::date
     and o.member_id is null
     and o.device_id is not null
     and coalesce(o.ta_mode,'') not in ('recharge','reservation')
     and coalesce(o.status,'') <> 'void')
select t.order_num                                as 单号,
       t.total                                    as 金额,
       coalesce(m.nickname || '（' || m.phone || '）', '❌ 认不出来，需要手工指定') as 认出的会员
  from tofix t left join public.members m on m.id = t.guess
 order by t.order_num;

-- ── ① 冲销今天手工补的 admin_adjust（只针对上面认出来的那些会员）──────────
--    幂等键是「会员 + 今天的日期」：同一天重复跑不会重复冲。
--    insert ... returning 出来多少就扣多少，不会照着原始那笔再冲一遍。
with tofix as (
  select o.id, (select o2.member_id from public.orders o2
                 where o2.device_id = o.device_id and o2.member_id is not null
                 order by o2.created_at desc limit 1) as guess
    from public.orders o
   where (o.created_at at time zone 'Asia/Kuala_Lumpur')::date
         = (now() at time zone 'Asia/Kuala_Lumpur')::date
     and o.member_id is null and o.device_id is not null
     and coalesce(o.ta_mode,'') not in ('recharge','reservation')
     and coalesce(o.status,'') <> 'void'),
     mems as (select distinct guess as mid from tofix where guess is not null),
     today as (select to_char(now() at time zone 'Asia/Kuala_Lumpur','YYYY-MM-DD') as d),
     amt as (select l.member_id, sum(l.delta) as delta
               from public.member_xp_ledger l join mems on mems.mid = l.member_id
              where l.reason = 'admin_adjust'
                and (l.created_at at time zone 'Asia/Kuala_Lumpur')::date
                    = (now() at time zone 'Asia/Kuala_Lumpur')::date
              group by 1),
     ins as (
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
  select o.id, (select o2.member_id from public.orders o2
                 where o2.device_id = o.device_id and o2.member_id is not null
                 order by o2.created_at desc limit 1) as guess
    from public.orders o
   where (o.created_at at time zone 'Asia/Kuala_Lumpur')::date
         = (now() at time zone 'Asia/Kuala_Lumpur')::date
     and o.member_id is null and o.device_id is not null
     and coalesce(o.ta_mode,'') not in ('recharge','reservation')
     and coalesce(o.status,'') <> 'void'),
     mems as (select distinct guess as mid from tofix where guess is not null),
     today as (select to_char(now() at time zone 'Asia/Kuala_Lumpur','YYYY-MM-DD') as d),
     amt as (select l.member_id, sum(l.delta) as delta
               from public.member_coin_ledger l join mems on mems.mid = l.member_id
              where l.reason = 'admin_adjust'
                and (l.created_at at time zone 'Asia/Kuala_Lumpur')::date
                    = (now() at time zone 'Asia/Kuala_Lumpur')::date
              group by 1),
     ins as (
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
select o.order_num as 已结算单号,
       public.rpc_on_order_completed(o.member_id, o.id::text, o.total) as _
  from public.orders o
 where (o.created_at at time zone 'Asia/Kuala_Lumpur')::date
       = (now() at time zone 'Asia/Kuala_Lumpur')::date
   and o.member_id is not null
   and coalesce(o.ta_mode,'') not in ('recharge','reservation')
   and coalesce(o.status,'') <> 'void'
   and not exists (select 1 from public.member_xp_ledger l
                    where l.ref_type = 'order' and l.ref_id = o.id::text)
 order by o.order_num;

-- ── 报告 2：结果对账 ──────────────────────────────────────────────────────
select o.order_num as 单号, m.nickname as 会员, o.total as 金额,
       coalesce((select sum(l.delta) from public.member_xp_ledger l
                  where l.ref_type='order' and l.ref_id=o.id::text),0)   as 本单XP,
       coalesce((select sum(l.delta) from public.member_coin_ledger l
                  where l.ref_type='order' and l.ref_id=o.id::text),0)   as 本单Coin,
       m.xp as 会员总XP, m.coins as 会员总Coin
  from public.orders o join public.members m on m.id = o.member_id
 where (o.created_at at time zone 'Asia/Kuala_Lumpur')::date
       = (now() at time zone 'Asia/Kuala_Lumpur')::date
   and coalesce(o.ta_mode,'') not in ('recharge','reservation')
   and coalesce(o.status,'') <> 'void'
 order by o.order_num;

-- ── 报告没问题就把下面两行对调（注释 rollback、放开 commit），再 Run 一次 ──
-- commit;
rollback;
