-- ============================================================================
--  布丁喵 — 查某个会员为什么登不进去（改 ★ 那两行 → 整段 Run）
--
--  只读，不改任何数据。跑完出一张表，从上往下看就知道卡在哪。
--
--  两个最可能的原因：
--    ① 同一个号码有**两个会员账号**。rpc_member_login 里是
--         where _norm_phone_my(phone) = ... limit 1
--       没有 order by，等于随便挑一个；而 POS 的「重置 PIN」是按你点的那一行的
--       member_id 改的。于是你改了 A 的密码、登录却匹配到 B —— 重置多少次都没用。
--       （这种重号是 supabase-member-birthday-phone.sql 那次迁移**故意跳过**的：
--         XP/钱包/券都挂在各自的 id 上，机器不敢替你合并。）
--    ② supabase-member-birthday-phone.sql 没跑过。那样 rpc_member_login 还是旧版的
--       `where phone = p_phone` 精确比对，而小程序现在会把输入归一成 0xxxxxxxxx。
--       老会员要是存成 "+60 12-263 7221"，就永远对不上，跟 PIN 无关。
-- ============================================================================

-- ╔══════════════════════════════════════════════════════════════════════════╗
-- ║  ★ 只改这两行 ★                                                          ║
-- ╚══════════════════════════════════════════════════════════════════════════╝
drop table if exists _chk;
create temp table _chk as
select '0122637221'::text as phone,     -- ★ 顾客的手机号（怎么写都行）
       ''::text           as new_pin;   -- ★ 你刚才帮他重置成的那个 PIN；不确定就留空

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
mn  as (select m.id, m.phone, m.nickname, m.pin_hash, m.created_at,
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
                         where proname='rpc_member_login' and prosrc like '%_norm_phone_my%')
            then '✅ 新版：按归一后的号码找人'
            else '❌ 旧版：phone 精确比对' end,
       '旧版的话，存成 +60 / 带空格横杠的老会员一律登不进，跟 PIN 无关'
union all
select 4, '这个号码匹配到几个会员账号',
       (select count(*)::text from hit),
       case when (select count(*) from hit) = 0 then '❌ 一个都没有——号码对吗？'
            when (select count(*) from hit) = 1 then '✅ 正常'
            else '❌ 就是这个问题：登录时 limit 1 随便挑一个，你重置的多半是另一个' end
union all
select 4 + row_number() over (order by h.created_at),
       '账号 ' || row_number() over (order by h.created_at)
         || '：' || coalesce(h.nickname,'(无昵称)'),
       '库里存的号码「' || coalesce(h.phone,'(空)') || '」'
         || '　PIN：' || case when h.pin_hash is null then '❌ 没设过（这种账号任何 PIN 都能登进去，另见下）'
                             when h.pin_hash like '$2%' then '已设（bcrypt）'
                             else '⚠ 格式不认识' end
         || case when (select new_pin from p) = '' then ''
                 when h.pin_hash is null then ''
                 when h.pin_hash = crypt((select new_pin from p), h.pin_hash)
                      then '　→ ✅ 你填的新 PIN 对得上这个账号'
                 else '　→ ❌ 你填的新 PIN 对不上这个账号' end,
       'id=' || h.id::text || '　注册于 ' || to_char(h.created_at,'YYYY-MM-DD HH24:MI')
  from hit h
order by 序;
