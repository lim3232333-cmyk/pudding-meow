-- ============================================================================
--  布丁喵 — 修「function crypt(text, text) does not exist」：会员一个都登不进去
--  用法：Supabase SQL Editor → 整段粘贴 → Run。可重复跑。
--
--  ── 症状 ──────────────────────────────────────────────────────────────────
--  会员输对 PIN 也登不进去；店员在 POS 帮他重置 PIN，显示「✓ 已重置」，还是登不进。
--  查会员表：账号只有一个、手机号格式干净、pin_hash 也在，而 last_active_at
--  一直停在注册那一刻——也就是注册完从来没有成功登录过一次。
--
--  ── 根因 ──────────────────────────────────────────────────────────────────
--  Supabase 把 pgcrypto 装在 **extensions** schema，不是 public。而
--  supabase-member-birthday-phone.sql 里的 rpc_member_login / rpc_member_register
--  定义时写了：
--        security definer
--        set search_path = public          ← 锁死在 public
--  函数体里的 crypt() / gen_salt() / gen_random_bytes() 全是 pgcrypto 的，
--  于是在函数里根本找不到 → 每次登录都抛 function crypt(text, text) does not exist，
--  跟顾客的 PIN 对不对完全无关。
--
--  为什么注册当时是好的：那会儿装的还是**没锁 search_path** 的旧版 register，
--  它跟着调用者的 search_path 走（Supabase 默认带 extensions），所以找得到 crypt。
--  为什么 POS 重置 PIN 显示成功：rpc_admin_reset_member_pin 也没锁 search_path，
--  它是真的把新密码写进去了——写得好好的，只是登录那一侧读不了。
--
--  ── 修法 ──────────────────────────────────────────────────────────────────
--  只改函数的 search_path 配置，**不碰函数体**。
--  刻意不用「重新 create or replace 一遍」：rpc_member_register 的函数体被三个
--  SQL 文件改过，其中两个互相丢过对方的活（referrals 那笔插入、默认等级），
--  在这里重写一遍太容易再丢一次。alter function ... set search_path 只动配置。
-- ============================================================================

do $$
declare
  r      record;
  v_ext  text;
  v_n    int := 0;
begin
  -- pgcrypto 到底装在哪个 schema，问库本身，不猜
  select n.nspname into v_ext
    from pg_extension e join pg_namespace n on n.oid = e.extnamespace
   where e.extname = 'pgcrypto';

  if v_ext is null then
    raise exception 'pgcrypto 扩展没装。先跑：create extension if not exists pgcrypto;';
  end if;

  -- 找出所有「用了 pgcrypto 的函数、又把 search_path 锁在不含它的地方」的函数
  for r in
    select p.oid::regprocedure::text as sig
      from pg_proc p
      join pg_namespace ns on ns.oid = p.pronamespace
     where ns.nspname = 'public'
       and p.prosrc ~ '(crypt|gen_salt|gen_random_bytes|digest|hmac)\s*\('
       and p.proconfig is not null
       and exists (select 1 from unnest(p.proconfig) c
                    where c like 'search_path=%'
                      and c not like '%' || v_ext || '%')
  loop
    execute format('alter function %s set search_path = public, %I', r.sig, v_ext);
    v_n := v_n + 1;
  end loop;

  raise notice 'pgcrypto 在 % schema；修好了 % 个函数', v_ext, v_n;
end $$;

-- ── 冒烟测试：真的调一次登录，看还会不会报 crypt 找不到 ────────────────────
--    故意用一个不存在的号码，所以**不会**动到任何真实会员的数据。
--    期望看到「手机号或 PIN 不正确」——那说明它已经走到密码比对那一步了，
--    也就是 crypt 能用了。
drop table if exists _smoke;
create temp table _smoke(项目 text, 结果 text, 说明 text);

do $$
declare msg text;
begin
  begin
    perform public.rpc_member_login('0000000000', 'nosuchpin');
    msg := '(没报错，意外)';
  exception when others then
    msg := SQLERRM;
  end;
  insert into _smoke values (
    '登录冒烟测试',
    case when msg like '%does not exist%' then '❌ 还是找不到 crypt'
         else '✅ crypt 可用了' end,
    '服务端回的是「' || msg || '」'
  );
end $$;

-- ── 报告放最后：Supabase 的 SQL Editor 只显示最后一条语句的结果 ─────────────
select * from _smoke
union all
select '现在的 search_path',
       p.oid::regprocedure::text,
       array_to_string(p.proconfig, ' ')
  from pg_proc p
  join pg_namespace ns on ns.oid = p.pronamespace
 where ns.nspname = 'public'
   and p.prosrc ~ '(crypt|gen_salt|gen_random_bytes)\s*\('
   and p.proconfig is not null
 order by 1 desc, 2;
