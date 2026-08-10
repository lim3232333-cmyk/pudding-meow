-- ============================================================================
--  布丁喵 — 会员等级：注册默认等级修正 + 已注册会员按成长值重算
--  用法：Supabase Dashboard → SQL Editor → New query → 粘贴 → Run（跑一次）
--
--  问题：后台把「游客」也建成一行（Lv.0）后，注册时把默认等级设成 sort_order 最低那档，
--        也就是「游客」——于是注册会员的 level_id 其实挂在游客上，会员卡就显示等级名「游客」，
--        跟青铜的配色/序号对不上。
--  解法：
--    1) rpc_member_register 的默认等级改成「0 成长值应处的等级」——跟升级规则完全一致
--       （xp_required <= 0 里 sort_order 最高的那档）。青铜门槛设 0 时，新注册就直接是青铜。
--    2) 把已经注册、但还挂在低档的会员，按各自 xp 重算一次等级（把卡在「游客」的顶上来）。
-- ============================================================================

create or replace function public.rpc_member_register(p_phone text, p_pin text, p_nickname text default null, p_referral_code text default null)
returns table(member_id uuid, session_token text) language plpgsql security definer as $$
declare v_id uuid; v_token text; v_referrer uuid; v_default_level uuid;
begin
  if p_phone is null or length(trim(p_phone)) < 6 then
    raise exception '请填写有效的手机号';
  end if;
  if p_pin is null or length(p_pin) < 4 then
    raise exception 'PIN 至少 4 位';
  end if;
  if exists (select 1 from public.members where phone = p_phone) then
    raise exception '该手机号已注册，请直接登录';
  end if;
  -- 默认等级 = 0 成长值应处的等级（跟升级规则一致），不是 sort_order 最低那档（游客）
  select id into v_default_level from public.member_levels
    where xp_required <= 0 order by sort_order desc limit 1;
  if v_default_level is null then
    select id into v_default_level from public.member_levels order by sort_order asc limit 1;
  end if;
  if p_referral_code is not null and length(trim(p_referral_code)) > 0 then
    select id into v_referrer from public.members where referral_code = upper(p_referral_code);
  end if;
  v_token := encode(gen_random_bytes(24), 'hex');
  insert into public.members (phone, pin_hash, session_token, nickname, level_id, referral_code, referred_by, last_active_at)
  values (p_phone, crypt(p_pin, gen_salt('bf')), v_token, coalesce(nullif(trim(p_nickname),''), '喵星人'), v_default_level, public._gen_referral_code(), v_referrer, now())
  returning id into v_id;
  return query select v_id, v_token;
end; $$;

grant execute on function public.rpc_member_register(text, text, text, text) to anon;

-- 已注册会员：按各自 xp 重算等级（xp_required <= 自己的 xp 里 sort_order 最高的那档）。
-- 青铜门槛=0 时，卡在「游客」的会员会被顶到青铜。
update public.members m set level_id = (
  select id from public.member_levels l
   where l.xp_required <= coalesce(m.xp, 0)
   order by l.sort_order desc limit 1
)
where exists (select 1 from public.member_levels)
  and level_id is distinct from (
    select id from public.member_levels l
     where l.xp_required <= coalesce(m.xp, 0)
     order by l.sort_order desc limit 1
  );

-- 完成。之后新注册直接落在青铜（若青铜 xp_required=0），旧会员也已重算到正确等级。
