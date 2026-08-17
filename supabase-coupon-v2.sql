-- ============================================================================
--  布丁喵 — 优惠券 v2（第一期）：封顶 · 使用限制 · 绝对有效期 · 兑换收进规则层
--  用法：Supabase Dashboard → SQL Editor → New query → 整段粘贴 → Run。
--        跑一次就好，可以重复跑（幂等）。
--  前置：supabase-coupon-rules.sql 已跑过。
--
--  这份脚本要解决的是「发放条件」和「使用限制」被混成一件事的问题。
--  原来的模型里，一张券能不能用只看三件事：状态、到期、满额门槛。其余全在
--  「发给谁」那一侧。于是：
--
--    · 「只发给外卖顾客」的券，发出去之后堂食照样能用；
--    · 「20% OFF」用在一张 RM200 的单上就是减 RM40，没有任何上限；
--    · Coin 兑换是独立于规则层的第三条发放通道，没有每人限领、没有总量上限。
--
--  三个洞都是钱直接漏出去的，所以第一期先补这三个，顺带把重复的地方合并掉。
--
--  ── 合并掉的重复 ──────────────────────────────────────────────────────────
--    coupons.coin_price              → coupon_rules（trigger_event = 'coin_redeem'）
--    coupons.issue_from/issue_until  → coupon_rules.starts_at/ends_at
--    coupons.menu_item_id            → coupons.applies_to
--  三处旧列都保留在表上（不删，免得旧前端读到 null 报错），但迁移之后一律置空，
--  由本脚本重建的函数只认新的那一份。一件事只能有一个地方管，否则迟早对不上。
-- ============================================================================

-- ── 0) 先清掉要重建的那几个函数的所有旧版本 ─────────────────────────────────
--     create or replace 改不了 OUT 参数（返回的列），会直接报
--     「cannot change return type of existing function」。
--     而且这几个函数这次要多加参数（p_mode / p_delivery_fee），加了默认值之后
--     新旧两个版本会同时存在：旧的 5 参精确匹配、新的 6 参靠默认值也匹配，
--     调用时报 ambiguous。所以按**函数名**把所有重载一次删干净，再重建。
--     不用 cascade：真有别的对象依赖它们，宁可在这里报错也别静默删掉。
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure as sig
      from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
     where n.nspname = 'public'
       and p.proname in ('_coupon_calc', '_coupon_expiry', '_coupon_expiry_for',
                         '_coupon_fire', '_coupon_item_price', '_coupon_norm_mode',
                         'rpc_admin_issue_coupon', 'rpc_consume_coupon', 'rpc_get_my_coupons',
                         'rpc_list_mall_coupons', 'rpc_pos_member_coupons', 'rpc_preview_coupon',
                         'rpc_redeem_coupon')
  loop
    execute 'drop function if exists ' || r.sig;
  end loop;
end $$;

-- ── 1) 券模板：新增使用限制相关的列 ─────────────────────────────────────────
alter table public.coupons
  --  百分比券的封顶金额。null = 不封顶（旧行为）。
  --  ZUS 那类券面永远写成「20% off, capped at RM10」就是这一格。
  add column if not exists max_discount numeric,
  --  可用渠道，jsonb 数组。null 或 [] = 不限。
  --  取值跟小程序的 currentMode、sales_channels.code 一致：dinein / pickup / delivery。
  --  ⚠ 注意跟发放条件里的 mode 事实不是同一套字面量（那边历史上用 takeaway 表示自取），
  --    所以下面 _coupon_norm_mode() 把 takeaway 归一成 pickup，两边都能喂进来。
  add column if not exists channels jsonb,
  --  绝对有效期。跟 valid_days（发放后 N 天）是两种到期方式，可以同时填：
  --  同时填就取「先到的那个」。都不填 = 永久有效。
  add column if not exists valid_from  timestamptz,
  add column if not exists valid_until timestamptz,
  --  适用范围，取代 menu_item_id：
  --    {"scope":"order"}                       整单
  --    {"scope":"items","ids":["<uuid>",...]}  指定商品（命中其中任意一件即可用）
  --    {"scope":"cats","codes":["drinks",...]} 指定分类（menu_items.cat / subcat）
  add column if not exists applies_to jsonb;

