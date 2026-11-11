// 固定 documentStart 模板。Swift 仅替换 JSON 配置标记，不拼接网页提供的脚本。
(function (w, config) {
  'use strict';

  // 幂等：这个脚本会被执行两次——一次是 WKUserScript 的 atDocumentStart，
  // 一次是 didCommit 时的 evaluateJavaScript 补注入（前者在自定义 scheme 下
  // 可能不生效或延迟）。__zeehoIOS 是 configurable:false 的，重复定义会抛
  // "Attempting to change value of a readonly property" 把整页炸掉。
  if (w.__zeehoIOS) return;

  // 重试保护：注入可能因为「文档还没就绪」而失败（此时上面的 __zeehoIOS 不存在），
  // 于是整个脚本会再跑一遍。错误监听与两个探针定时器只能挂一次，否则重试 N 次
  // 就有 N 个定时器和 N 个监听器，错误风暴与重复 showFatal 都会来。
  var firstRun = !w.__zeehoIOSBooted;
  if (firstRun) {
    try { Object.defineProperty(w, '__zeehoIOSBooted', { value: 1, configurable: true, writable: false }); }
    catch (e) { /* 老内核不支持就算了，最多重复挂一次 */ }
  }

  // 诊断面板：网页在真机白屏时，光看 Xcode/Console 拿不到线索（TrollStore 装的包
  // 也没法连调试器）。这里在 documentStart 就挂好错误捕获，一旦脚本抛错或资源
  // 加载失败，直接把原因画在页面上——比白屏让用户猜好得多。
  //
  // 呈现方式要分情况：文档里真的一无所有（body 不存在或没有子节点）才铺满全屏；
  // 已经有内容时只画顶部条。否则一个 icon 的 404 或一条未处理的 Promise 拒绝
  // 就能把已经渲染好的页面整片盖成黑色——用户看到的「纯黑点不动」就是这么来的。
  function showFatal(title, detail, forceFull) {
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
        var existing = w.document.getElementById(id);
        if (existing) {
          // 已经画过：只追加一行，不重建（避免把用户正在看的错误覆盖掉）。
          var more = w.document.createElement('div');
          more.textContent = full;
          more.setAttribute('style', 'margin-top:10px;padding-top:10px;border-top:1px solid #ff8a80');
          existing.appendChild(more);
          return;
        }
        var blank = !w.document.body.children || w.document.body.children.length === 0;
        var overlay = forceFull === true || blank;
        var box = w.document.createElement('div');
        box.id = id;
        box.setAttribute('style', overlay ? [
          'position:fixed', 'inset:0', 'z-index:2147483647',
          'background:#111', 'color:#eee', 'font:13px/1.5 -apple-system,sans-serif',
          'padding:24px', 'overflow:auto', 'white-space:pre-wrap',
          'word-break:break-word', '-webkit-user-select:text', 'user-select:text'
        ].join(';') : [
          'position:fixed', 'left:0', 'right:0', 'top:0', 'max-height:40vh', 'overflow:auto',
          'z-index:2147483647', 'background:#2b1113', 'color:#eee',
          'font:12px/1.45 -apple-system,sans-serif', 'padding:10px 12px',
          'white-space:pre-wrap', 'word-break:break-word', 'box-shadow:0 2px 8px rgba(0,0,0,.4)',
          '-webkit-user-select:text', 'user-select:text'
        ].join(';'));
        var head = w.document.createElement('div');
        head.setAttribute('style', 'font-size:14px;font-weight:600;margin-bottom:6px;color:#ff8a80');
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

  // 错误只报一次，避免错误风暴把屏幕刷满。但不再用「全局一个 flag」把后续
  // 全部静音——那会让第一个 img 404 把后面真正的脚本错误一起吞掉。改成按
  // title 去重：同类错误只报一次，不同类照报。
  var reportedKinds = Object.create(null);
  function reportOnce(kind, title, detail, forceFull) {
    if (reportedKinds[kind]) return;
    reportedKinds[kind] = 1;
    showFatal(title, detail, forceFull);
  }
  // 只有脚本/样式表加载失败值得上屏；图片、字体、图标的 404 交给 diag 日志，
  // 否则一个缺图就能把画好的页面盖成黑色。
  w.addEventListener('error', function (event) {
    // 资源加载失败（img/script/link）没有 message，只有 target。
    var target = event && event.target;
    if (target && target !== w && target.tagName) {
      var tag = String(target.tagName).toUpperCase();
      if (tag !== 'SCRIPT' && tag !== 'LINK') return;
      var url = String(target.src || target.href || '');
      reportOnce('resource:' + tag + ':' + url, '资源加载失败', tag + '\n' + url);
      return;
    }
    var where = event && event.filename
      ? '\n\n' + event.filename + ':' + event.lineno + ':' + event.colno : '';
    var message = String((event && event.message) || event);
    reportOnce('script:' + message.slice(0, 120), '脚本错误', message + where);
  }, true);
  w.addEventListener('unhandledrejection', function (event) {
    var reason = event && event.reason;
    var text = String((reason && (reason.stack || reason.message)) || reason);
    // Promise 拒绝大多是业务可选路径（某个接口 404 被 catch 漏了），
    // 只画顶部条，不盖全屏。
    reportOnce('promise:' + text.slice(0, 120), '未处理的 Promise 拒绝', text);
  });

  // 下面三段探针只在第一次执行时挂：重试注入时不能再挂一遍定时器。
  if (firstRun) {
  // 网页 8 秒内没把首屏画出来就当失败：正常单文件产物 1~2 秒就该有内容。
  var painted = false;
  w.addEventListener('zeehoios:painted', function () { painted = true; });
  w.setTimeout(function () {
    if (painted) return;
    if (!w.document || !w.document.body) return;
    // 已经有可见内容就不打扰（例如只有 bootskel 也算活着）。
    if (w.document.body.children.length > 0) return;
    showFatal('页面 8 秒内没有任何内容',
      '文档已加载但 body 为空。\n\nlocation=' + w.location.href +
      '\norigin=' + w.location.origin +
      '\nUA=' + w.navigator.userAgent, true);
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
      // 桥正常、或者还没被补注入（另一种状态）就什么都不做。
      if (br && br.candidate()) return;
      if (w.__zeehoIOS) return;
      var h = w.webkit && w.webkit.messageHandlers && w.webkit.messageHandlers.zeehoIOS;
      var detail = [
        '原生桥判定失败（candidate=false）',
        '__zeehoIOS=' + (w.__zeehoIOS ? 'present' : 'MISSING'),
        'handler=' + (h && typeof h.postMessage === 'function' ? 'ok' : 'MISSING'),
        'IOSBR=' + (br ? 'present' : 'MISSING'),
        'available=' + (br && br.available ? br.available() : 'n/a'),
        'origin=' + w.location.origin,
        'href=' + w.location.href
      ].join('\n');
      showFatal('原生桥未就绪', detail);
    } catch (e) { /* 诊断失败不抛 */ }
  }, 3000);
  }  // end firstRun

  // 文档身份校验。
  //
  // 不能直接比 `location.origin`：自定义 scheme（zeeho-panel://）的 origin 在
  // WebKit 里可能是字符串 "null"（opaque origin），而 config.origin 是
  // "zeeho-panel://panel"，一比就 return —— 整页没有原生桥，表现为白屏。
  // 所以按 scheme/host 分开判：
  //   * http(s)：origin 或 protocol+host 等于配置值（兼容端口写法）。
  //   * 自定义 scheme：protocol/host 精确相等（host 可能为空，那就只比 protocol）。
  // 路径用「相对 rootPath 的尾部」判，兼容 host 被塞进 path 的写法
  // （zeeho-panel:///panel/index.html 在部分 Foundation 版本上 pathname 是
  //  /panel/index.html）。
  function normalisePath(value) {
    return String(value || '/').replace(/\/{2,}/g, '/');
  }
  var scheme = String(w.location.protocol || '').replace(/:$/, '').toLowerCase();
  var hostname = String(w.location.host || '').toLowerCase();
  var hrefPrefix = scheme + '://' + hostname;
  var schemeOk = !config.scheme || scheme === String(config.scheme).toLowerCase();
  var hostOk = !config.host || hostname === String(config.host).toLowerCase();
  var originOk = schemeOk && hostOk;
  if (scheme === 'https' || scheme === 'http') {
    // http(s) 额外认可 origin 字符串与 protocol+//+host（排除端口差异带来的假失败）。
    originOk = originOk || w.location.origin === config.origin || hrefPrefix === config.origin;
  }
  var pathname = normalisePath(w.location.pathname);
  var rootPath = normalisePath(config.rootPath || '');
  var tail = null;
  if (rootPath && pathname.indexOf(rootPath) === 0) tail = pathname.slice(rootPath.length);
  var pathOk = (tail !== null && (tail === '' || tail === '/' || tail === '/index.html'))
    || config.paths.indexOf(pathname) >= 0
    || config.paths.indexOf(normalisePath(w.location.pathname)) >= 0;
  if (w !== w.top || !originOk || !pathOk) {
    // 这里 return 会让整页没有原生桥，是最常见的白屏原因，必须报出来。
    showFatal('原生桥未注入',
      'location.origin=' + w.location.origin +
      '\nlocation.host=' + w.location.host +
      '\n期望 origin=' + config.origin +
      '\n期望 scheme/host=' + config.scheme + ' / ' + config.host +
      '\nlocation.pathname=' + w.location.pathname +
      '\n期望 rootPath=' + config.rootPath +
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
  // 通知网页「桥到了」。
  //
  // 关键场景：atDocumentStart 的 user script 在自定义 scheme 下可能延迟 2 秒以上，
  // 而 js/ios-bridge.js 早在它之前就跑完了——那时 __zeehoIOS 还是 undefined，
  // candidate 被算成 false，网页退回「UI 测试预览」且再也不重算。
  // ios-bridge.js 监听这个事件后会重算 candidate 并重新握手，已渲染的页面不用刷新。
  try {
    if (w.dispatchEvent && typeof w.CustomEvent === 'function') {
      w.dispatchEvent(new w.CustomEvent('zeehoios:bridge', { detail: Object.freeze({ navId: config.navId }) }));
    }
  } catch (e) { /* 事件派发失败不影响桥本身 */ }
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
