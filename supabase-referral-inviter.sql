-- ============================================================================
--  布丁喵 — 按邀请码查邀请人昵称（好友点分享链接进来时，弹欢迎卡要用）
--  用法：Supabase Dashboard → SQL Editor → New query → 粘贴 → Run（跑一次）
--
--  好友这时还没登录，members 表不给 anon 直接读，所以走这个 security definer RPC，
--  只回一个昵称（不泄露电话/余额等隐私）。码不存在就回 null。
-- ============================================================================

create or replace function public.rpc_referral_inviter(p_code text)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare v_nick text;
begin
  if p_code is null or length(trim(p_code)) = 0 then return null; end if;
  select nickname into v_nick from public.members where referral_code = upper(trim(p_code));
  return v_nick;   -- 找不到就是 null
end;
$$;

grant execute on function public.rpc_referral_inviter(text) to anon;

-- 完成。好友打开 ?ref=CODE 时，前端用这个 RPC 拿到邀请人昵称，弹「XX 邀请你加入布丁喵会员」卡。