comment on column public.coupons.max_discount is
  '百分比券的最高抵扣金额（RM）。null = 不封顶。现金券/兑换券不适用。';
comment on column public.coupons.channels is
  '这张券允许在哪些用餐方式下使用（dinein/pickup/delivery）。null 或 [] = 不限。这是「使用限制」，跟 coupon_rules 里的发放条件是两回事。';
comment on column public.coupons.applies_to is
  '适用范围：{"scope":"order"} | {"scope":"items","ids":[...]} | {"scope":"cats","codes":[...]}。取代旧的 menu_item_id。';

-- ── 2) 规则表：兑换价（trigger_event = 'coin_redeem' 时用）──────────────────
alter table public.coupon_rules
  add column if not exists coin_price int;
comment on column public.coupon_rules.coin_price is
  '触发事件为 coin_redeem 时，这张券在积分商城卖多少 Coin。其它事件下无意义。';

-- ── 3) 数据迁移：把三处旧配置搬进新家 ───────────────────────────────────────
--     全部写成「只在还没搬过的时候搬」，重复跑不会覆盖你后来在 POS 里改过的值。

--  3a) menu_item_id → applies_to
update public.coupons
   set applies_to = jsonb_build_object('scope','items','ids', jsonb_build_array(menu_item_id::text))
 where applies_to is null and menu_item_id is not null;
update public.coupons
   set applies_to = '{"scope":"order"}'::jsonb
 where applies_to is null;

--  3b) issue_from/issue_until → 该券名下还没有自己时间窗的规则
update public.coupon_rules r
   set starts_at = coalesce(r.starts_at, c.issue_from),
       ends_at   = coalesce(r.ends_at,   c.issue_until)
  from public.coupons c
 where c.id = r.coupon_id
   and (c.issue_from is not null or c.issue_until is not null);

--  3c) coin_price → 一条 coin_redeem 规则
--      per_member_limit 给 0（不限）是为了跟旧行为一致——旧的兑换本来就没有限领，
--      现在只是把这个开关摆到了台面上，店家想限就去 POS 改。
insert into public.coupon_rules (coupon_id, name, trigger_event, conditions,
                                 per_member_limit, total_limit, coin_price,
                                 starts_at, ends_at, enabled)
select c.id, '积分商城兑换', 'coin_redeem', '{}'::jsonb,
       0, null, c.coin_price, c.issue_from, c.issue_until, c.enabled
  from public.coupons c
 where coalesce(c.coin_price, 0) > 0
   and not exists (select 1 from public.coupon_rules r
                    where r.coupon_id = c.id and r.trigger_event = 'coin_redeem');

--  3d) 搬完把旧列清空，杜绝「两个地方都能改、结果对不上」
update public.coupons
   set coin_price = null, issue_from = null, issue_until = null
 where coin_price is not null or issue_from is not null or issue_until is not null;

-- ── 4) 用餐方式归一 ─────────────────────────────────────────────────────────
--     历史包袱：发放条件里的 mode 事实用 takeaway 表示自取，小程序的 currentMode
--     和 sales_channels.code 用的是 pickup。两边都可能喂进来，这里统一。
create or replace function public._coupon_norm_mode(p_mode text)
returns text
language sql
immutable
as $$
  select case lower(coalesce(p_mode,''))
           when 'takeaway' then 'pickup'
           when 'ta'       then 'pickup'
           else lower(coalesce(p_mode,''))
         end;
$$;

-- ── 5) 到期时间：相对天数 与 绝对截止 取先到的那个 ──────────────────────────
--     旧签名 _coupon_expiry(int) 还有别的脚本在调，保留它并转调新版，
--     这样不用回头去改那些文件（改了反而容易漏）。
create or replace function public._coupon_expiry(p_valid_days int, p_valid_until timestamptz)
returns timestamptz
language sql
stable
as $$
  select least(
    case when coalesce(p_valid_days,0) <= 0 then null
         else now() + (p_valid_days || ' days')::interval end,
    p_valid_until
  );
$$;
create or replace function public._coupon_expiry(p_valid_days int)
returns timestamptz
language sql
stable
as $$ select public._coupon_expiry(p_valid_days, null::timestamptz); $$;

