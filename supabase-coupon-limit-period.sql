-- ============================================================================
--  布丁喵 — 「每人限领」可以按天/周/月，不再只有终身
--  用法：Supabase Dashboard → SQL Editor → New query → 整段粘贴 → Run。
--        跑一次就好，可以重复跑（幂等）。
--  前置：**supabase-coupon-free-claim.sql**（它也建 rpc_redeem_coupon，
--        跑在这份后面会把周期判断盖掉。下面有硬检查）
--        biz_date（supabase-business-day.sql）、week_start（supabase-weekly-tasks.sql）
--
--  原来 per_member_limit 是**终身**的：一个人一辈子领 2 张就到顶。想做「免邮券
--  每周限领 2 张」只能每周复制一张新券模板 —— 券包里堆着一排同名券，顾客分不清，
--  统计也散了。
--
--  加一列 per_member_period：total（终身，默认，行为不变）/ day / week / month。
--  数的时候只数当前周期内领的那几张，周期一过自动回满，不用店家去点任何按钮。
--
--  ⚠ 周期的口径跟营业日、每周任务**完全一致**：week 是营业日的周一到周日
--    （`week_start()`），day 是营业日（`biz_date()`，默认凌晨 4 点切）。
--    不然「本周领了几张」会跟仪表盘、每周任务对不上，同一天读出两个数。
--
--  ⚠ 只改「每人限领」。总量上限（total_limit）仍然是终身的 —— 那是一批券印了
--    多少张的意思，本来就不该自己回满。真要按周控总量是另一个决定。
-- ============================================================================

do $$
begin
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname='public' and p.proname='_coupon_rule_guard') then
    raise exception '请先跑 supabase-coupon-free-claim.sql —— 它也会重建 rpc_redeem_coupon，跑在这份后面会把周期判断盖掉';
  end if;
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname='public' and p.proname='biz_date') then
    raise exception '请先跑 supabase-business-day.sql —— 周期要按营业日算';
  end if;
  if not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                  where n.nspname='public' and p.proname='week_start') then
    raise exception '请先跑 supabase-weekly-tasks.sql —— 「本周」的口径要跟每周任务用同一个 week_start()';
  end if;
end $$;

alter table public.coupon_rules
  add column if not exists per_member_period text not null default 'total';
do $$
begin
  alter table public.coupon_rules
    add constraint coupon_rules_period_ck check (per_member_period in ('total','day','week','month'));
exception when duplicate_object then null;
end $$;
comment on column public.coupon_rules.per_member_period is
  '每人限领的计数周期：total=终身（默认）/ day=每个营业日 / week=每个营业周（周一起）/ month=每个自然月。周期一过自动回满。';

-- ── 周期的起点（营业日口径，跟每周任务、仪表盘同一套） ──────────────────────
--  返回 null 表示「终身」，调用处就不加时间条件。
create or replace function public._coupon_period_start(p_period text)
returns date
language sql
stable
set search_path = public
as $$
  select case lower(coalesce(p_period, 'total'))
           when 'day'   then public.biz_date(now())
           when 'week'  then public.week_start()
           when 'month' then date_trunc('month', public.biz_date(now()))::date
           else null::date
         end;
$$;

-- ── 规则派发器：注册送 / 下单送 / 生日券都走这里 ────────────────────────────
--  整段重贴（v2 那版 + 周期判断）。这个项目已经吃过两次「两个文件各改一半」的亏
--  （rpc_member_register 被三个文件轮流覆盖），所以宁可重贴也不局部打补丁。
create or replace function public._coupon_fire(p_event text, p_member_id uuid, p_ctx jsonb)
returns int
language plpgsql
security definer
set search_path = public, extensions
as $$
declare c record; v_facts jsonb; v_mine int; v_n int := 0; v_from date;
begin
  if p_member_id is null then return 0; end if;
  v_facts := public._coupon_facts(p_member_id, coalesce(p_ctx, '{}'::jsonb));

  for c in
    select r.*, co.enabled as coupon_enabled
      from public.coupon_rules r
      join public.coupons co on co.id = r.coupon_id
     where r.trigger_event = p_event and r.enabled and co.enabled
     order by r.created_at
  loop
    -- 锁住这条规则再数：重试的注册 / 并发的订单会排队，后来的那次看得见前一次插的券
    perform 1 from public.coupon_rules where id = c.id for update;

    if c.starts_at is not null and now() < c.starts_at then continue; end if;
    if c.ends_at   is not null and now() > c.ends_at   then continue; end if;
    if c.total_limit is not null and c.issued_count >= c.total_limit then continue; end if;
    if coalesce(c.per_member_limit,0) > 0 then
      v_from := public._coupon_period_start(c.per_member_period);
      select count(*) into v_mine from public.member_coupons mc
       where mc.member_id = p_member_id and mc.source_rule_id = c.id
         and (v_from is null or public.biz_date(mc.issued_at) >= v_from);
      if v_mine >= c.per_member_limit then continue; end if;
    end if;
    if not public._coupon_cond_ok(c.conditions, v_facts) then continue; end if;

    insert into public.member_coupons(member_id, coupon_id, status, expires_at, source_rule_id)
      values (p_member_id, c.coupon_id, 'unused', public._coupon_expiry_for(c.coupon_id), c.id);
    update public.coupon_rules set issued_count = issued_count + 1 where id = c.id;
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

