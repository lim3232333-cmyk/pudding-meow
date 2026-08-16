-- ============================================================================
--  布丁喵 — 优惠券「发放规则」层（三层模型的中间那层）
--  用法：Supabase Dashboard → SQL Editor → 整段粘贴 → Run。可重复跑。
--
--  ── 为什么需要这一层 ──────────────────────────────────────────────────────
--  原来只有两层：券模板（coupons）→ 券实例（member_coupons），中间靠店员手动点
--  「发放」。而「发给全体会员」是这么写的：
--        insert into member_coupons(...) select id from members;
--  它对**按下按钮那一刻已经存在的会员**拍了张快照——明天注册的新人不在快照里，
--  所以「新人注册就送券」这件事，用原来的结构根本表达不出来。
--
--  补上中间这层之后：
--        券模板（面额/门槛/有效期）
--           ↓
--        发放规则（什么事件触发 · 满足什么条件 · 每人限领几张 · 总量上限）  ← 新增
--           ↓
--        券实例（某个会员手上的那一张）
--
--  一张券可以挂多条规则（例：同一张「满20减5」既在注册时送，也在消费满 RM100 时送）。
--
--  ── 两条安全底线 ──────────────────────────────────────────────────────────
--  ① 发券**绝不能连累主流程**。触发器里整段包了 exception 捕获：发券失败只写一条
--     warning，注册照样成功、订单照样落库。没券是小事，注册不了/订单丢了是大事。
--  ② 发券**不能重复**。并发或重试时靠 `select ... for update` 锁住规则行：第二个
--     调用会等，等到之后再数已发数量，就数得到第一个刚插进去的那张，于是跳过。
--
--  ── 刻意不做的事 ──────────────────────────────────────────────────────────
--  不去改 rpc_member_register。那个函数被三个 SQL 文件改过、其中两个互相丢过对方
--  的活（referrals 那笔插入、默认等级）。在它里面加发券调用，下次谁再重写一遍就
--  又没了。挂触发器在 members 表上，任何注册路径都覆盖得到，也不怕被覆盖。
-- ============================================================================

-- ── 1) 规则表 ──────────────────────────────────────────────────────────────
create table if not exists public.coupon_rules (
  id             uuid primary key default gen_random_uuid(),
  coupon_id      uuid not null references public.coupons(id) on delete cascade,
  name           text,                                  -- 给店员看的备注，如「新人注册礼」
  -- register        注册成功时
  -- order_paid      订单付款完成时（含柜台收款、在线支付到账）
  -- birthday_month  生日月（要靠 rpc_admin_run_birthday_coupons 触发，见文件末尾）
  trigger_event  text not null,
  -- 条件，jsonb。留空 = 无条件。形状是一串「字段 · 运算符 · 值」的比较：
  --   {"all":[{"field":"amount","op":">=","value":100},
  --           {"field":"mode","op":"==","value":"delivery"}]}
  --   可用字段由 _coupon_facts 算出来（本单金额/用餐方式/历史消费/等级/星期几…），
  --   运算符 >= <= > < == != in not_in。all = 全部满足。
  conditions     jsonb not null default '{}'::jsonb,
  per_member_limit int not null default 1,               -- 每人最多领几张；0 = 不限
  total_limit    int,                                    -- 这条规则总共最多发几张；null = 不限
  issued_count   int not null default 0,                 -- 已经发出去多少（配合 total_limit）
  starts_at      timestamptz,
  ends_at        timestamptz,
  enabled        boolean not null default true,
  created_at     timestamptz not null default now()
);
create index if not exists coupon_rules_event_idx on public.coupon_rules (trigger_event, enabled);
create index if not exists coupon_rules_coupon_idx on public.coupon_rules (coupon_id);

-- 券实例记一下是哪条规则发的：既是审计，也是「每人限领」的计数依据。
-- 按规则计数而不是按券计数——同一张券挂两条规则时，两边的限额要各算各的。
alter table public.member_coupons
  add column if not exists source_rule_id uuid references public.coupon_rules(id) on delete set null;
create index if not exists member_coupons_rule_idx on public.member_coupons (source_rule_id, member_id);

