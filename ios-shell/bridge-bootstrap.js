// 固定 documentStart 模板。Swift 仅替换 JSON 配置标记，不拼接网页提供的脚本。
(function (w, config) {
  'use strict';

  // 诊断面板：网页在真机白屏时，光看 Xcode/Console 拿不到线索（TrollStore 装的包
  // 也没法连调试器）。这里在 documentStart 就挂好错误捕获，一旦脚本抛错或资源
  // 加载失败，直接把原因画在页面上——比白屏让用户猜好得多。
  // 正常运行时这个面板永远不显示，也不影响任何业务逻辑。
  function showFatal(title, detail) {
    try {
      var paint = function () {
        if (!w.document || !w.document.body) return;
        var id = '__zeeho_ios_fatal';
        if (w.document.getElementById(id)) return;
        var box = w.document.createElement('div');
        box.id = id;
        box.setAttribute('style', [
          'position:fixed', 'inset:0', 'z-index:2147483647',
          'background:#111', 'color:#eee', 'font:13px/1.5 -apple-system,sans-serif',
          'padding:24px', 'overflow:auto', 'white-space:pre-wrap',
          'word-break:break-word', '-webkit-user-select:text', 'user-select:text'
        ].join(';'));
        var head = w.document.createElement('div');
        head.setAttribute('style', 'font-size:16px;font-weight:600;margin-bottom:12px;color:#ff8a80');
        head.textContent = 'iOS 壳：' + title;
        var body = w.document.createElement('div');
        body.textContent = detail;
        box.appendChild(head);
        box.appendChild(body);
        w.document.body.appendChild(box);
      };
      if (w.document && w.document.body) paint();
      else if (w.document) w.document.addEventListener('DOMContentLoaded', paint, { once: true });
    } catch (e) { /* 诊断本身失败就放弃，绝不能因此再抛错 */ }
  }

  // 只报第一处错误，避免错误风暴把屏幕刷满。
  var reported = false;
  w.addEventListener('error', function (event) {
    if (reported) return;
    // 资源加载失败（img/script/link）没有 message，只有 target。
    var target = event && event.target;
    if (target && target !== w && target.tagName) {
      reported = true;
      showFatal('资源加载失败', String(target.tagName) + '\n' + String(target.src || target.href || ''));
      return;
    }
    reported = true;
    var where = event && event.filename
      ? '\n\n' + event.filename + ':' + event.lineno + ':' + event.colno : '';
    showFatal('脚本错误', String((event && event.message) || event) + where);
  }, true);
  w.addEventListener('unhandledrejection', function (event) {
    if (reported) return;
    reported = true;
    var reason = event && event.reason;
    showFatal('未处理的 Promise 拒绝',
      String((reason && (reason.stack || reason.message)) || reason));
  });

  // 网页 8 秒内没把首屏画出来就当失败：正常单文件产物 1~2 秒就该有内容。
  var painted = false;
  w.addEventListener('zeehoios:painted', function () { painted = true; });
  w.setTimeout(function () {
    if (painted) return;
    if (!w.document || !w.document.body) return;
    // 已经有可见内容就不打扰（例如只有 bootskel 也算活着）。
    if (w.document.body.children.length > 0 && w.document.getElementById('__zeeho_ios_fatal')) return;
    if (w.document.body.children.length > 0) return;
    showFatal('页面 8 秒内没有任何内容',
      '文档已加载但 body 为空。\n\nlocation=' + w.location.href +
      '\norigin=' + w.location.origin +
      '\nUA=' + w.navigator.userAgent);
  }, 8000);

  if (w !== w.top || w.location.origin !== config.origin
    || config.paths.indexOf(w.location.pathname) < 0) {
    // 这里 return 会让整页没有原生桥，是最常见的白屏原因，必须报出来。
    showFatal('原生桥未注入',
      'location.origin=' + w.location.origin +
      '\n期望 origin=' + config.origin +
      '\nlocation.pathname=' + w.location.pathname +
      '\n期望 paths=' + config.paths.join(', '));
    return;
  }
  var nav = new URL(w.location.href).searchParams.getAll('_shellNav');
  if (nav.length !== 1 || nav[0] !== config.navId) {
    showFatal('导航代号不匹配',
      '_shellNav=' + nav.join(',') + '\n期望 navId=' + config.navId +
      '\nlocation=' + w.location.href);
    return;
  }
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
