-- ============================================================================
--  布丁喵 — 优惠券 v3（第二期）：兑换码 · 免运费券 · 时段限制 · 使用报表
--  用法：Supabase Dashboard → SQL Editor → New query → 整段粘贴 → Run。
--        跑一次就好，可以重复跑（幂等）。
--  前置：supabase-coupon-v2.sql 已跑过。
--
--  这一期加的四样，都是「一张券还能怎么发、怎么限」的延伸：
--
--    A) 兑换码   —— 海报/网红推广用的通用码（PUDDING10），和一人一码的一次性码
--    B) 免运费券 —— 抵的是配送费，不是商品金额
--    C) 时段限制 —— 只能周一到周四下午 2-5 点用（下午茶时段）
--    D) 使用报表 —— 发了多少、用了多少、带来多少营业额
--
--  ⚠ 一单只能用一张券（店家定的口径）。所以免运费券会占掉那唯一的名额——
--    顾客要么省运费，要么打折，不能两个都要。这是刻意的：真要两张一起用，
--    得先想清楚叠加顺序和总折扣上限，那是另一个决定，不该顺手做掉。
-- ============================================================================

-- ── A) 兑换码 ───────────────────────────────────────────────────────────────
--    通用码和一次性码是同一张表的两种 kind，不另开一张表：两者的校验逻辑
--    （时间窗、总量、每人限领）一模一样，分表就要写两遍，迟早改漏一边。
--      public  一串码大家都能用，靠 max_uses / per_member_limit 控量
--      unique  一人一码，max_uses 恒为 1，用完即废（赔付、合作方派发）
create table if not exists public.coupon_codes (
  id            uuid primary key default gen_random_uuid(),
  coupon_id     uuid not null references public.coupons(id) on delete cascade,
  code          text not null,
  kind          text not null default 'public',      -- public | unique
  max_uses      int,                                  -- null = 不限；unique 恒为 1
  used_count    int not null default 0,
  per_member_limit int not null default 1,            -- 0 = 不限
  batch         text,                                 -- 一次性码的批次名，方便筛选/导出
  starts_at     timestamptz,
  ends_at       timestamptz,
  enabled       boolean not null default true,
  created_at    timestamptz not null default now()
);
--  码一律存大写：顾客打 pudding10 和 PUDDING10 必须是同一串，
--  唯一索引也建在大写上，否则能建出两条只差大小写的码。
create unique index if not exists coupon_codes_code_uidx on public.coupon_codes (upper(code));
create index if not exists coupon_codes_coupon_idx on public.coupon_codes (coupon_id);
create index if not exists coupon_codes_batch_idx on public.coupon_codes (batch);

--  券实例记一下是哪串码换来的：既是审计，也是「每人限领」的计数依据。
--  跟 source_rule_id 分开两列而不是合成一个多态列——查询要 join 的表不同，
--  合起来只会让每次查询都得先判断类型。
alter table public.member_coupons
  add column if not exists source_code_id uuid references public.coupon_codes(id) on delete set null;
create index if not exists member_coupons_code_idx on public.member_coupons (source_code_id, member_id);

alter table public.coupon_codes enable row level security;
drop policy if exists coupon_codes_anon_read on public.coupon_codes;
create policy coupon_codes_anon_read on public.coupon_codes for select to anon using (true);
drop policy if exists coupon_codes_anon_write on public.coupon_codes;
create policy coupon_codes_anon_write on public.coupon_codes for all to anon using (true) with check (true);

-- ── B) 免运费券 + C) 时段限制：券模板加列 ───────────────────────────────────
alter table public.coupons
  --  只能在这些星期几用（1=周一 … 7=周日）。null / [] = 不限。
  add column if not exists usable_days  jsonb,
  --  只能在这个钟点区间用，{"from":14,"to":17} = 14:00–16:59。null = 不限。
  --  跨夜（from > to，如 21→2）也支持，见 _coupon_hour_ok。
  add column if not exists usable_hours jsonb;

comment on column public.coupons.usable_days is
  '可用星期，jsonb 数组，1=周一…7=周日。null 或 [] = 不限。按马来西亚时区判。';