alter table public.coupon_rules enable row level security;
drop policy if exists coupon_rules_anon_read on public.coupon_rules;
create policy coupon_rules_anon_read on public.coupon_rules for select to anon using (true);
drop policy if exists coupon_rules_anon_write on public.coupon_rules;
create policy coupon_rules_anon_write on public.coupon_rules for all to anon using (true) with check (true);

-- ── 2) 条件：通用「事实 + 比较」引擎 ────────────────────────────────────────
--    刻意不把条件写成一堆写死的 if：那样每加一种玩法都要改后端。
--    改成先把这个会员/这次事件的所有「事实」算成一个 jsonb，规则就是一串
--    {字段, 运算符, 值} 的比较。店员在 POS 上自由组合，不用再找人改代码。
--
--    conditions 的形状：
--      {"all": [ {"field":"amount","op":">=","value":100},
--                {"field":"mode","op":"==","value":"delivery"},
--                {"field":"weekday","op":"in","value":[6,7]} ]}
--    all = 全部满足（AND）。空数组 / 空对象 = 无条件。
-- 旧版是 _coupon_cond_ok(jsonb, uuid, jsonb)，跟新版签名不同，create or replace 替换不掉，
-- 会留下一个没人调用的僵尸函数。显式删掉，免得以后读代码的人以为还有两套条件逻辑。
drop function if exists public._coupon_cond_ok(jsonb, uuid, jsonb);

