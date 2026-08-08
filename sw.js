/* 布丁喵 · 订单提醒 Service Worker
   收到 Web Push（来自 hitpay-webhook Edge Function）就弹系统通知；点通知回到提醒页。
   只负责通知，不缓存页面（不做离线，避免旧版卡住）。 */

self.addEventListener('install', function(){ self.skipWaiting(); });
self.addEventListener('activate', function(e){ e.waitUntil(self.clients.claim()); });

self.addEventListener('push', function(e){
  var data = {};
  try { data = e.data ? e.data.json() : {}; }
  catch (_) { data = { title: '布丁喵 · 新订单', body: (e.data && e.data.text && e.data.text()) || '' }; }
  var title = data.title || '布丁喵 · 新订单';
  var opts = {
    body: data.body || '有新的自取/外卖订单',
    icon: data.icon || './icon-192.png',
    badge: data.badge || './icon-192.png',
    tag: data.tag || ('order-' + Date.now()),
    renotify: true,
    requireInteraction: true,          // 通知不自动消失，店员回来才看得到
    vibrate: [200, 100, 200, 100, 200],
    data: { url: data.url || './notify.html' }
  };
  e.waitUntil(self.registration.showNotification(title, opts));
});

self.addEventListener('notificationclick', function(e){
  e.notification.close();
  var url = (e.notification.data && e.notification.data.url) || './notify.html';
  e.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(function(list){
      for (var i = 0; i < list.length; i++) {
        if (list[i].url.indexOf('notify') >= 0 && 'focus' in list[i]) return list[i].focus();
      }
      if (self.clients.openWindow) return self.clients.openWindow(url);
    })
  );
});