comment on column public.coupons.usable_hours is
  '可用时段 {"from":14,"to":17} = 14:00 到 16:59。null = 不限。from>to 表示跨夜。';

--  type 多一种 free_delivery。刻意不加 check 约束：这张表的 type 一直是裸 text，
--  加约束会让还没跑这份脚本的旧库在写入时炸掉，收益也就是防一个手滑。

-- ── 时段判断 ────────────────────────────────────────────────────────────────
create or replace function public._coupon_hour_ok(p_hours jsonb, p_now timestamptz)
returns boolean
language plpgsql
immutable
as $$
declare h int; a int; b int;
begin
  if p_hours is null or jsonb_typeof(p_hours) <> 'object' then return true; end if;
  a := (p_hours->>'from')::int; b := (p_hours->>'to')::int;
  if a is null or b is null then return true; end if;
  h := extract(hour from p_now)::int;
  if a = b then return true; end if;               -- 首尾相同当作不限，别把顾客锁死
  if a < b then return h >= a and h < b; end if;   -- 14→17 = 14:00–16:59
  return h >= a or h < b;                          -- 21→2 跨夜
end;
$$;

create or replace function public._coupon_day_ok(p_days jsonb, p_now timestamptz)
returns boolean
language sql
immutable
as $$
  select p_days is null
      or jsonb_typeof(p_days) <> 'array'
      or jsonb_array_length(p_days) = 0
      or exists (select 1 from jsonb_array_elements_text(p_days) e
                  where e::int = extract(isodow from p_now)::int);
$$;

-- ── 核心：算折扣（加上免运费 / 时段 / 星期）─────────────────────────────────
--    签名多了 p_delivery_fee。免运费券抵的是配送费，不能拿商品小计去封顶它，
--    否则一张 RM0 商品 + RM8 运费的单会被 least(disc, subtotal) 削成 0。
drop function if exists public._coupon_calc(uuid, uuid, numeric, uuid[], text);
create or replace function public._coupon_calc(
  p_member_id uuid, p_member_coupon_id uuid, p_subtotal numeric,
  p_item_ids uuid[], p_mode text default null, p_delivery_fee numeric default 0)
returns numeric
language plpgsql
stable
set search_path = public
as $$
declare v record; v_disc numeric; v_price numeric; v_mode text; v_chs jsonb; v_now timestamptz;
begin
  select mc.status, mc.expires_at, mc.member_id,
         c.type, c.value, c.min_spend, c.name,
         c.max_discount, c.channels, c.valid_from,
         c.usable_days, c.usable_hours,
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

  -- 时段/星期：跟营业日、每周任务一个时区口径
  v_now := now() at time zone 'Asia/Kuala_Lumpur';
  if not public._coupon_day_ok(v.usable_days, v_now) then
    raise exception '这张券今天不能用';
  end if;
  if not public._coupon_hour_ok(v.usable_hours, v_now) then
    raise exception '这张券只能在 %:00–%:00 使用',
      (v.usable_hours->>'from'), (v.usable_hours->>'to');
  end if;

  if p_subtotal < coalesce(v.min_spend, 0) then
    raise exception '未达使用门槛：需满 RM%，当前 RM%', v.min_spend, p_subtotal;
  end if;

  -- 使用渠道。p_mode 传空 = 调用方没说（旧前端），此时不拦。
  v_chs := v.channels;
  if v_chs is not null and jsonb_typeof(v_chs) = 'array' and jsonb_array_length(v_chs) > 0
     and coalesce(p_mode,'') <> '' then
    v_mode := public._coupon_norm_mode(p_mode);
    if not exists (select 1 from jsonb_array_elements_text(v_chs) e
                    where public._coupon_norm_mode(e) = v_mode) then
      raise exception '这张券在当前用餐方式下不可用';
    end if;
  end if;

  -- 免运费券：抵的是配送费，跟商品无关，所以走单独一条路，不碰 applies_to
  if v.type = 'free_delivery' then
    if coalesce(p_mode,'') <> '' and public._coupon_norm_mode(p_mode) <> 'delivery' then
      raise exception '免运费券只能用在外卖单上';
    end if;
    v_disc := coalesce(p_delivery_fee, 0);
    if v.max_discount is not null and v.max_discount >= 0 then
      v_disc := least(v_disc, v.max_discount);     -- 「最多免 RM8」，超出部分顾客自付
    end if;
    return greatest(coalesce(v_disc, 0), 0);
  end if;

  -- 适用范围：null = 整单；-1 = 车里没有符合的商品；其余 = 命中那份的单价
  v_price := public._coupon_item_price(v.applies_to, p_item_ids);
  if v_price is not null and v_price < 0 then
    raise exception '购物车里没有「%」适用的商品', v.name;
  end if;

  if v.type = 'dessert' then
    if v_price is null then raise exception '该兑换券未指定商品，请联系店员'; end if;
    v_disc := v_price;
  elsif v.type = 'percent_off' then
    v_disc := round(coalesce(v_price, p_subtotal) * coalesce(v.value, 0) / 100.0, 2);
    if v.max_discount is not null and v.max_discount >= 0 then
      v_disc := least(v_disc, v.max_discount);
    end if;
  else   -- fixed_off
    v_disc := coalesce(v.value, 0);
    if v_price is not null then v_disc := least(v_disc, v_price); end if;
  end if;

  return least(greatest(coalesce(v_disc, 0), 0), p_subtotal);