create or replace function public._coupon_facts(p_member_id uuid, p_ctx jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, extensions
as $$
declare m record; v_cnt int; v_sum numeric; v_now timestamptz;
begin
  v_now := now() at time zone 'Asia/Kuala_Lumpur';

  select mm.*, coalesce(l.sort_order, 0) as lvl_sort
    into m
    from public.members mm
    left join public.member_levels l on l.id = mm.level_id
   where mm.id = p_member_id;

  -- 历史完成餐单数 / 消费总额（充值单、预约单、作废单都不算）
  select count(*), coalesce(sum(greatest(coalesce(o.total,0) - coalesce(o.admin_fee,0), 0)), 0)
    into v_cnt, v_sum
    from public.orders o
   where o.member_id = p_member_id
     and coalesce(o.status,'') in ('paid','preparing','ready','done')
     and coalesce(o.ta_mode,'') not in ('recharge','reservation');

  return jsonb_build_object(
    -- 本次事件（下单类事件才有值）
    'amount',              coalesce((p_ctx->>'amount')::numeric, 0),
    'mode',                coalesce(p_ctx->>'mode', ''),
    'pay_method',          coalesce(p_ctx->>'pay_method', ''),
    'is_first_order',      case when v_cnt = 1 then 1 else 0 end,
    -- 会员画像
    'order_count',         v_cnt,
    'total_spent',         v_sum,
    'level_sort_order',    coalesce(m.lvl_sort, 0),
    'xp',                  coalesce(m.xp, 0),
    'coins',               coalesce(m.coins, 0),
    'wallet_balance',      coalesce(m.wallet_balance, 0),
    'days_since_register', coalesce(extract(day from (now() - m.created_at))::int, 0),
    'birthday_month',      case when m.birthday is null then 0
                                else extract(month from m.birthday)::int end,
    -- 时间（用马来西亚时区，跟营业日一个口径）
    'weekday',             case when extract(isodow from v_now)::int is null then 0
                                else extract(isodow from v_now)::int end,   -- 1=周一 … 7=周日
    'hour',                extract(hour from v_now)::int,
    'month',               extract(month from v_now)::int
  );
end;
$$;

--    单条比较。数字比数字，文本比文本，in / not_in 的 value 是数组。
create or replace function public._coupon_cmp(p_fact jsonb, p_op text, p_val jsonb)
returns boolean
language plpgsql
immutable
as $$
declare a numeric; b numeric; sa text; sb text;
begin
  if p_fact is null or p_val is null then return false; end if;
  sa := trim(both '"' from p_fact::text);
  sb := trim(both '"' from p_val::text);

  if p_op in ('in','not_in') then
    if jsonb_typeof(p_val) <> 'array' then return false; end if;
    -- 数组里逐个比字符串形态，数字和文本都能用
    if exists (select 1 from jsonb_array_elements(p_val) e
                where trim(both '"' from e::text) = sa)
    then return p_op = 'in'; else return p_op = 'not_in'; end if;
  end if;

  -- 两边都能当数字就按数字比（避免 '9' > '10' 这种字符串陷阱）
  begin a := sa::numeric; b := sb::numeric; exception when others then a := null; end;

  if a is not null and b is not null then
    return case p_op
      when '>=' then a >= b when '<=' then a <= b
      when '>'  then a >  b when '<'  then a <  b
      when '==' then a =  b when '!=' then a <> b
      else false end;
  end if;

  return case p_op
    when '==' then sa =  sb
    when '!=' then sa <> sb
    else false end;   -- 文本不支持大小比较
end;
$$;

create or replace function public._coupon_cond_ok(p_cond jsonb, p_facts jsonb)
returns boolean
language plpgsql
immutable
as $$
declare it jsonb;
begin
  if p_cond is null or p_cond = '{}'::jsonb then return true; end if;
  if jsonb_typeof(p_cond->'all') <> 'array' then return true; end if;

  for it in select * from jsonb_array_elements(p_cond->'all') loop
    if not public._coupon_cmp(p_facts -> (it->>'field'), it->>'op', it->'value') then
      return false;
    end if;
  end loop;
  return true;
end;
$$;

-- ── 3) 派发器：某个事件发生了，把挂在它上面的券该发的发掉 ────────────────────
create or replace function public._coupon_fire(p_event text, p_member_id uuid, p_ctx jsonb default '{}'::jsonb)
returns int
language plpgsql
security definer
set search_path = public, extensions
as $$
declare v_id uuid; r record; c record; v_have int; v_n int := 0; v_facts jsonb;
begin
  if p_member_id is null or coalesce(p_event,'') = '' then return 0; end if;
  -- 事实只算一次，所有规则共用（每条规则各算一遍会重复扫 orders 表）
  v_facts := public._coupon_facts(p_member_id, coalesce(p_ctx, '{}'::jsonb));

  for v_id in
    select cr.id from public.coupon_rules cr
     where cr.trigger_event = p_event
       and cr.enabled
     order by cr.created_at
  loop
    -- 锁住这一条规则再判断。并发下单/重试注册时，第二个调用会停在这里等；
    -- 拿到锁之后重新读、重新数，就看得见第一个刚插进去的那张券，于是正确跳过。
    select * into r from public.coupon_rules where id = v_id for update;
    if not found or not r.enabled then continue; end if;
    if r.starts_at is not null and now() < r.starts_at then continue; end if;
    if r.ends_at   is not null and now() > r.ends_at   then continue; end if;

    select * into c from public.coupons where id = r.coupon_id and enabled = true;
    if not found then continue; end if;
    -- 券模板自己的发放时间窗也要认（跟手动发放、商城兑换同一套判断）
    if not public._coupon_issuable(c.issue_from, c.issue_until) then continue; end if;

    if r.total_limit is not null and r.issued_count >= r.total_limit then continue; end if;

    if r.per_member_limit > 0 then
      select count(*) into v_have from public.member_coupons mc
       where mc.member_id = p_member_id and mc.source_rule_id = r.id;
      if v_have >= r.per_member_limit then continue; end if;
    end if;

    if not public._coupon_cond_ok(r.conditions, v_facts) then continue; end if;

    insert into public.member_coupons(member_id, coupon_id, status, expires_at, source_rule_id)
      values (p_member_id, r.coupon_id, 'unused', public._coupon_expiry(c.valid_days), r.id);
    update public.coupon_rules set issued_count = issued_count + 1 where id = r.id;
    v_n := v_n + 1;
  end loop;

  return v_n;
end;
$$;

-- ── 4) 触发点：注册 ────────────────────────────────────────────────────────
--    挂在 members 的插入上，不去改 rpc_member_register（见文件头的说明）。
--    整段包 exception：发券失败只留一条 warning，注册照样成功。
create or replace function public._tg_coupon_on_register()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  begin
    perform public._coupon_fire('register', new.id, '{}'::jsonb);
  exception when others then
    raise warning '注册发券失败（已忽略，不影响注册）：%', sqlerrm;
  end;
  return new;
