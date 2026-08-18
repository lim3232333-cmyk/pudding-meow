-- ============================================================================
--  布丁喵 — 积分商城允许「0 Coin 免费领」
--  用法：Supabase Dashboard → SQL Editor → New query → 整段粘贴 → Run。
--        跑一次就好，可以重复跑（幂等）。
--  前置：supabase-coupon-v2.sql、supabase-coupon-mall-category.sql
--
--  原来兑换价必须 > 0：`coalesce(coin_price,0) > 0` 同时兼了两个意思——
--  「有没有上架到商城」和「要花多少 Coin」。这两件事挤在一个判断里，
--  于是「上架了，但不要钱」根本表达不出来（免运费券、新人礼、节日发的券都是这种）。
--  拆开：**上架与否看 coin_price 是不是 null**（null = 没上架），
--  **价钱看它的数值**（0 = 免费领）。
--
--  ⚠ 0 Coin 意味着白送，所以「每人限领」这时候是**唯一**的闸门。
--    0 Coin + 每人不限领 = 顾客连点就能无限领券，那不是促销是漏洞。
--    下面的触发器在写规则时就拦住这种组合（拦在配置端，不是等顾客兑换时才报错——
--    那是拿顾客的脸去接店家的配置失误）。
-- ============================================================================

do $$
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='coupon_rules' and column_name='coin_price') then
    raise exception '请先跑 supabase-coupon-v2.sql —— coupon_rules 还没有 coin_price 列';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='coupons' and column_name='mall_category') then
    raise exception '请先跑 supabase-coupon-mall-category.sql —— coupons 还没有 mall_category / mall_image_url 列';
  end if;
end $$;

-- ── 1) 配置端的闸门：0 Coin 的规则必须限领 ──────────────────────────────────
create or replace function public._coupon_rule_guard()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.trigger_event = 'coin_redeem'
     and coalesce(new.coin_price, -1) = 0
     and coalesce(new.per_member_limit, 0) = 0 then
    raise exception '0 Coin 的商城券必须设「每人限领」（填 1 就好）—— 免费又不限领，顾客连点就能无限领';
  end if;
  return new;
end;
$$;
drop trigger if exists coupon_rules_guard on public.coupon_rules;
create trigger coupon_rules_guard
  before insert or update on public.coupon_rules
  for each row execute function public._coupon_rule_guard();

-- ── 2) 商城列表：上架与否改看 coin_price 是不是 null ────────────────────────
--  仍然先 drop：库里可能还是更早那版（列少几个），create or replace 会报
--  cannot change return type。
--
--  ⚠ 这里必须**带上 image_pos**（取景位置，supabase-coupon-image-pos.sql 加的），
--    哪怕那份脚本还没跑。原因：这份脚本是「可以重复跑」的，而它一旦在
--    image-pos 之后再跑一次，就会把商城列表函数换回没有 image_pos 的旧版——
--    于是「我的卷」照常跟着取景走（它读的是另一个函数），**只有兑好礼不动**。
--    这种「重跑一份旧脚本把新功能悄悄抹掉」是这个项目最难查的一类 bug，
--    所以列一旦被任何一份脚本用到，每一份重建这个函数的脚本都要带着它。
alter table public.coupons
  add column if not exists image_pos text,
  add column if not exists description text;

drop function if exists public.rpc_list_mall_coupons();
create or replace function public.rpc_list_mall_coupons()
returns table(
  id uuid, name text, type text, value numeric, min_spend numeric,
  valid_days int, coin_price int, menu_item_id uuid, menu_item_name text, menu_item_image text,
  max_discount numeric, channels jsonb, applies_to jsonb, rule_id uuid,
  mall_category text, mall_image_url text, image_pos text, description text)
language plpgsql
security definer
set search_path = public
as $$
begin
  return query
  select c.id, c.name, c.type, c.value, c.min_spend, c.valid_days, r.coin_price,
         c.menu_item_id, mi.name, mi.image_url,
         c.max_discount, c.channels, coalesce(c.applies_to,'{"scope":"order"}'::jsonb), r.id,
         c.mall_category, c.mall_image_url, c.image_pos, c.description
    from public.coupons c
    join public.coupon_rules r on r.coupon_id = c.id
                              and r.trigger_event = 'coin_redeem'
                              and r.enabled
    left join public.menu_items mi on mi.id = c.menu_item_id
   where c.enabled
     and r.coin_price is not null            -- null = 没上架；0 = 上架了，免费领
     and (r.starts_at is null or now() >= r.starts_at)
     and (r.ends_at   is null or now() <= r.ends_at)
     and (r.total_limit is null or r.issued_count < r.total_limit)
   order by r.coin_price asc;                -- 免费的排最前面，本来就该最显眼
end;
$$;

-- ── 3) 兑换：0 Coin 不扣币、不写流水 ────────────────────────────────────────
--  ⚠ 只有在 supabase-coupon-limit-period.sql **还没跑**时才重建它。那份脚本给
--    rpc_redeem_coupon 加了「每人限领的计数周期」，这份是旧版；重复跑这份会
--    把周期判断悄悄抹掉（跟上面 image_pos 一模一样的坑）。检测到那一列就跳过。
do $guard$
begin
  if exists (select 1 from information_schema.columns
              where table_schema='public' and table_name='coupon_rules'
                and column_name='per_member_period') then
    raise notice '已检测到 per_member_period —— supabase-coupon-limit-period.sql 跑过了，它那版 rpc_redeem_coupon 更新，这里跳过重建，不覆盖它';
  else
    execute $sql$
      create or replace function public.rpc_redeem_coupon(
        p_member_id uuid, p_session_token text, p_coupon_id uuid)
      returns uuid
      language plpgsql
      security definer
      set search_path = public, extensions
      as $body$
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
        if v_rule is null or v_rule.coin_price is null then
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

        --  0 Coin 就整段跳过：不锁会员行、不扣、也不写一条 delta = 0 的流水
        --  （对账时那种 0 的行只会让人以为出过 bug）
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
      $body$;
    $sql$;
  end if;
end
$guard$;


grant execute on function public.rpc_list_mall_coupons() to anon;
grant execute on function public.rpc_redeem_coupon(uuid, text, uuid) to anon;

-- 对账：商城上现在有哪些券、各自多少 Coin、限领几张
select c.name as 券名, r.coin_price as coin价,
       case when r.coin_price = 0 then '免费领' else '要花 Coin' end as 类型,
       coalesce(r.per_member_limit,0) as 每人限领, r.total_limit as 总量, r.issued_count as 已发
  from public.coupon_rules r
  join public.coupons c on c.id = r.coupon_id
 where r.trigger_event = 'coin_redeem' and r.coin_price is not null
 order by r.coin_price, c.name;
