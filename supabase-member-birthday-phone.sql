-- ============================================================================
--  布丁喵 — 注册加「生日」+ 手机号统一成 0127010189 这一种写法
--  用法：Supabase Dashboard → SQL Editor → New query → 粘贴 → Run（跑一次）
--  前置：supabase-membership.sql、supabase-pos-member.sql、supabase-member-admin.sql
--        都已经跑过（本文件会重建 rpc_admin_list_members，基线取 member-admin.sql 那版）。
--
--  ⚠️ rpc_member_register 在仓库里被改过好几轮，而且两条线互相盖掉了：
--     supabase-referral-v2.sql 那版会往 referrals 表写邀请关系，但默认等级还是老的（会挂到「未注册」档）；
--     supabase-member-default-level.sql 那版修了默认等级，却把 referrals 那句弄丢了。
--     本文件这版把两边都合进来了 —— 谁最后跑都不会再丢东西。
--
--  为什么要动手机号：
--    以前顾客怎么打就怎么存 —— +60 12-701 0189 / 6012 7010189 / 012-7010189
--    全都进得来。柜台在 POS 里按手机号找会员时，rpc_pos_find_member 比的是
--    「去掉非数字」后的字符串，60 开头和 0 开头对不上，店员照着单子输
--    0127010189 就是找不到人。现在一律存本地写法：纯数字、0 开头。
--
--  改动：
--   1) _norm_phone_my()：把任意写法归一成 0127010189
--   2) 把 members 里已有的号码就地归一（会冲突的那几条跳过并列出来，人工处理）
--   3) rpc_member_register：多收 p_birthday，且落库前归一 + 校验手机号
--   4) rpc_member_login：按归一后的号码找人（老号码存成 +60 的也还能登）
--   5) rpc_pos_find_member：同上，柜台输 0 开头也能找到历史上存成 60 开头的
--   6) rpc_admin_list_members：返回里补上 birthday（POS 会员列表多一列「生日」）
-- ============================================================================

-- ---------- 1) 归一函数 ----------
--  规则：去掉所有非数字；不是 0 开头而是 60 开头 → 去掉 60 补 0；1 开头 → 补 0。
--  其余原样返回（校验交给调用方，这里只负责统一写法）。
create or replace function public._norm_phone_my(p_phone text)
returns text
language plpgsql
immutable
as $$
declare d text;
begin
  d := regexp_replace(coalesce(p_phone, ''), '\D', '', 'g');
  if d = '' then return ''; end if;
  if left(d, 1) <> '0' and left(d, 2) = '60' then
    d := '0' || substr(d, 3);
  elsif left(d, 1) = '1' then
    d := '0' || d;
  end if;
  return d;
end;
$$;

-- ---------- 2) 存量号码就地归一 ----------
--  phone 上有 unique 约束：万一两条记录归一后撞成同一个号（同一个人注册过两次，
--  一次 +60 一次 0），跳过后面那条并打印出来，人工决定留哪个 —— 这里不敢替店家合并会员，
--  XP/Coin/储值/券都挂在各自的 id 上。
do $$
declare r record; v_new text; v_skipped int := 0;
begin
  for r in select id, phone from public.members order by created_at loop
    v_new := public._norm_phone_my(r.phone);
    continue when v_new = r.phone or v_new = '';
    if exists (select 1 from public.members m where m.phone = v_new and m.id <> r.id) then
      v_skipped := v_skipped + 1;
      raise notice '手机号冲突，未修改：会员 % 的 % 归一后是 %，但已有别的会员用这个号', r.id, r.phone, v_new;
    else
      update public.members set phone = v_new where id = r.id;
    end if;
  end loop;
  if v_skipped > 0 then
    raise notice '共 % 条因重号跳过，请在 POS 会员列表里人工核对', v_skipped;
  end if;
end $$;

-- ---------- 3) 注册：多收生日，手机号归一 + 校验 ----------
--  参数个数变了，留着旧的 4 参版本会让「按名字传参」变成有歧义的调用，必须先 drop。
drop function if exists public.rpc_member_register(text, text, text, text);
drop function if exists public.rpc_member_register(text, text, text, text, date);
create or replace function public.rpc_member_register(
  p_phone text,
  p_pin text,
  p_nickname text default null,
  p_referral_code text default null,
  p_birthday date default null)
