// 固定 documentStart 模板。Swift 仅替换 JSON 配置标记，不拼接网页提供的脚本。
(function (w, config) {
  'use strict';
  if (w !== w.top || w.location.origin !== config.origin
    || config.paths.indexOf(w.location.pathname) < 0) return;
  var nav = new URL(w.location.href).searchParams.getAll('_shellNav');
  if (nav.length !== 1 || nav[0] !== config.navId) return;
  var snapshot = Object.create(null);
  Object.keys(config.storeSnapshot).forEach(function (key) { snapshot[key] = config.storeSnapshot[key]; });
  Object.freeze(snapshot);
  var bootstrap = Object.freeze({ flavor: 'ios', version: 1, nonce: config.nonce,
    navId: config.navId, generation: config.generation, epoch: config.epoch,
    capabilities: Object.freeze(config.capabilities.slice()), storeSnapshot: snapshot,
    storeRevision: config.storeRevision, storeReadError: config.storeReadError });
  Object.defineProperty(w, '__zeehoIOS', { value: bootstrap, configurable: false, writable: false });
  // 原生生命周期只取消网页观察者。后台明确开启的骑行记录由服务自己的系统权限守护。
  Object.defineProperty(w, '__zeehoIOSLifecycle', { configurable: false, writable: false,
    value: function (event) {
      if (!event || event.navId !== config.navId) return;
      if (event.kind === 'navigation' || event.kind === 'closed') {
        if (w.IOSBR && typeof w.IOSBR.expire === 'function') w.IOSBR.expire();
      }
      if (w.dispatchEvent && typeof w.CustomEvent === 'function') {
        w.dispatchEvent(new w.CustomEvent('zeehoios:lifecycle', { detail: Object.freeze({
          kind: event.kind, navId: config.navId, generation: event.generation, epoch: event.epoch
        }) }));
      }
    } });
})(window, __ZEEHO_IOS_CONFIG__);