--     发券时统一走这个：读券模板，算出该实例的到期时间
create or replace function public._coupon_expiry_for(p_coupon_id uuid)
returns timestamptz
language sql
stable
as $$
  select public._coupon_expiry(c.valid_days, c.valid_until)
    from public.coupons c where c.id = p_coupon_id;
$$;

-- ── 6) 适用范围：这张券认不认购物车里的东西 ─────────────────────────────────
--     返回命中的那一份商品的单价（整单券返回 null，表示按小计算）。
--     ⚠ 口径沿用旧版：单品券只打「一份」，不是把车里所有同款都打折。
--       命中多件时取单价最高的那一份 —— 顾客直觉是「用在最贵的那杯上」，
--       取最低会让人觉得券缩水了。
--     ⚠ 单价一律从 menu_items 查，不接受前端传的价格（anon key 是公开的）。
create or replace function public._coupon_item_price(p_applies jsonb, p_item_ids uuid[])
returns numeric
language plpgsql
stable
set search_path = public
as $$
declare v_scope text; v_price numeric;
begin
  v_scope := coalesce(p_applies->>'scope', 'order');
  if v_scope = 'order' then return null; end if;
  if p_item_ids is null or array_length(p_item_ids, 1) is null then return -1; end if;

  if v_scope = 'items' then
    select max(mi.price) into v_price
      from public.menu_items mi
     where mi.id = any(p_item_ids)
       and mi.id::text in (select jsonb_array_elements_text(coalesce(p_applies->'ids','[]'::jsonb)));
  elsif v_scope = 'cats' then
    select max(mi.price) into v_price
      from public.menu_items mi
     where mi.id = any(p_item_ids)
       and (mi.cat    in (select jsonb_array_elements_text(coalesce(p_applies->'codes','[]'::jsonb)))
         or mi.subcat in (select jsonb_array_elements_text(coalesce(p_applies->'codes','[]'::jsonb))));
  else
    return null;   -- 认不出的 scope 当整单，别把顾客卡死
  end if;

  return coalesce(v_price, -1);   -- -1 = 车里没有符合的商品
end;
$$;

-- ── 7) 核心：算折扣（加上封顶 / 渠道 / 生效日 / 适用范围）───────────────────
--     签名多了 p_mode。旧签名显式删掉——留着会变成没人调用的僵尸函数，
--     以后读代码的人会以为有两套折扣逻辑。
create or replace function public._coupon_calc(
  p_member_id uuid, p_member_coupon_id uuid, p_subtotal numeric,
  p_item_ids uuid[], p_mode text default null)
returns numeric
language plpgsql
stable
set search_path = public
as $$
declare v record; v_disc numeric; v_price numeric; v_mode text; v_chs jsonb;
begin
  select mc.status, mc.expires_at, mc.member_id,
         c.type, c.value, c.min_spend, c.name,
         c.max_discount, c.channels, c.valid_from,
         coalesce(c.applies_to, '{"scope":"order"}'::jsonb) as applies_to
    into v
    from public.member_coupons mc
    join public.coupons c on c.id = mc.coupon_id
   where mc.id = p_member_coupon_id;

  if v is null then raise exception '优惠券不存在'; end if;
  if v.member_id <> p_member_id then raise exception '这不是你的优惠券'; end if;
  if v.status <> 'unused' then raise exception '该优惠券已使用或已失效'; end if;
  if v.expires_at is not null and v.expires_at < now() then raise exception '该优惠券已过期'; end if;
  if v.valid_from is not null and now() < v.valid_from then
    raise exception '这张券还没到可用日期（% 起）', to_char(v.valid_from at time zone 'Asia/Kuala_Lumpur', 'YYYY-MM-DD');
  end if;
  if p_subtotal < coalesce(v.min_spend, 0) then
    raise exception '未达使用门槛：需满 RM%，当前 RM%', v.min_spend, p_subtotal;
  end if;

  -- 使用渠道。p_mode 传空 = 调用方没说（旧前端），此时不拦——
  -- 宁可放过也不要把付得起的顾客挡在门外，新前端一律会传。
  v_chs := v.channels;
  if v_chs is not null and jsonb_typeof(v_chs) = 'array' and jsonb_array_length(v_chs) > 0
     and coalesce(p_mode,'') <> '' then
    v_mode := public._coupon_norm_mode(p_mode);
    if not exists (select 1 from jsonb_array_elements_text(v_chs) e
                    where public._coupon_norm_mode(e) = v_mode) then
      raise exception '这张券在当前用餐方式下不可用';
    end if;
  end if;

  -- 适用范围：null = 整单；-1 = 车里没有符合的商品；其余 = 命中那份的单价
  v_price := public._coupon_item_price(v.applies_to, p_item_ids);
  if v_price is not null and v_price < 0 then
    raise exception '购物车里没有「%」适用的商品', v.name;
  end if;

  if v.type = 'dessert' then
    if v_price is null then raise exception '该兑换券未指定商品，请联系店员'; end if;
    v_disc := v_price;                                              -- 兑换：抵掉一份的全价
  elsif v.type = 'percent_off' then
    v_disc := round(coalesce(v_price, p_subtotal) * coalesce(v.value, 0) / 100.0, 2);
    -- 封顶只对百分比券有意义：现金券的面额本身就是上限
    if v.max_discount is not null and v.max_discount >= 0 then
      v_disc := least(v_disc, v.max_discount);
    end if;
  else   -- fixed_off
    v_disc := coalesce(v.value, 0);
    if v_price is not null then v_disc := least(v_disc, v_price); end if;   -- 单品现金券不倒贴
  end if;

  -- 折扣不能超过小计，否则会算出负数总额
  return least(greatest(coalesce(v_disc, 0), 0), p_subtotal);