returns table(member_id uuid, session_token text)
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid; v_token text; v_referrer uuid; v_default_level uuid; v_phone text;
begin
  v_phone := public._norm_phone_my(p_phone);
  -- 0 开头、连 0 一共 9-11 位（手机 01x 是 10-11 位，座机如 06 是 9 位）
  if v_phone !~ '^0\d{8,10}$' then
    raise exception '手机号请用 0127010189 这样的写法（纯数字、0 开头）';
  end if;
  if p_pin is null or length(p_pin) < 4 then
    raise exception 'PIN 至少 4 位';
  end if;
  if p_birthday is not null and (p_birthday > current_date or p_birthday < date '1900-01-01') then
    raise exception '请填写正确的生日';
  end if;
  -- 老号码可能还存着 +60 的写法，用归一后的比，别让同一个人注册出第二个账号
  if exists (select 1 from public.members where public._norm_phone_my(phone) = v_phone) then
    raise exception '该手机号已注册，请直接登录';
  end if;
  -- 默认等级 = 0 成长值应处的等级（跟升级规则一致），不是 sort_order 最低那档——那档是「未注册」灰卡。
  -- 出处：supabase-member-default-level.sql
  select id into v_default_level from public.member_levels
    where xp_required <= 0 order by sort_order desc limit 1;
  if v_default_level is null then
    select id into v_default_level from public.member_levels order by sort_order asc limit 1;
  end if;
  if p_referral_code is not null and length(trim(p_referral_code)) > 0 then
    select id into v_referrer from public.members where referral_code = upper(trim(p_referral_code));
  end if;
  v_token := encode(gen_random_bytes(24), 'hex');
  insert into public.members (phone, pin_hash, session_token, nickname, birthday, level_id, referral_code, referred_by, last_active_at)
  values (v_phone, crypt(p_pin, gen_salt('bf')), v_token, coalesce(nullif(trim(p_nickname),''), '喵星人'), p_birthday,
          v_default_level, public._gen_referral_code(), v_referrer, now())
  returning id into v_id;
  -- 邀请关系必须留下（出处：supabase-referral-v2.sql）。奖励不在这里发，等好友完成首单才结算，
  -- 漏了这一条整条邀请链就断了，而且断得无声无息。
  if v_referrer is not null and v_referrer <> v_id and to_regclass('public.referrals') is not null then
    insert into public.referrals(referrer_id, referred_id) values (v_referrer, v_id);
  end if;
  return query select v_id, v_token;
end;
$$;

-- ---------- 4) 登录：按归一后的号码找人 ----------
--  两边都归一再比：这样第 2) 步没敢改的历史号码（存成 +60 的）照样登得进去。
create or replace function public.rpc_member_login(p_phone text, p_pin text)
returns table(member_id uuid, session_token text)
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid; v_hash text; v_token text; v_phone text;
begin
  v_phone := public._norm_phone_my(p_phone);
  select id, pin_hash into v_id, v_hash
    from public.members
   where public._norm_phone_my(phone) = v_phone
   limit 1;
  if v_id is null or crypt(p_pin, v_hash) <> v_hash then
    raise exception '手机号或 PIN 不正确';
  end if;
  v_token := encode(gen_random_bytes(24), 'hex');
  update public.members set session_token = v_token, last_active_at = now() where id = v_id;
  return query select v_id, v_token;
end;
$$;

-- ---------- 5) 柜台按手机号查会员：同样按归一后的号码比 ----------
create or replace function public.rpc_pos_find_member(p_phone text)
returns table(
  id uuid, phone text, nickname text, level_name text, level_color text,
  xp int, coins int, wallet_balance numeric, unused_coupons int)
language plpgsql
security definer
set search_path = public
as $$
begin
  return query
  select m.id, m.phone, m.nickname, l.name_cn, l.color_hex,
         m.xp, m.coins, m.wallet_balance,
         (select count(*)::int from public.member_coupons mc
           where mc.member_id = m.id and mc.status = 'unused'
             and (mc.expires_at is null or mc.expires_at > now()))
    from public.members m
    left join public.member_levels l on l.id = m.level_id
   where public._norm_phone_my(m.phone) = public._norm_phone_my(p_phone)
   limit 1;
end;
$$;

-- ---------- 6) POS 会员列表：补一列生日 ----------
--  返回的列变了，必须先 drop 再建（Postgres 不让 create or replace 改列结构）。
drop function if exists public.rpc_admin_list_members(text);
create or replace function public.rpc_admin_list_members(p_search text default null)
returns table(
  id uuid, phone text, nickname text, avatar_url text, level_id uuid,
  xp int, coins int, wallet_balance numeric,
  total_spent numeric, order_count int, last_order_at timestamptz,
  notes text, birthday date, created_at timestamptz, last_active_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
begin
  return query
  select m.id, m.phone, m.nickname, m.avatar_url, m.level_id,
         m.xp, m.coins, m.wallet_balance,
         coalesce(o.spent, 0)::numeric,
         coalesce(o.cnt, 0)::int,
         o.last_at,
         m.notes, m.birthday, m.created_at, m.last_active_at
    from public.members m
    left join lateral (
      select sum(x.total) as spent, count(*) as cnt, max(x.created_at) as last_at
        from public.orders x
       where x.member_id = m.id
         and coalesce(x.ta_mode, '') not in ('recharge', 'reservation')
         and coalesce(x.status, '') not in ('void', 'pending')
    ) o on true
   where p_search is null or p_search = ''
      or m.phone ilike '%' || p_search || '%'
      -- 搜的是号码时，两边都归一再比（店员输 0127010189 也能找到存成 +60 的老会员）。
      -- 必须挡掉「搜的是昵称」的情况：那时归一结果是空串，like '%%' 会把所有人捞回来。
      or (public._norm_phone_my(p_search) <> ''
          and public._norm_phone_my(m.phone) like '%' || public._norm_phone_my(p_search) || '%')
      or m.nickname ilike '%' || p_search || '%'
   order by m.created_at desc
   limit 200;
end;
$$;

grant execute on function public._norm_phone_my(text) to anon;
grant execute on function public.rpc_member_register(text, text, text, text, date) to anon;
grant execute on function public.rpc_member_login(text, text) to anon;
grant execute on function public.rpc_pos_find_member(text) to anon;
grant execute on function public.rpc_admin_list_members(text) to anon;

-- 完成。小程序注册页多一格「生日」，手机号只收 0127010189 这种写法；
-- POS「会员运营 → 会员列表」多一列「生日」，按手机号搜也不挑写法了。
