-- ============================================================================
--  布丁喵 — 会员收货地址簿（外卖用）
--  用法：Supabase Dashboard → SQL Editor → New query → 粘贴全部 → Run
--  依赖 supabase-membership.sql 已经跑过（用到 public.members、public._auth_member）。
--
--  地址含姓名/电话/门牌号等个人资料，跟 members 表一样：不给 anon 任何直接读写权限，
--  全部走下面的 security definer RPC（函数内部用 p_session_token 校验身份）。
-- ============================================================================

-- ---------- 1) 地址表 ----------
create table if not exists public.member_addresses (
  id             uuid primary key default gen_random_uuid(),
  member_id      uuid not null references public.members(id) on delete cascade,
  label          text,                    -- 地点名称，如 Home / Office，选填
  unit_no        text not null,           -- 单位号/门牌号
  address        text not null,           -- 地址
  postcode       text not null,           -- 邮政编码
  city           text not null,           -- 城市
  recipient_name text not null,           -- 收件人姓名
  phone          text not null,           -- 手机号码
  remarks        text,                    -- 备注，选填
  lat            numeric,                 -- 坐标（算 Lalamove 运费用；填地址时用定位按钮才有）
  lng            numeric,
  is_default     boolean not null default false,
  created_at     timestamptz not null default now()
);
create index if not exists member_addresses_member_idx on public.member_addresses (member_id);

alter table public.member_addresses enable row level security;
-- 有意不建 anon policy：默认拒绝所有直接访问，全部走下面的 RPC。

-- ---------- 2) 我的地址列表 ----------
create or replace function public.rpc_list_my_addresses(p_member_id uuid, p_session_token text)
returns table(id uuid, label text, unit_no text, address text, postcode text, city text,
              recipient_name text, phone text, remarks text, lat numeric, lng numeric,
              is_default boolean, created_at timestamptz)
language plpgsql security definer as $$
begin
  perform public._auth_member(p_member_id, p_session_token);
  return query select a.id, a.label, a.unit_no, a.address, a.postcode, a.city,
                      a.recipient_name, a.phone, a.remarks, a.lat, a.lng, a.is_default, a.created_at
    from public.member_addresses a
    where a.member_id = p_member_id
    order by a.is_default desc, a.created_at desc;
end; $$;

-- ---------- 3) 新增/编辑地址（p_id 传已有地址 id 就是编辑，不传就是新增）----------
create or replace function public.rpc_save_address(
  p_member_id uuid, p_session_token text,
  p_unit_no text, p_address text, p_postcode text, p_city text, p_recipient_name text, p_phone text,
  p_id uuid default null, p_label text default null, p_remarks text default null,
  p_lat numeric default null, p_lng numeric default null, p_is_default boolean default false
) returns uuid
language plpgsql security definer as $$
declare v_id uuid; v_is_first boolean;
begin
  perform public._auth_member(p_member_id, p_session_token);
  select not exists(select 1 from public.member_addresses where member_id = p_member_id and id <> coalesce(p_id,'00000000-0000-0000-0000-000000000000'::uuid))
    into v_is_first;
  if v_is_first then p_is_default := true; end if;   -- 第一个地址自动设为默认

  if p_is_default then
    update public.member_addresses set is_default = false
      where member_id = p_member_id and id <> coalesce(p_id,'00000000-0000-0000-0000-000000000000'::uuid);
  end if;

  if p_id is not null then
    update public.member_addresses set
      label = p_label, unit_no = p_unit_no, address = p_address, postcode = p_postcode, city = p_city,
      recipient_name = p_recipient_name, phone = p_phone, remarks = p_remarks,
      lat = p_lat, lng = p_lng, is_default = p_is_default
    where id = p_id and member_id = p_member_id
    returning id into v_id;
    if v_id is null then raise exception '地址不存在或不属于该会员'; end if;
  else
    insert into public.member_addresses
      (member_id, label, unit_no, address, postcode, city, recipient_name, phone, remarks, lat, lng, is_default)
      values (p_member_id, p_label, p_unit_no, p_address, p_postcode, p_city, p_recipient_name, p_phone, p_remarks, p_lat, p_lng, p_is_default)
      returning id into v_id;
  end if;
  return v_id;
end; $$;

-- ---------- 4) 删除地址 ----------
create or replace function public.rpc_delete_address(p_member_id uuid, p_session_token text, p_id uuid)
returns void language plpgsql security definer as $$
begin
  perform public._auth_member(p_member_id, p_session_token);
  delete from public.member_addresses where id = p_id and member_id = p_member_id;
end; $$;

grant execute on function public.rpc_list_my_addresses(uuid, text) to anon;
grant execute on function public.rpc_save_address(uuid, text, text, text, text, text, text, text, uuid, text, text, numeric, numeric, boolean) to anon;
grant execute on function public.rpc_delete_address(uuid, text, uuid) to anon;

-- 完成。小程序"外卖"下单流程会读/写这几个 RPC：选已存地址、新增/编辑地址、删除地址。
