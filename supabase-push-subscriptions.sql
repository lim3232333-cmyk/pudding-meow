-- ============================================================================
--  布丁喵 — 手机推送订阅表（PWA Web Push）
--  用法：Supabase Dashboard → SQL Editor → New query → 粘贴 → Run（跑一次）
--
--  notify.html「开启通知」时，把浏览器给的推送订阅（endpoint + 两个密钥）存到这里；
--  hitpay-webhook 里自取/外卖付款到账时，用 service_role 读出所有订阅、逐个发 Web Push。
--  endpoint 唯一，同一台手机重复开启只更新不重复插。
-- ============================================================================

create table if not exists public.push_subscriptions (
  id         uuid primary key default gen_random_uuid(),
  endpoint   text unique not null,          -- 浏览器推送服务的地址（每台设备一个）
  p256dh     text not null,                 -- 订阅公钥（加密推送内容用）
  auth       text not null,                 -- 订阅认证密钥
  phone      text,                          -- 开启通知时填的手机号（用来做「只推给这两个号」白名单）
  ua         text,                          -- 记一下是哪台设备（可选，方便管理）
  created_at timestamptz not null default now()
);
-- 老表补列（已建过表再跑也不会报错）
alter table public.push_subscriptions add column if not exists phone text;

alter table public.push_subscriptions enable row level security;

-- 前端（anon）：能自己订阅 / 更新 / 退订；但不能读别人的订阅（读取只留给 service_role）。
drop policy if exists push_sub_anon_insert on public.push_subscriptions;
create policy push_sub_anon_insert on public.push_subscriptions for insert to anon with check (true);
drop policy if exists push_sub_anon_update on public.push_subscriptions;
create policy push_sub_anon_update on public.push_subscriptions for update to anon using (true) with check (true);
drop policy if exists push_sub_anon_delete on public.push_subscriptions;
create policy push_sub_anon_delete on public.push_subscriptions for delete to anon using (true);
-- 注意：没有给 anon 的 select 策略——发推送在 Edge Function 里用 service_role（绕过 RLS）读。

-- 完成。接着部署 hitpay-webhook（已加发推送逻辑），并在 Edge Functions → Secrets 里设
--   VAPID_PUBLIC_KEY / VAPID_PRIVATE_KEY / VAPID_SUBJECT。
-- 只想给指定手机号收通知：再设一个 PUSH_ALLOW_PHONES，填允许的号码（逗号分隔），例如
--   PUSH_ALLOW_PHONES = 0123456789,0129876543
-- 设了之后就只推给这些号；留空/不设 = 推给所有开了提醒的设备。号码 0/+60/60 前缀都行，自动归一化比对。
