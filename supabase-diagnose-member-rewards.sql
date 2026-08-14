-- ============================================================================
--  布丁喵 — 诊断：会员买单后 XP / Coin 没加
--  用法：Supabase Dashboard → SQL Editor → New query → 整段粘贴 → Run
--        全是只读查询，不改任何数据，随时可以重复跑。
--
--  订单上确实绑了会员（POS 能看到会员名）却不加分，可能卡在这几处，
--  这个脚本按顺序把它们逐个排除：
--    ① 规则本身没启用 / 值是 0        → 查 1
--    ② 撞到当日上限 daily_cap          → 查 1 + 查 3
--    ③ 这一单已经发过（流水里有记录）  → 查 2
--    ④ RPC 直接报错（以前是静默的）    → 查 5
-- ============================================================================

-- ── 查 1：消费积分规则。enabled 要是 true、值不能是 0 ────────────────────────
--    daily_cap 有值就说明有当日上限，配合查 3 看是不是撞顶了。
select 'xp_rules'   as 表, action_key as 规则, enabled as 已启用,
       xp_value::text as 每单位发放, daily_cap as 当日上限
  from public.xp_rules   where action_key = 'purchase_per_rm'
union all
select 'coin_rules', action_key, enabled,
       coin_value::text, daily_cap
  from public.coin_rules where action_key = 'purchase_per_rm';


-- ── 查 2：最近两天的订单，逐单看「绑没绑会员」和「实际发了多少」 ─────────────
--    has_member = false → 那单压根没绑会员，不会发分（跟服务端无关）。
--    has_member = true 但 xp_granted / coin_granted 是 0 → 问题在服务端，往下看。
--    已经有非 0 数字 → 这一单其实发过了，别重复排查。
select o.order_num                                as 单号,
       o.created_at                               as 下单时间,
       o.total                                    as 金额,
       o.status                                   as 状态,
       o.pay_method                               as 支付方式,
       (o.member_id is not null)                  as 绑了会员,
       coalesce((select sum(l.delta) from public.member_xp_ledger l
                  where l.ref_type = 'order' and l.ref_id = o.id::text), 0)   as 已发XP,
       coalesce((select sum(l.delta) from public.member_coin_ledger l
                  where l.ref_type = 'order' and l.ref_id = o.id::text), 0)   as 已发Coin,
       o.id                                       as 订单id
  from public.orders o
 where o.created_at >= current_date - interval '2 days'
   and coalesce(o.ta_mode,'') not in ('recharge','reservation')
 order by o.created_at desc
 limit 40;


-- ── 查 3：今天每个会员已经拿到的消费 XP（对照查 1 的 daily_cap）─────────────
--    某人今天累计 >= daily_cap，之后这一天就不再发了——这正是「今天不加分」的典型样子。
--    注意 current_date 走的是数据库时区(UTC)，跟马来西亚差 8 小时，
--    所以这个「今天」实际是当地时间早上 8 点换的日。
select m.nickname                as 会员,
       l.reason                  as 规则,
       sum(l.delta)              as 今日已发,
       count(*)                  as 笔数
  from public.member_xp_ledger l
  join public.members m on m.id = l.member_id
 where l.created_at::date = current_date
 group by 1,2
 order by 3 desc;


-- ── 查 4：等级闸门那套装好了没（supabase-member-level-guard.sql）────────────
--    _grant_xp 发完分会顺手 update members.level_id，那一步会经过这个触发器。
--    如果脚本只跑了一半（函数在、触发器不在，或反过来），这条 update 会报错，
--    整个 rpc_on_order_completed 回滚 → XP 和 Coin 都不会进账。
--    正常应该是：函数存在、触发器 = 1。
select to_regprocedure('public._member_level_for_xp(int)') as 函数,
       (select count(*) from pg_trigger
         where tgname = 'trg_member_level_guard'
           and tgrelid = 'public.members'::regclass)       as 触发器;


-- ── 查 5：直接把那一单重放一遍，看服务端到底报什么错 ────────────────────────
--    这一段默认注释掉了。要用的话：
--      1. 从查 2 里挑一单「绑了会员 = true 但已发XP = 0」的，复制它的 订单id
--      2. 把下面两个占位替换掉，去掉 /* */ 再 Run
--    整段包在事务里、最后 rollback，所以不会真的发分，只是把错误逼出来。
--    如果它安静地跑完没报错，说明 RPC 本身没问题，回头看查 1 / 查 3（规则或上限）。
/*
begin;
  select public.rpc_on_order_completed(
    (select member_id from public.orders where id = '这里贴订单id'),
    '这里贴订单id',
    (select total    from public.orders where id = '这里贴订单id')
  );
  -- 看看这一趟到底会写出什么流水（rollback 后不会留下）
  select 'xp' as 类型, delta, reason from public.member_xp_ledger
    where ref_type='order' and ref_id='这里贴订单id'
  union all
  select 'coin', delta, reason from public.member_coin_ledger
    where ref_type='order' and ref_id='这里贴订单id';
rollback;
*/
