-- ============================================================================
--  布丁喵 — 修 rpc_member_login：重号时按 PIN 认人，顺手堵上一个安全洞
--  用法：Supabase SQL Editor → 整段粘贴 → Run。可重复跑。
--
--  ── 修的第一件事：同一个号码有两个账号时，登录随便挑一个 ──────────────────
--  原来是：
--        select id, pin_hash into v_id, v_hash
--          from public.members
--         where _norm_phone_my(phone) = v_phone
--         limit 1;                      ← 没有 order by
--  没有 order by 的 limit 1，Postgres 返回哪一行是不保证的（还会随着表被更新、
--  vacuum 而变）。而 POS 的「重置 PIN」是按你在会员列表点的那一行的 member_id 改的。
--  于是：你改了 A 的密码 → 顾客登录却匹配到 B → 提示「手机号或 PIN 不正确」，
--  重置几次都一样。顾客和店员都会以为是密码记错了。
--
--  改成：在这个号码下的所有账号里，找**PIN 对得上**的那一个。
--  顾客输哪个账号的 PIN，就进哪个账号。号码不重复时行为完全不变。
--
--  ── 修的第二件事：pin_hash 是 NULL 的账号，任何 PIN 都能登进去 ─────────────
--  原来的判断是  if v_id is null or crypt(p_pin, v_hash) <> v_hash then raise ...
--  v_hash 为 NULL 时，crypt(...) 是 NULL，NULL <> NULL 也是 NULL，
--  整个 if 条件既不是 true 也就不会 raise —— 直接往下走，发令牌，登录成功。
--  正常注册流程都会写 pin_hash，但只要有一行是手工/导入进来的没设密码，
--  那个账号就等于不设防。加一句 pin_hash is not null 就堵上了。
--
--  ── 不做的事 ──────────────────────────────────────────────────────────────
--  不替你合并重号的账号。XP、Coin、钱包余额、优惠券全都挂在各自的 id 上，
--  合并等于替你决定哪些资产作废，机器不该自作主张。这份脚本只保证
--  「顾客能用自己的 PIN 进到自己那个账号」。要不要合并、怎么合，你自己定。
-- ============================================================================

-- 号码归一：跟小程序的 _normPhoneMY() 同一套规则。
-- 这里一并建好，是为了这份脚本在没跑过 supabase-member-birthday-phone.sql 的库上
-- 也能独立生效（那种库的 rpc_member_login 还是「phone 精确比对」的老版本，
-- 存成 +60 开头的老会员一样登不进——跑完这段就一起好了）。
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

create or replace function public.rpc_member_login(p_phone text, p_pin text)
returns table(member_id uuid, session_token text)
language plpgsql
security definer
set search_path = public, extensions
as $$
declare v_id uuid; v_token text; v_phone text;
begin
  v_phone := public._norm_phone_my(p_phone);

  -- 在这个号码下的所有账号里，挑 PIN 对得上的那一个。
  -- 万一有两个账号连 PIN 都一样（顾客自己设成同一个），取最近活跃的那个——
  -- 那多半就是他现在在用的账号。
  select m.id into v_id
    from public.members m
   where public._norm_phone_my(m.phone) = v_phone
     and m.pin_hash is not null                      -- 没设过密码的账号不给登
     and m.pin_hash = crypt(p_pin, m.pin_hash)
   order by m.last_active_at desc nulls last, m.created_at desc
   limit 1;

  if v_id is null then
    raise exception '手机号或 PIN 不正确';
  end if;

  v_token := encode(gen_random_bytes(24), 'hex');
  update public.members set session_token = v_token, last_active_at = now() where id = v_id;
  return query select v_id, v_token;
end;
$$;

grant execute on function public.rpc_member_login(text, text) to anon;

-- ── 跑完看一眼：还有哪些号码是重号的（这些账号的资产要不要合并，你自己决定）──
select public._norm_phone_my(phone)                as 归一后的号码,
       count(*)                                   as 账号数,
       string_agg(coalesce(nickname,'(无昵称)') || ' / 存的是「' || coalesce(phone,'') || '」',
                  '　｜　' order by created_at)    as 都有谁,
       count(*) filter (where pin_hash is null)    as 没设密码的
  from public.members
 group by 1
having count(*) > 1
 order by 2 desc, 1;