end;
$$;

create or replace function public.rpc_preview_coupon(
  p_member_id uuid, p_session_token text, p_member_coupon_id uuid,
  p_subtotal numeric, p_item_ids uuid[] default null, p_mode text default null,
  p_delivery_fee numeric default 0)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public._auth_member(p_member_id, p_session_token);
  return public._coupon_calc(p_member_id, p_member_coupon_id, p_subtotal, p_item_ids, p_mode, p_delivery_fee);
end;
$$;

create or replace function public.rpc_consume_coupon(
  p_member_id uuid, p_session_token text, p_member_coupon_id uuid,
  p_order_id text, p_subtotal numeric, p_item_ids uuid[] default null,
  p_mode text default null, p_delivery_fee numeric default 0)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare v_disc numeric; v_status text;
begin
  perform public._auth_member(p_member_id, p_session_token);
  select status into v_status from public.member_coupons
   where id = p_member_coupon_id for update;
  if v_status is null then raise exception '优惠券不存在'; end if;

  v_disc := public._coupon_calc(p_member_id, p_member_coupon_id, p_subtotal, p_item_ids, p_mode, p_delivery_fee);

  update public.member_coupons
     set status = 'used', used_at = now(), order_id = p_order_id
   where id = p_member_coupon_id;
  return v_disc;
end;
$$;

-- ── 兑换码：顾客输码领券 ────────────────────────────────────────────────────
create or replace function public.rpc_redeem_code(
  p_member_id uuid, p_session_token text, p_code text)
returns table(coupon_name text, member_coupon_id uuid)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare v_code record; v_coupon record; v_mine int; v_new uuid; v_norm text;
begin
  perform public._auth_member(p_member_id, p_session_token);
  v_norm := upper(trim(coalesce(p_code,'')));
  if v_norm = '' then raise exception '请输入兑换码'; end if;

  -- 锁住这一行再数：两台设备同时输同一串码，后来的那次看得见前一次的插入
  select * into v_code from public.coupon_codes where upper(code) = v_norm for update;
  if v_code is null then raise exception '兑换码不存在'; end if;
  if not v_code.enabled then raise exception '这串兑换码已停用'; end if;
  if v_code.starts_at is not null and now() < v_code.starts_at then raise exception '这串兑换码还没开始'; end if;
  if v_code.ends_at   is not null and now() > v_code.ends_at   then raise exception '这串兑换码已过期'; end if;
  if v_code.max_uses is not null and v_code.used_count >= v_code.max_uses then
    raise exception '这串兑换码已经用完了';
  end if;
  if coalesce(v_code.per_member_limit,0) > 0 then
    select count(*) into v_mine from public.member_coupons
     where member_id = p_member_id and source_code_id = v_code.id;
    if v_mine >= v_code.per_member_limit then raise exception '你已经用过这串兑换码了'; end if;
  end if;

  select * into v_coupon from public.coupons where id = v_code.coupon_id;
  if v_coupon is null or not v_coupon.enabled then raise exception '这串码对应的券已下架'; end if;

  insert into public.member_coupons(member_id, coupon_id, status, expires_at, source_code_id)
    values (p_member_id, v_code.coupon_id, 'unused', public._coupon_expiry_for(v_code.coupon_id), v_code.id)
    returning id into v_new;
  update public.coupon_codes set used_count = used_count + 1 where id = v_code.id;

  return query select v_coupon.name, v_new;
