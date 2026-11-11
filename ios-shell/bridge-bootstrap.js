// 固定 documentStart 模板。Swift 仅替换 JSON 配置标记，不拼接网页提供的脚本。
(function (w, config) {
  'use strict';

  // 幂等：这个脚本会被执行两次——一次是 WKUserScript 的 atDocumentStart，
  // 一次是 didCommit 时的 evaluateJavaScript 补注入（前者在自定义 scheme 下
  // 可能不生效或延迟）。__zeehoIOS 是 configurable:false 的，重复定义会抛
  // "Attempting to change value of a readonly property" 把整页炸掉。
  if (w.__zeehoIOS) return;

  // 诊断面板：网页在真机白屏时，光看 Xcode/Console 拿不到线索（TrollStore 装的包
  // 也没法连调试器）。这里在 documentStart 就挂好错误捕获，一旦脚本抛错或资源
  // 加载失败，直接把原因画在页面上——比白屏让用户猜好得多。
  // 正常运行时这个面板永远不显示，也不影响任何业务逻辑。
  function showFatal(title, detail) {
    var full = title + '\n' + detail;
    // 同时通过桥写进原生日志文件：用户能导出这份文件，比截图信息量大得多。
    // 桥可能还没就绪（这本身就是一种失败原因），所以放在 try 里。
    try {
      var handler = w.webkit && w.webkit.messageHandlers && w.webkit.messageHandlers.zeehoIOS;
      if (handler && w.__zeehoIOS) {
        handler.postMessage({ version: 1, nonce: w.__zeehoIOS.nonce, id: 'diag-' + Date.now(),
          method: 'app.diag', args: [{ message: full.slice(0, 3000) }] });
      }
    } catch (e) { /* 诊断通道失败不影响显示 */ }
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

  // 白屏取证：如果 6 秒后文档还在 loading，直接在页面最上层画一条诊断条。
  // 这条不是给用户看的成品 UI，是用来区分「真的没渲染」和「渲染了但被遮挡」——
  // 只要这条能看见，就说明绘制链路正常，问题在被遮挡或颜色；看不见就是更深的问题。
  w.setTimeout(function () {
    try {
      var d = w.document;
      if (!d || !d.body) return;
      if (d.readyState === 'complete') return;
      var bar = d.createElement('div');
      bar.id = '__zeeho_ios_probe';
      bar.setAttribute('style', [
        'position:fixed', 'left:0', 'right:0', 'top:0', 'z-index:2147483646',
        'background:#ff0', 'color:#000', 'font:12px/1.4 -apple-system,sans-serif',
        'padding:8px', 'white-space:pre-wrap', 'word-break:break-all'
      ].join(';'));
      var stage = d.querySelector('.stage');
      var cs = stage ? w.getComputedStyle(stage) : null;
      bar.textContent = 'iOS 探针 readyState=' + d.readyState
        + '\nbodyChildren=' + d.body.children.length
        + ' bodyLen=' + (d.body.innerHTML || '').length
        + '\nstage.display=' + (cs ? cs.display : 'n/a')
        + ' stage.opacity=' + (cs ? cs.opacity : 'n/a')
        + ' stage.visibility=' + (cs ? cs.visibility : 'n/a')
        + ' stage.zIndex=' + (cs ? cs.zIndex : 'n/a');
      d.body.appendChild(bar);
    } catch (e) { /* 取证失败就算了 */ }
  }, 6000);

  // 桥诊断：把 candidate 判定的每一项单独报出来。
  // 「当前是 UI 测试预览」= candidate 为 false，但光看结果猜不出是哪一项挂了。
  w.setTimeout(function () {
    try {
      var d = w.document;
      if (!d || !d.body) return;
      var br = w.IOSBR;
      if (!br || br.candidate()) return;   // 桥正常就什么都不做
      var native = w.__zeehoIOS;
      var h = w.webkit && w.webkit.messageHandlers && w.webkit.messageHandlers.zeehoIOS;
      var detail = [
        '原生桥判定失败（candidate=false）',
        '__zeehoIOS=' + (native ? 'present' : 'MISSING'),
        'flavor=' + (native ? native.flavor : 'n/a'),
        'version=' + (native ? native.version : 'n/a'),
        'nonce.len=' + (native && native.nonce ? String(native.nonce).length : 'n/a'),
        'capabilities=' + (native && native.capabilities ? native.capabilities.length : 'n/a'),
        'hasHello=' + (native && native.capabilities ? native.capabilities.indexOf('hello') >= 0 : 'n/a'),
        'handler=' + (h && typeof h.postMessage === 'function' ? 'ok' : 'MISSING'),
        'storeSnapshot=' + (native && native.storeSnapshot ? typeof native.storeSnapshot : 'n/a'),
        'storeReadError=' + (native ? String(native.storeReadError) : 'n/a'),
        'IOSBR=' + (br ? 'present' : 'MISSING'),
        'available=' + (br && br.available ? br.available() : 'n/a'),
        'origin=' + w.location.origin
      ].join('\n');
      showFatal('原生桥未就绪', detail);
    } catch (e) { /* 诊断失败不抛 */ }
  }, 3000);

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