end;
$$;

-- ── 8) 预览 / 核销 / 退回：都带上 p_mode ─────────────────────────────────────
create or replace function public.rpc_preview_coupon(
  p_member_id uuid, p_session_token text, p_member_coupon_id uuid,
  p_subtotal numeric, p_item_ids uuid[] default null, p_mode text default null)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public._auth_member(p_member_id, p_session_token);
  return public._coupon_calc(p_member_id, p_member_coupon_id, p_subtotal, p_item_ids, p_mode);
end;
$$;

create or replace function public.rpc_consume_coupon(
  p_member_id uuid, p_session_token text, p_member_coupon_id uuid,
  p_order_id text, p_subtotal numeric, p_item_ids uuid[] default null,
  p_mode text default null)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare v_disc numeric; v_status text;
begin
  perform public._auth_member(p_member_id, p_session_token);
  -- 先上行锁再算：连点两次不会用掉同一张券两回
  select status into v_status from public.member_coupons
   where id = p_member_coupon_id for update;
  if v_status is null then raise exception '优惠券不存在'; end if;

  v_disc := public._coupon_calc(p_member_id, p_member_coupon_id, p_subtotal, p_item_ids, p_mode);

  update public.member_coupons
     set status = 'used', used_at = now(), order_id = p_order_id
   where id = p_member_coupon_id;
  return v_disc;
end;
$$;

-- ── 9) 后台发券：只能发给指定会员 ───────────────────────────────────────────
--     原来 p_member_id 留空就是「对全体会员群发」。那是对按下按钮那一刻的会员
--     拍快照，明天注册的新人不在里面 —— 正是当初做规则层要解决的问题。
--     群发交给规则（注册即送 / 下单后送 / 生日月），这里只留客诉补偿用的手动补发。
create or replace function public.rpc_admin_issue_coupon(p_coupon_id uuid, p_member_id uuid default null)
returns int
language plpgsql
security definer
set search_path = public
as $$
declare v_coupon record;
begin
  if p_member_id is null then
    raise exception '请指定会员。给一批人发券请用「发放规则」，不要群发快照。';
  end if;
  select * into v_coupon from public.coupons where id = p_coupon_id and enabled = true;
  if v_coupon is null then raise exception '优惠券不存在或已停用'; end if;

  insert into public.member_coupons(member_id, coupon_id, expires_at)
    values (p_member_id, p_coupon_id, public._coupon_expiry_for(p_coupon_id));
  return 1;
end;
$$;

-- ── 10) 积分商城：改成读 coin_redeem 规则 ───────────────────────────────────
--      价格、时间窗、每人限领、总量、领取条件全都在规则上，跟其它发放方式一套逻辑。
create or replace function public.rpc_list_mall_coupons()
returns table(
  id uuid, name text, type text, value numeric, min_spend numeric,
  valid_days int, coin_price int, menu_item_id uuid, menu_item_name text, menu_item_image text,
  max_discount numeric, channels jsonb, applies_to jsonb, rule_id uuid)