end;
$$;

-- ── 兑换码：后台批量生成一次性码 ────────────────────────────────────────────
--    码在服务端生成，不让前端提交自造的码：前端生成撞号了只会静默少发几张。
--    字符集刻意去掉 0/O/1/I/L —— 印在小票或海报上，顾客会把它们看混。
create or replace function public.rpc_admin_gen_codes(
  p_coupon_id uuid, p_count int, p_prefix text default '',
  p_batch text default null, p_per_member_limit int default 1,
  p_starts_at timestamptz default null, p_ends_at timestamptz default null)
returns table(code text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_alpha text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  v_code text; v_i int := 0; v_try int; v_ok boolean;
begin
  if p_count is null or p_count < 1 or p_count > 2000 then
    raise exception '一次最多生成 2000 串';
  end if;
  if not exists (select 1 from public.coupons where id = p_coupon_id) then
    raise exception '优惠券不存在';
  end if;

  while v_i < p_count loop
    v_ok := false; v_try := 0;
    -- 撞号就重摇；连摇 20 次还撞说明码位太短或量太大，直接报错让店家加长前缀
    while not v_ok and v_try < 20 loop
      v_code := upper(coalesce(p_prefix,'')) ||
                (select string_agg(substr(v_alpha, 1 + floor(random()*length(v_alpha))::int, 1), '')
                   from generate_series(1, 8));
      begin
        insert into public.coupon_codes(coupon_id, code, kind, max_uses, per_member_limit,
                                        batch, starts_at, ends_at)
          values (p_coupon_id, v_code, 'unique', 1, greatest(coalesce(p_per_member_limit,1),1),
                  p_batch, p_starts_at, p_ends_at);
        v_ok := true;
      exception when unique_violation then
        v_try := v_try + 1;
      end;
    end loop;
    if not v_ok then raise exception '生成失败：连续撞号，请换一个前缀'; end if;
    v_i := v_i + 1;
    code := v_code; return next;
  end loop;
end;
$$;

-- ── D) 使用报表 ─────────────────────────────────────────────────────────────
--    发了多少 / 用了多少 / 核销率 / 带来多少营业额。
--    营业额用 orders.total 减掉 admin_fee（手续费是代收转付给 HitPay 的，不是店家的钱），
--    跟仪表盘、月报一个口径 —— 三处不一致的话同一天会读出三个数。
create or replace function public.rpc_admin_coupon_stats()
returns table(
  coupon_id uuid, name text, type text,
  issued int, used int, expired int, unused int,
  use_rate numeric, discount_total numeric, revenue_total numeric, order_count int)
