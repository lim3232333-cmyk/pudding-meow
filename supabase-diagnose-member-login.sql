-- ============================================================================
--  布丁喵 — 查某个会员为什么登不进去（改 ★ 那两行 → 整段 Run）
--
--  只读，不改任何数据。跑完出一张表，从上往下看就知道卡在哪。
--
--  ⚠ 第二行的 PIN **一定要填**，那是全场唯一能一刀切开的判断：
--      PIN 对得上哈希 → 数据库没问题，毛病在小程序那一侧（输入/缓存/版本）
--      PIN 对不上     → 重置根本没落到这个账号上（或者重置到别的会员去了）
--    可以一次填好几个，逗号隔开：重置成的那个、顾客自己以为的那个，都丢进去试。
--
--  能查出来的几种情况：
--    ① 同一个号码有**两个会员账号**。rpc_member_login 里是
--         where _norm_phone_my(phone) = ... limit 1
--       没有 order by，等于随便挑一个；而 POS 的「重置 PIN」是按你点的那一行的
--       member_id 改的。于是改了 A 的密码、登录却匹配到 B。
--       （修法见 supabase-fix-member-login.sql）
--    ② supabase-member-birthday-phone.sql 没跑过 → rpc_member_login 还是旧版的
--       `where phone = p_phone` 精确比对，存成 "+60 …" 的老会员永远对不上。
--    ③ 账号的 pin_hash 是空的 → 那个账号任何 PIN 都能登进去（安全洞，同上脚本修）。
--    ④ 号码根本没有账号，或者顾客记错了号码。
-- ============================================================================

-- ╔══════════════════════════════════════════════════════════════════════════╗
-- ║  ★ 只改这两行 ★                                                          ║
-- ╚══════════════════════════════════════════════════════════════════════════╝
drop table if exists _chk;
create temp table _chk as
select '0122637221'::text  as phone,    -- ★ 顾客的手机号（怎么写都行）
       ''::text            as pins;     -- ★ 要试的 PIN，逗号隔开，例：'999999,1234'

-- 下面不用动。归一规则直接写在查询里，不依赖 _norm_phone_my 是否已经建好——
-- 「函数在不在」本身就是要查的东西之一，用它去查它会直接报错。
with
p   as (select * from _chk),
tn  as (select case
          when regexp_replace(phone,'\D','','g') = '' then ''
          when left(regexp_replace(phone,'\D','','g'),1) <> '0'
           and left(regexp_replace(phone,'\D','','g'),2) = '60'
            then '0' || substr(regexp_replace(phone,'\D','','g'), 3)
          when left(regexp_replace(phone,'\D','','g'),1) = '1'
            then '0' || regexp_replace(phone,'\D','','g')
          else regexp_replace(phone,'\D','','g') end as norm
        from p),
mn  as (select m.id, m.phone, m.nickname, m.pin_hash, m.created_at, m.last_active_at,
               case
          when regexp_replace(coalesce(m.phone,''),'\D','','g') = '' then ''
          when left(regexp_replace(coalesce(m.phone,''),'\D','','g'),1) <> '0'
           and left(regexp_replace(coalesce(m.phone,''),'\D','','g'),2) = '60'
            then '0' || substr(regexp_replace(coalesce(m.phone,''),'\D','','g'), 3)
          when left(regexp_replace(coalesce(m.phone,''),'\D','','g'),1) = '1'
            then '0' || regexp_replace(coalesce(m.phone,''),'\D','','g')
          else regexp_replace(coalesce(m.phone,''),'\D','','g') end as norm
          from public.members m),
hit as (select mn.* from mn, tn where mn.norm = tn.norm)

select 1 as 序, '你查的号码' as 项目,
       (select phone from p) || ' → 归一后 ' || (select norm from tn) as 结果,
       '归一规则：去掉非数字，60 开头换成 0，1 开头补 0' as 说明
union all
select 2, '归一函数 _norm_phone_my',
       case when exists(select 1 from pg_proc where proname='_norm_phone_my')
            then '✅ 已建好' else '❌ 不存在' end,
       '不存在 = supabase-member-birthday-phone.sql 没跑过'
union all
select 3, 'rpc_member_login 版本',
       case when exists(select 1 from pg_proc
                         where proname='rpc_member_login' and prosrc like '%crypt(p_pin, m.pin_hash)%')
            then '✅ 最新：按 PIN 认人（重号也不怕）'
            when exists(select 1 from pg_proc
                         where proname='rpc_member_login' and prosrc like '%_norm_phone_my%')
            then '⚠ 中间版：按归一号码找人，但重号时 limit 1 随便挑'
            else '❌ 旧版：phone 精确比对' end,
       '不是「最新」的话，跑一次 supabase-fix-member-login.sql'
union all
select 4, '这个号码匹配到几个会员账号',
       (select count(*)::text from hit),
       case when (select count(*) from hit) = 0 then '❌ 一个都没有——号码对吗？'
            when (select count(*) from hit) = 1 then '✅ 正常'
            else '❌ 登录时 limit 1 随便挑一个，你重置的多半是另一个' end
union all
select 4 + row_number() over (order by h.created_at),
       '账号 ' || row_number() over (order by h.created_at)
         || '：' || coalesce(h.nickname,'(无昵称)'),
       '存的号码「' || coalesce(h.phone,'(空)') || '」'
         || '　PIN：' || case when h.pin_hash is null
                               then '❌ 没设过（这个账号任何 PIN 都能登进去）'
                             when h.pin_hash like '$2%' then '已设(bcrypt)'
                             else '⚠ 格式不认识：' || left(coalesce(h.pin_hash,''),4) end
         -- 最后登录时间：跟注册时间几乎一样 = 注册完就再没成功登录过
         || '　最后登录：' || coalesce(to_char(h.last_active_at,'MM-DD HH24:MI'), '从来没有')
         || case when coalesce(btrim((select pins from p)),'') = '' then '　→ ⚠ 你没填 PIN，没法判断'
                 when h.pin_hash is null then ''
                 when mt.ok is not null then '　→ ✅ 对得上的 PIN：' || mt.ok
                 else '　→ ❌ 你给的 PIN 一个都对不上这个账号' end,
       'id=' || h.id::text || '　注册于 ' || to_char(h.created_at,'YYYY-MM-DD HH24:MI')
  from hit h
  -- 逐个试你给的 PIN，列出哪些对得上（对得上多个也照实说）
  left join lateral (
    select string_agg(btrim(t.pin), '、') as ok
      from unnest(string_to_array((select pins from p), ',')) as t(pin)
     where h.pin_hash is not null
       and btrim(t.pin) <> ''
       and h.pin_hash = crypt(btrim(t.pin), h.pin_hash)
  ) mt on true
order by 序;