language plpgsql
security definer
set search_path = public
as $$
begin
  return query
  select c.id, c.name, c.type, c.value, c.min_spend, c.valid_days, r.coin_price,
         c.menu_item_id, mi.name, mi.image_url,
         c.max_discount, c.channels, coalesce(c.applies_to,'{"scope":"order"}'::jsonb), r.id
    from public.coupons c
    join public.coupon_rules r on r.coupon_id = c.id
                              and r.trigger_event = 'coin_redeem'
                              and r.enabled
    left join public.menu_items mi on mi.id = c.menu_item_id
   where c.enabled
     and coalesce(r.coin_price, 0) > 0
     and (r.starts_at is null or now() >= r.starts_at)
     and (r.ends_at   is null or now() <= r.ends_at)
     and (r.total_limit is null or r.issued_count < r.total_limit)
   order by r.coin_price asc;
end;
$$;

create or replace function public.rpc_redeem_coupon(
  p_member_id uuid, p_session_token text, p_coupon_id uuid)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_coupon record; v_rule record; v_coins int; v_new_id uuid; v_mine int;
begin
  perform public._auth_member(p_member_id, p_session_token);

  select * into v_coupon from public.coupons where id = p_coupon_id;
  if v_coupon is null or not v_coupon.enabled then raise exception '该优惠券不存在或已下架'; end if;

  -- 锁住规则行再数：两次并发兑换会排队，后来的那次看得见前一次插进去的券
  select * into v_rule from public.coupon_rules
   where coupon_id = p_coupon_id and trigger_event = 'coin_redeem' and enabled
   order by created_at limit 1
   for update;
  if v_rule is null or coalesce(v_rule.coin_price,0) <= 0 then
    raise exception '该优惠券未在积分商城出售';
  end if;
  if v_rule.starts_at is not null and now() < v_rule.starts_at then raise exception '兑换还没开始'; end if;
  if v_rule.ends_at   is not null and now() > v_rule.ends_at   then raise exception '兑换已结束'; end if;
  if v_rule.total_limit is not null and v_rule.issued_count >= v_rule.total_limit then
    raise exception '这张券已经兑完了';
  end if;
  if coalesce(v_rule.per_member_limit,0) > 0 then
    select count(*) into v_mine from public.member_coupons
     where member_id = p_member_id and source_rule_id = v_rule.id;
    if v_mine >= v_rule.per_member_limit then
      raise exception '每人限兑 % 张，你已经兑过了', v_rule.per_member_limit;
    end if;
  end if;
  -- 规则上的领取条件（等级、消费额…）跟其它发放方式共用同一套引擎
  if not public._coupon_cond_ok(v_rule.conditions, public._coupon_facts(p_member_id, '{}'::jsonb)) then
    raise exception '你还不满足这张券的兑换条件';
  end if;

  select coins into v_coins from public.members where id = p_member_id for update;
  if v_coins < v_rule.coin_price then
    raise exception 'Coin 不足：需要 %，当前 %', v_rule.coin_price, v_coins;
  end if;

  update public.members set coins = coins - v_rule.coin_price where id = p_member_id;
  insert into public.member_coin_ledger(member_id, delta, reason, ref_type, ref_id)
    values (p_member_id, -v_rule.coin_price, 'mall_redeem', 'coupon', p_coupon_id::text);

  insert into public.member_coupons(member_id, coupon_id, status, expires_at, source_rule_id)
    values (p_member_id, p_coupon_id, 'unused', public._coupon_expiry_for(p_coupon_id), v_rule.id)
    returning id into v_new_id;
  update public.coupon_rules set issued_count = issued_count + 1 where id = v_rule.id;

  return v_new_id;
end;
$$;