language plpgsql
security definer
set search_path = public
as $$
begin
  return query
  with mc as (
    select c.id as cid, c.name as cname, c.type as ctype, m.id as mcid, m.status as st
      from public.coupons c
      left join public.member_coupons m on m.coupon_id = c.id
  ),
  ord as (
    select m.coupon_id as cid,
           count(*)::int as ocnt,
           coalesce(sum(o.discount), 0) as disc,
           coalesce(sum(greatest(coalesce(o.total,0) - coalesce(o.admin_fee,0), 0)), 0) as rev
      from public.orders o
      join public.member_coupons m on m.id = o.coupon_id
     where coalesce(o.status,'') in ('paid','preparing','ready','done')
     group by m.coupon_id
  )
  select mc.cid, mc.cname, mc.ctype,
         count(mc.mcid)::int,
         count(*) filter (where mc.st = 'used')::int,
         count(*) filter (where mc.st = 'expired')::int,
         count(*) filter (where mc.st = 'unused')::int,
         case when count(mc.mcid) = 0 then 0
              else round(count(*) filter (where mc.st = 'used')::numeric * 100 / count(mc.mcid), 1) end,
         coalesce(max(ord.disc), 0),
         coalesce(max(ord.rev), 0),
         coalesce(max(ord.ocnt), 0)
    from mc left join ord on ord.cid = mc.cid
   group by mc.cid, mc.cname, mc.ctype
   order by count(mc.mcid) desc, mc.cname;
end;
$$;

-- ── 顾客端 / POS 读券：把时段限制一起带出去 ─────────────────────────────────
drop function if exists public.rpc_get_my_coupons(uuid, text);
create or replace function public.rpc_get_my_coupons(p_member_id uuid, p_session_token text)
returns table(
  id uuid, coupon_id uuid, name text, type text, value numeric, min_spend numeric,
  status text, issued_at timestamptz, expires_at timestamptz,
  menu_item_name text, menu_item_image text,
  max_discount numeric, channels jsonb, applies_to jsonb, valid_from timestamptz,
  usable_days jsonb, usable_hours jsonb)
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
         c.max_discount, c.channels, coalesce(c.applies_to,'{"scope":"order"}'::jsonb), c.valid_from,
         c.usable_days, c.usable_hours
    from public.member_coupons mc
    join public.coupons c on c.id = mc.coupon_id
    left join public.menu_items mi on mi.id = c.menu_item_id
   where mc.member_id = p_member_id
   order by (mc.status = 'unused') desc, mc.issued_at desc;
end;
$$;

drop function if exists public.rpc_pos_member_coupons(uuid);
create or replace function public.rpc_pos_member_coupons(p_member_id uuid)
returns table(
  id uuid, coupon_id uuid, name text, type text, value numeric, min_spend numeric,
  expires_at timestamptz, menu_item_id uuid, menu_item_name text,
  max_discount numeric, channels jsonb, applies_to jsonb, valid_from timestamptz,
  usable_days jsonb, usable_hours jsonb)
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
         c.max_discount, c.channels, coalesce(c.applies_to,'{"scope":"order"}'::jsonb), c.valid_from,
         c.usable_days, c.usable_hours
    from public.member_coupons mc
    join public.coupons c on c.id = mc.coupon_id
    left join public.menu_items mi on mi.id = c.menu_item_id
   where mc.member_id = p_member_id and mc.status = 'unused'
   order by mc.issued_at desc;
end;
$$;

-- ── 权限 ────────────────────────────────────────────────────────────────────
grant execute on function public.rpc_preview_coupon(uuid, text, uuid, numeric, uuid[], text, numeric) to anon;
grant execute on function public.rpc_consume_coupon(uuid, text, uuid, text, numeric, uuid[], text, numeric) to anon;
grant execute on function public.rpc_redeem_code(uuid, text, text) to anon;
grant execute on function public.rpc_admin_gen_codes(uuid, int, text, text, int, timestamptz, timestamptz) to anon;
grant execute on function public.rpc_admin_coupon_stats() to anon;
grant execute on function public.rpc_get_my_coupons(uuid, text) to anon;
grant execute on function public.rpc_pos_member_coupons(uuid) to anon;

-- ── 对账 ────────────────────────────────────────────────────────────────────
select (select count(*) from public.coupon_codes)                                   as 兑换码数,
       (select count(*) from public.coupon_codes where kind='public')                as 通用码,
       (select count(*) from public.coupon_codes where kind='unique')                as 一次性码,
       (select count(*) from public.coupons where type='free_delivery')              as 免运费券,
       (select count(*) from public.coupons
         where usable_days is not null or usable_hours is not null)                  as 有时段限制的券;
