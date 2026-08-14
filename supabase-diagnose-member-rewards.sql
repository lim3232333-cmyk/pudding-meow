-- ============================================================================
--  布丁喵 — 诊断：会员买单后 XP / Coin 没加
--  用法：Supabase Dashboard → SQL Editor → 整段粘贴 → Run
--        只读，不改任何数据，随时可以重复跑。
--
--  ⚠ Supabase 的 SQL Editor 一次只显示**最后一条语句**的结果，
--    所以这里刻意写成「一条查询」——一次 Run 就能把所有检查项一起看到。
--    最下面还有一段「逐单明细」，要看的话把那一段**选中**再 Run（只跑选中的部分）。
--
--  订单确实绑了会员（POS 能看到会员名）却不加分，可能卡在：
--    ① 规则没启用 / 值是 0
--    ② 撞到当日上限 daily_cap（_grant_xp 会安静返回 0，不报错也不写流水）
--    ③ 这一单已经发过了（流水里有记录，RPC 里的幂等锁会跳过）
--    ④ 等级闸门只装了一半 → _grant_xp 末尾更新等级报错 → 整个 RPC 回滚
--  下面每一行对应一个可能，「判断」列写着正不正常。
-- ============================================================================

with tz as (select 'Asia/Kuala_Lumpur'::text as z),
     today as (select ((now() at time zone (select z from tz))::date) as d),
     rx as (select * from public.xp_rules   where action_key = 'purchase_per_rm'),
     rc as (select * from public.coin_rules where action_key = 'purchase_per_rm'),
     -- 今天（马来西亚时间）的正常餐单
     ord as (
       select o.*
         from public.orders o
        where (o.created_at at time zone (select z from tz))::date = (select d from today)
          and coalesce(o.ta_mode,'') not in ('recharge','reservation')
          and coalesce(o.status,'') <> 'void'
     ),
     -- 今天每个会员已经拿到的消费 XP（对照 daily_cap）
     capped as (
       select l.member_id, sum(l.delta) as got
         from public.member_xp_ledger l
        where l.reason = 'purchase_per_rm'
          and (l.created_at at time zone (select z from tz))::date = (select d from today)
        group by 1
     )
select * from (
  select 1 as 序, '① XP规则 已启用'   as 检查项,
         coalesce((select enabled::text from rx), '(没有这条规则)') as 结果,
         case when (select enabled from rx) then '正常' else '⚠ 不发 XP 的直接原因' end as 判断
  union all
  select 2, '① XP规则 每 RM 发放',
         coalesce((select xp_value::text from rx), '—'),
         case when coalesce((select xp_value from rx),0) = 0 then '⚠ 是 0，发不出来' else '正常' end
  union all
  select 3, '② XP规则 当日上限',
         coalesce((select daily_cap::text from rx), '(没设上限)'),
         case when (select daily_cap from rx) is null then '正常（不限）' else '有上限 → 看第 ⑦ 行' end
  union all
  select 4, '① Coin规则 已启用',
         coalesce((select enabled::text from rc), '(没有这条规则)'),
         case when (select enabled from rc) then '正常' else '⚠ 不发 Coin 的直接原因' end
  union all
  select 5, '① Coin规则 每 RM 发放',
         coalesce((select coin_value::text from rc), '—'),
         case when coalesce((select coin_value from rc),0) = 0 then '⚠ 是 0，发不出来' else '正常' end
  union all
  select 6, '② Coin规则 当日上限',
         coalesce((select daily_cap::text from rc), '(没设上限)'),
         case when (select daily_cap from rc) is null then '正常（不限）' else '有上限 → 看第 ⑦ 行' end
  union all
  -- ⑦ 今天有没有人已经撞到 XP 上限：撞顶之后这一天就不再发了
  select 7, '② 今天撞到 XP 上限的会员',
         coalesce((select string_agg(m.nickname || '(' || c.got || ')', '、')
                     from capped c join public.members m on m.id = c.member_id
                    where (select daily_cap from rx) is not null
                      and c.got >= (select daily_cap from rx)), '无'),
         case when exists (select 1 from capped c
                            where (select daily_cap from rx) is not null
                              and c.got >= (select daily_cap from rx))
              then '⚠ 这些人今天不会再加分了' else '正常' end
  union all
  -- ④ 等级闸门（supabase-member-level-guard.sql）两样都要在
  select 8, '④ 等级闸门 函数+触发器',
         coalesce(to_regprocedure('public._member_level_for_xp(int)')::text,'(缺函数)')
           || ' / 触发器 ' ||
         (select count(*)::text from pg_trigger
           where tgname = 'trg_member_level_guard'
             and tgrelid = 'public.members'::regclass),
         case when to_regprocedure('public._member_level_for_xp(int)') is not null
               and exists (select 1 from pg_trigger
                            where tgname='trg_member_level_guard'
                              and tgrelid='public.members'::regclass)
              then '正常' else '⚠ 只装了一半 → 整个 RPC 会回滚' end
  union all
  -- 今天的实际战况：几单、几单绑了会员、其中几单真的发出了分
  select 9, '今天 餐单总数', (select count(*)::text from ord), '—'
  union all
  select 10, '今天 绑了会员的单',
         (select count(*)::text from ord where member_id is not null), '—'
  union all
  select 11, '③ 绑了会员且已发分的单',
         (select count(*)::text from ord o
           where o.member_id is not null
             and exists (select 1 from public.member_xp_ledger l
                          where l.ref_type='order' and l.ref_id = o.id::text)),
         case when (select count(*) from ord where member_id is not null) > 0
               and (select count(*) from ord o
                     where o.member_id is not null
                       and exists (select 1 from public.member_xp_ledger l
                                    where l.ref_type='order' and l.ref_id=o.id::text)) = 0
              then '⚠ 一单都没发出去' else '—' end
) x order by 序;


-- ============================================================================
--  逐单明细（可选）：想看具体哪一单没发分，把下面整段**选中**再 Run。
--  绑了会员 = true 但 已发XP = 0 的，就是没结算成功的那些。
-- ============================================================================
-- select o.order_num as 单号, o.created_at as 下单时间, o.total as 金额,
--        o.status as 状态, o.pay_method as 支付方式,
--        (o.member_id is not null) as 绑了会员,
--        coalesce((select sum(l.delta) from public.member_xp_ledger l
--                   where l.ref_type='order' and l.ref_id=o.id::text),0) as 已发XP,
--        coalesce((select sum(l.delta) from public.member_coin_ledger l
--                   where l.ref_type='order' and l.ref_id=o.id::text),0) as 已发Coin,
--        o.id as 订单id
--   from public.orders o
--  where o.created_at >= now() - interval '2 days'
--    and coalesce(o.ta_mode,'') not in ('recharge','reservation')
--  order by o.created_at desc limit 40;


-- ============================================================================
--  逼出真实报错（最后手段）：上面都看不出问题时用。
--  从「逐单明细」里挑一单「绑了会员 = true 但 已发XP = 0」的，把 订单id 填进去，
--  选中这一段 Run。包在事务里、最后 rollback，不会真的发分。
--  RPC 要是有毛病，这里会直接把 Postgres 的报错原文打出来。
-- ============================================================================
-- begin;
--   select public.rpc_on_order_completed(
--     (select member_id from public.orders where id = '这里贴订单id'),
--     '这里贴订单id',
--     (select total from public.orders where id = '这里贴订单id'));
-- rollback;