-- ── 积分商城兑换：同一套周期判断 ────────────────────────────────────────────
--  整段是 supabase-coupon-free-claim.sql 那版（0 Coin 免费领）+ 周期判断。
create or replace function public.rpc_redeem_coupon(
  p_member_id uuid, p_session_token text, p_coupon_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_coupon record; v_rule record; v_coins int; v_new_id uuid; v_mine int; v_from date;
begin
  perform public._auth_member(p_member_id, p_session_token);

  select * into v_coupon from public.coupons where id = p_coupon_id;
  if v_coupon is null or not v_coupon.enabled then raise exception '该优惠券不存在或已下架'; end if;

  -- 锁住规则行再数：两次并发兑换会排队，后来的那次看得见前一次插进去的券
  select * into v_rule from public.coupon_rules
   where coupon_id = p_coupon_id and trigger_event = 'coin_redeem' and enabled
   order by created_at limit 1
   for update;
  if v_rule is null or v_rule.coin_price is null then
    raise exception '该优惠券未在积分商城出售';
  end if;
  if v_rule.starts_at is not null and now() < v_rule.starts_at then raise exception '兑换还没开始'; end if;
  if v_rule.ends_at   is not null and now() > v_rule.ends_at   then raise exception '兑换已结束'; end if;
  if v_rule.total_limit is not null and v_rule.issued_count >= v_rule.total_limit then
    raise exception '这张券已经兑完了';
  end if;
  if coalesce(v_rule.per_member_limit,0) > 0 then
    v_from := public._coupon_period_start(v_rule.per_member_period);
    select count(*) into v_mine from public.member_coupons mc
     where mc.member_id = p_member_id and mc.source_rule_id = v_rule.id
       and (v_from is null or public.biz_date(mc.issued_at) >= v_from);
    if v_mine >= v_rule.per_member_limit then
      -- 周期券要说清楚「什么时候能再领」，不然顾客以为坏了
      raise exception '%限领 % 张，你已经领过了%',
        case v_rule.per_member_period when 'day' then '每天每人' when 'week' then '每周每人'
                                      when 'month' then '每月每人' else '每人' end,
        v_rule.per_member_limit,
        case v_rule.per_member_period when 'day' then '，明天再来' when 'week' then '，下周再来'
                                      when 'month' then '，下个月再来' else '' end;
    end if;
  end if;
  -- 规则上的领取条件（等级、消费额…）跟其它发放方式共用同一套引擎
  if not public._coupon_cond_ok(v_rule.conditions, public._coupon_facts(p_member_id, '{}'::jsonb)) then
    raise exception '你还不满足这张券的兑换条件';
  end if;

  --  0 Coin 就整段跳过：不锁会员行、不扣、也不写一条 delta = 0 的流水
  if v_rule.coin_price > 0 then
    select coins into v_coins from public.members where id = p_member_id for update;
    if v_coins < v_rule.coin_price then
      raise exception 'Coin 不足：需要 %，当前 %', v_rule.coin_price, v_coins;
    end if;
    update public.members set coins = coins - v_rule.coin_price where id = p_member_id;
    insert into public.member_coin_ledger(member_id, delta, reason, ref_type, ref_id)
      values (p_member_id, -v_rule.coin_price, 'mall_redeem', 'coupon', p_coupon_id::text);
  end if;

  insert into public.member_coupons(member_id, coupon_id, status, expires_at, source_rule_id)
    values (p_member_id, p_coupon_id, 'unused', public._coupon_expiry_for(p_coupon_id), v_rule.id)
    returning id into v_new_id;
  update public.coupon_rules set issued_count = issued_count + 1 where id = v_rule.id;

  return v_new_id;
end;
$$;

grant execute on function public._coupon_period_start(text) to anon;
grant execute on function public.rpc_redeem_coupon(uuid, text, uuid) to anon;

-- 对账：每条规则的限领口径，以及本周期内已经发出去多少张
select c.name as 券名,
       coalesce(r.name,'(未命名)') as 规则,
       r.trigger_event as 触发,
       case when coalesce(r.per_member_limit,0)=0 then '不限'
            else r.per_member_limit || ' 张/' ||
                 case r.per_member_period when 'day' then '天' when 'week' then '周'
                                          when 'month' then '月' else '终身' end end as 每人限领,
       (select count(*) from public.member_coupons mc
         where mc.source_rule_id = r.id
           and (public._coupon_period_start(r.per_member_period) is null
                or public.biz_date(mc.issued_at) >= public._coupon_period_start(r.per_member_period))
       ) as 本周期已发,
       r.issued_count as 累计已发
  from public.coupon_rules r
  join public.coupons c on c.id = r.coupon_id
 order by c.name, r.created_at;