-- ── 11) 顾客端「我的优惠券」：把新字段一起带出去 ─────────────────────────────
--      小程序要靠这些字段在结算页把「这张券在当前用餐方式下不可用」提前灰掉，
--      而不是等顾客点了才被服务端拒绝。
create or replace function public.rpc_get_my_coupons(p_member_id uuid, p_session_token text)
returns table(
  id uuid, coupon_id uuid, name text, type text, value numeric, min_spend numeric,
  status text, issued_at timestamptz, expires_at timestamptz,
  menu_item_name text, menu_item_image text,
  max_discount numeric, channels jsonb, applies_to jsonb, valid_from timestamptz)
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public._auth_member(p_member_id, p_session_token);
  update public.member_coupons mc set status = 'expired'
   where mc.member_id = p_member_id and mc.status = 'unused'
     and mc.expires_at is not null and mc.expires_at < now();
  return query
  select mc.id, mc.coupon_id, c.name, c.type, c.value, c.min_spend,
         mc.status, mc.issued_at, mc.expires_at, mi.name, mi.image_url,
         c.max_discount, c.channels, coalesce(c.applies_to,'{"scope":"order"}'::jsonb), c.valid_from
    from public.member_coupons mc
    join public.coupons c on c.id = mc.coupon_id
    left join public.menu_items mi on mi.id = c.menu_item_id
   where mc.member_id = p_member_id
   order by (mc.status = 'unused') desc, mc.issued_at desc;
end;
$$;

-- ── 12) POS 收银台读会员的券：同样带上新字段 ───────────────────────────────
create or replace function public.rpc_pos_member_coupons(p_member_id uuid)
returns table(
  id uuid, coupon_id uuid, name text, type text, value numeric, min_spend numeric,
  expires_at timestamptz, menu_item_id uuid, menu_item_name text,
  max_discount numeric, channels jsonb, applies_to jsonb, valid_from timestamptz)
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.member_coupons mc set status = 'expired'
   where mc.member_id = p_member_id and mc.status = 'unused'
     and mc.expires_at is not null and mc.expires_at < now();
  return query
  select mc.id, mc.coupon_id, c.name, c.type, c.value, c.min_spend,
         mc.expires_at, c.menu_item_id, mi.name,
         c.max_discount, c.channels, coalesce(c.applies_to,'{"scope":"order"}'::jsonb), c.valid_from
    from public.member_coupons mc
    join public.coupons c on c.id = mc.coupon_id
    left join public.menu_items mi on mi.id = c.menu_item_id
   where mc.member_id = p_member_id and mc.status = 'unused'
   order by mc.issued_at desc;
end;
$$;

-- ── 13) 规则派发器：发券时用新的到期算法 ────────────────────────────────────
--      _coupon_fire 是 supabase-coupon-rules.sql 里的，这里只改它算 expires_at
--      那一句。整段重贴是为了避免「两个文件各改一半」——那是这个项目已经吃过
--      两次亏的地方（rpc_member_register 被三个文件轮流覆盖）。
create or replace function public._coupon_fire(p_event text, p_member_id uuid, p_ctx jsonb)
returns int
language plpgsql
security definer
set search_path = public, extensions
as $$
declare c record; v_facts jsonb; v_mine int; v_n int := 0;
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
      select count(*) into v_mine from public.member_coupons
       where member_id = p_member_id and source_rule_id = c.id;
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

-- ── 14) 权限 ────────────────────────────────────────────────────────────────
grant execute on function public.rpc_preview_coupon(uuid, text, uuid, numeric, uuid[], text) to anon;
grant execute on function public.rpc_consume_coupon(uuid, text, uuid, text, numeric, uuid[], text) to anon;
grant execute on function public.rpc_admin_issue_coupon(uuid, uuid) to anon;
grant execute on function public.rpc_list_mall_coupons() to anon;
grant execute on function public.rpc_redeem_coupon(uuid, text, uuid) to anon;
grant execute on function public.rpc_get_my_coupons(uuid, text) to anon;
grant execute on function public.rpc_pos_member_coupons(uuid) to anon;

-- ── 15) 对账：跑完看一眼迁移结果 ────────────────────────────────────────────
select
  (select count(*) from public.coupons)                                              as 券模板数,
  (select count(*) from public.coupons where applies_to is not null)                 as 已填适用范围,
  (select count(*) from public.coupons where coalesce(coin_price,0) > 0)             as 旧兑换价残留,
  (select count(*) from public.coupon_rules where trigger_event = 'coin_redeem')     as 兑换规则数,
  (select count(*) from public.coupons where max_discount is not null)               as 已设封顶,
  (select count(*) from public.coupons
    where channels is not null and jsonb_array_length(channels) > 0)                 as 已限渠道;
