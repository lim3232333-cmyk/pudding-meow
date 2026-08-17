-- ============================================================================
--  布丁喵 — 「我的券」也带上店家传的券面图 + 可选的单独券面图
--  用法：Supabase Dashboard → SQL Editor → New query → 整段粘贴 → Run。
--        跑一次就好，可以重复跑（幂等）。
--  前置：supabase-coupon-v3.sql（加了 usable_days / usable_hours）
--        supabase-coupon-mall-category.sql（加了 coupons.mall_image_url）
--
--  「我的券」那一页（Figma 1124:1572）每张券上面有一块 128 高的券面，跟积分商城
--  卡片上半部是同一张图（coupons.mall_image_url，店家在 POS 上传，可以是 SVG）。
--  但 rpc_get_my_coupons 一直没把这一列带出去，顾客从商城兑到手之后，那张图就没了。
--
--  前端还留着一条兜底：按 coupon_id 去商城列表里回查图。所以不跑这份脚本也不会坏，
--  只是**商城里已经下架、或不是从商城来的券**（注册赠券、兑换码、客诉补发）看不到图。
--
--  另外加一列 voucher_image_url：两个槽位比例不一样（商城卡 230×98 = 2.35，
--  券面 345×128 = 2.70），差 13%。默认**只传一张**母图（680×270，重要内容留在
--  中间 630×250），两处 cover 各切掉 3% 出血就够了 —— 让店家每张券传两遍，
--  迟早有一张忘了传，漏的那张比切掉 3% 难看得多。
--  所以 voucher_image_url 是**可选的覆盖**，留空就用 mall_image_url，
--  只有哪张券在券包里确实不好看时才单独补一张。
--
--  ⚠ 返回的列变了，create or replace 改不动，必须先 drop —— 这一条栽过一次
--    （ERROR 42P13: cannot change return type of existing function）。
--    Supabase 的 SQL Editor 把整段包在一个事务里跑，中途失败会整段回滚，
--    所以「先删再建」不会把函数删了建不回来。
-- ============================================================================

-- 前置检查：缺列就在这里说人话，而不是等下面 create function 报一句 column does not exist
do $$
begin
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='coupons' and column_name='usable_days') then
    raise exception '请先跑 supabase-coupon-v3.sql —— coupons 还没有 usable_days / usable_hours 列';
  end if;
  if not exists (select 1 from information_schema.columns
                  where table_schema='public' and table_name='coupons' and column_name='mall_image_url') then
    raise exception '请先跑 supabase-coupon-mall-category.sql —— coupons 还没有 mall_image_url 列';
  end if;
end $$;

--  可选的券面图（345×128 那个槽位）。留空 = 用 mall_image_url，不是必填项。
alter table public.coupons
  add column if not exists voucher_image_url text;
comment on column public.coupons.voucher_image_url is
  '「我的券」券面图（345×128 位置）。留空则用 mall_image_url —— 默认只传一张母图（680×270，安全区 630×250），只有这张券在券包里构图确实不好看时才单独补。';

drop function if exists public.rpc_get_my_coupons(uuid, text);
create or replace function public.rpc_get_my_coupons(p_member_id uuid, p_session_token text)
returns table(
  id uuid, coupon_id uuid, name text, type text, value numeric, min_spend numeric,
  status text, issued_at timestamptz, expires_at timestamptz,
  menu_item_name text, menu_item_image text,
  max_discount numeric, channels jsonb, applies_to jsonb, valid_from timestamptz,
  usable_days jsonb, usable_hours jsonb, mall_image_url text, voucher_image_url text)
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
         c.usable_days, c.usable_hours, c.mall_image_url, c.voucher_image_url
    from public.member_coupons mc
    join public.coupons c on c.id = mc.coupon_id
    left join public.menu_items mi on mi.id = c.menu_item_id
   where mc.member_id = p_member_id
   order by (mc.status = 'unused') desc, mc.issued_at desc;
end;
$$;

grant execute on function public.rpc_get_my_coupons(uuid, text) to anon;

-- 对账：会员手上有多少张券、其中几张能显示店家传的券面图
select count(*)                                                            as 已发出的券,
       count(*) filter (where mc.status = 'unused')                        as 还没用的,
       count(*) filter (where coalesce(c.voucher_image_url, c.mall_image_url) is not null) as 有券面图的,
       count(*) filter (where c.voucher_image_url is not null)             as 单独补过券面图的
  from public.member_coupons mc
  join public.coupons c on c.id = mc.coupon_id;
