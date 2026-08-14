-- ============================================================================
--  布丁喵 — 会员等级：排序 0（未注册档）不再分配给已注册会员
--  用法：Supabase Dashboard → SQL Editor → New query → 粘贴 → Run（跑一次）
--
--  问题：后台「等级管理」里排序 0 那行是「未注册」档（如「路过喵」），只给小程序的
--        灰卡用。但升级逻辑一律按「xp_required <= 自己的 xp 里 sort_order 最高的那档」
--        算，它不知道排序 0 有特殊含义——新会员 0 成长值、第一个真实等级门槛又大于 0 时，
--        就正好落回排序 0，于是 POS 上一个已注册会员显示成「路过喵」。
--
--  为什么用触发器而不是逐个改 RPC：现在有 7 处在写 level_id（_grant_xp、抽奖、
--  邀请返奖、钱包规则、每周任务…），全是同一段复制出来的 SQL。逐个改要动 7 个文件，
--  漏一个 bug 就回来了，以后新加的还会再犯。触发器是一个收口，现有的和以后的写入
--  都会经过它。
--
--  后台没有排序 0 那行时（比如把它删了），这套逻辑自动失效——没有等级会被跳过，
--  触发器不会改任何东西，回填也是空操作。
-- ============================================================================

-- 「这个成长值应该在哪一档」——排除排序 0。
-- 成长值还够不到第一个真实等级的门槛时，兜底给最低的那个真实等级，
-- 而不是返回 null（那会把会员的等级抹掉）。
create or replace function public._member_level_for_xp(p_xp int)
returns uuid language sql stable as $$
  select coalesce(
    (select l.id from public.member_levels l
      where l.sort_order <> 0 and l.xp_required <= coalesce(p_xp, 0)
      order by l.sort_order desc limit 1),
    (select l.id from public.member_levels l
      where l.sort_order <> 0
      order by l.sort_order asc limit 1)
  );
$$;

-- 闸门：任何写入只要把 level_id 指到排序 0 那档，就按会员当前成长值改到正确的真实等级。
create or replace function public._member_level_guard()
returns trigger language plpgsql as $$
declare v_fix uuid;
begin
  if new.level_id is not null
     and exists (select 1 from public.member_levels where id = new.level_id and sort_order = 0) then
    v_fix := public._member_level_for_xp(new.xp);
    if v_fix is not null then new.level_id := v_fix; end if;   -- 没有真实等级时保持原样，不敢乱清
  end if;
  return new;
end; $$;

drop trigger if exists trg_member_level_guard on public.members;
create trigger trg_member_level_guard
  before insert or update of level_id on public.members
  for each row execute function public._member_level_guard();

-- 回填：已经挂在排序 0 上的会员，按各自成长值重算到正确的真实等级。
-- 成长值高的不会被压回第一级——_member_level_for_xp 是按 xp 选的。
update public.members m
   set level_id = public._member_level_for_xp(m.xp)
 where m.level_id in (select id from public.member_levels where sort_order = 0)
   and public._member_level_for_xp(m.xp) is not null;

-- 完成。之后不管哪条路径写 level_id，都不会再把已注册会员放到「未注册」档上。