end;
$$;

drop trigger if exists trg_coupon_on_register on public.members;
create trigger trg_coupon_on_register
after insert on public.members
for each row execute function public._tg_coupon_on_register();

-- ── 5) 触发点：订单付款完成 ────────────────────────────────────────────────
--    覆盖两条路：POS 直接开单落库就是 paid（INSERT），app 单是 pending→preparing（UPDATE）。
--    只在「状态刚变成已付款」那一刻发一次；后续对同一行的其它 update（比如写
--    kitchen_printed_at）状态没变，直接跳过，不会重复发。
create or replace function public._tg_coupon_on_order()
returns trigger
language plpgsql
security definer
set search_path = public, extensions
as $$
declare v_mode text; v_amt numeric;
begin
  if new.member_id is null then return new; end if;
  if coalesce(new.ta_mode,'') in ('recharge','reservation') then return new; end if;
  if coalesce(new.status,'') not in ('paid','preparing','ready','done') then return new; end if;
  -- UPDATE 时只认「状态真的变了」或「刚补绑上会员」这两种情况
  if tg_op = 'UPDATE'
     and coalesce(old.status,'') = coalesce(new.status,'')
     and coalesce(old.member_id::text,'') = coalesce(new.member_id::text,'') then
    return new;
  end if;

  -- 金额扣掉手续费：那笔钱是代收转付给 HitPay 的，不该算进「消费了多少」
  v_amt := greatest(coalesce(new.total,0) - coalesce(new.admin_fee,0), 0);
  v_mode := case
    when coalesce(new.table_name,'') like '%外卖%' then 'delivery'
    when coalesce(new.table_name,'') like '%自取%' then 'takeaway'
    when coalesce(new.ta_mode,'')   =  'dinein'    then 'dinein'
    else coalesce(new.ta_mode,'') end;

  begin
    perform public._coupon_fire('order_paid', new.member_id,
      jsonb_build_object('amount', v_amt, 'mode', v_mode,
                        'pay_method', coalesce(new.pay_method,''), 'order_id', new.id));
  exception when others then
    raise warning '下单发券失败（已忽略，不影响订单）：%', sqlerrm;
  end;
  return new;
end;
$$;

drop trigger if exists trg_coupon_on_order on public.orders;
create trigger trg_coupon_on_order
after insert or update on public.orders
for each row execute function public._tg_coupon_on_order();

-- ── 6) 生日月：没有定时器，所以留一个手动/定时都能调的 RPC ──────────────────
--    Supabase 免费版没有 cron，这个函数就是给「POS 点一下」或以后接定时任务用的。
--    重复跑安全：每人限领在派发器里管着，同一个月不会发第二张。
create or replace function public.rpc_admin_run_birthday_coupons()
returns int
language plpgsql
security definer
set search_path = public, extensions
as $$
declare m record; v_n int := 0;
begin
  for m in
    select id from public.members
     where birthday is not null
       and extract(month from birthday) = extract(month from (now() at time zone 'Asia/Kuala_Lumpur'))
  loop
    v_n := v_n + public._coupon_fire('birthday_month', m.id, '{}'::jsonb);
  end loop;
  return v_n;
end;
$$;

grant execute on function public.rpc_admin_run_birthday_coupons() to anon;

-- ── 7) 对账：现在有哪些规则、各发了多少 ────────────────────────────────────
select cr.trigger_event                                   as 触发事件,
       coalesce(cr.name, '(未命名)')                       as 规则,
       c.name                                             as 券,
       cr.conditions::text                                as 条件,
       cr.per_member_limit                                as 每人限领,
       coalesce(cr.total_limit::text, '不限')              as 总量上限,
       cr.issued_count                                    as 已发出,
       cr.enabled                                         as 启用
  from public.coupon_rules cr
  join public.coupons c on c.id = cr.coupon_id
 order by cr.trigger_event, cr.created_at;
