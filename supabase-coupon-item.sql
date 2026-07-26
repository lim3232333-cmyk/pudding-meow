-- ============================================================================
--  布丁喵 — 现金/百分比优惠券支持「只对某个单品打折」
--  用法：Supabase Dashboard → SQL Editor → New query → 粘贴 → Run（跑一次）
--  前置：supabase-coupon-apply.sql 已跑过。
--
--  原本 coupons.menu_item_id 只有甜品券在用（绑一件商品，抵掉全价＝免费送），
--  现金折扣 / 百分比折扣一律按整单小计算。现在放开：这两种券也能绑商品——
--  绑了就只对那件商品打折，没绑还是按整单算。
--
--    menu_item_id = null          → 整单：RM5 OFF / 8 折都按小计
--    menu_item_id 有值 + 非甜品券 → 单品：只抵那件商品「一份」的钱
--
--  一份，不是全部份数：顾客买 3 份布丁，「布丁 8 折」只打 1 份。
--  跟甜品券现在的口径一致，避免一张券把整车同款全打折。
--
--  单价一律从 menu_items 查，不接受前端传上来的价格——anon key 是公开的。
--  现金券还要用商品单价封顶：不然「布丁 RM5 OFF」用在 RM3 的商品上会倒贴。
-- ============================================================================

create or replace function public._coupon_calc(
  p_member_id uuid, p_member_coupon_id uuid, p_subtotal numeric, p_item_ids uuid[])
returns numeric
language plpgsql
stable
set search_path = public
as $$
declare v record; v_disc numeric; v_price numeric; v_item boolean;
begin
  select mc.status, mc.expires_at, mc.member_id,
         c.type, c.value, c.min_spend, c.menu_item_id, c.name
    into v
    from public.member_coupons mc
    join public.coupons c on c.id = mc.coupon_id
   where mc.id = p_member_coupon_id;

  if v is null then raise exception '优惠券不存在'; end if;
  if v.member_id <> p_member_id then raise exception '这不是你的优惠券'; end if;
  if v.status <> 'unused' then raise exception '该优惠券已使用或已失效'; end if;
  if v.expires_at is not null and v.expires_at < now() then raise exception '该优惠券已过期'; end if;
  if p_subtotal < coalesce(v.min_spend, 0) then
    raise exception '未达使用门槛：需满 RM%，当前 RM%', v.min_spend, p_subtotal;
  end if;

  -- 甜品券必须绑商品；现金/百分比券绑了就是单品券，没绑就是整单券
  v_item := v.menu_item_id is not null;
  if v.type = 'dessert' and not v_item then
    raise exception '该甜品券未绑定商品，请联系店员';
  end if;

  if v_item then
    if p_item_ids is null or not (v.menu_item_id = any(p_item_ids)) then
      raise exception '购物车里没有「%」，这张券用不了', v.name;
    end if;
    select coalesce(price, 0) into v_price from public.menu_items where id = v.menu_item_id;
    v_price := coalesce(v_price, 0);
    if v.type = 'dessert' then
      v_disc := v_price;                                        -- 兑换：抵掉一份的全价
    elsif v.type = 'percent_off' then
      v_disc := round(v_price * coalesce(v.value, 0) / 100.0, 2); -- 单品打折，只打一份
    else
      v_disc := least(coalesce(v.value, 0), v_price);            -- 单品减钱，封顶到这份的价钱
    end if;
  elsif v.type = 'percent_off' then
    v_disc := round(p_subtotal * coalesce(v.value, 0) / 100.0, 2);
  else   -- fixed_off
    v_disc := coalesce(v.value, 0);
  end if;

  -- 折扣不能超过小计，否则会算出负数总额
  return least(greatest(coalesce(v_disc, 0), 0), p_subtotal);
end;
$$;

-- 完成。POS 建现金/百分比券时多了「适用范围」，选「指定单品」就绑商品。
