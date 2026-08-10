-- ============================================================================
--  布丁喵 — 会员忘记 PIN：POS 店员帮重置登录密码
--  用法：Supabase Dashboard → SQL Editor → New query → 粘贴 → Run（跑一次）
--
--  背景：会员登录是「手机号 + PIN」，PIN 用 bcrypt 哈希存（members.pin_hash），
--        谁都看不到原始密码，本来也没有「忘记密码」的补救。会员忘了就登不进去。
--  解法：加一个后台 RPC，让 POS「会员管理 → 某会员 → 重置 PIN」把密码改成店员
--        当场输入的新 4–6 位数字（顾客可以自己报想要的 PIN，店员代填）。
--
--  安全尺度跟现有 rpc_admin_* 一致：POS 还没有真正的店员账号体系（只有本机 PIN 门禁），
--  这个 RPC 对 anon 开放；它只改 pin_hash、顺手轮换 session_token（把旧登录态失效，
--  重置后必须用新 PIN 重新登录），不返回也不泄露任何哈希/令牌。
-- ============================================================================

create extension if not exists pgcrypto;

create or replace function public.rpc_admin_reset_member_pin(p_member_id uuid, p_new_pin text)
returns void language plpgsql security definer as $$
begin
  if p_new_pin is null or p_new_pin !~ '^[0-9]{4,6}$' then
    raise exception 'PIN 必须是 4–6 位数字';
  end if;
  update public.members
     set pin_hash = crypt(p_new_pin, gen_salt('bf')),
         session_token = encode(gen_random_bytes(24), 'hex')   -- 轮换令牌：旧设备上的登录态作废
   where id = p_member_id;
  if not found then
    raise exception '找不到该会员';
  end if;
end; $$;

grant execute on function public.rpc_admin_reset_member_pin(uuid, text) to anon;

-- 完成。回 POS「会员运营 → 会员管理」，点开某个会员，右上角就有「重置 PIN」。
