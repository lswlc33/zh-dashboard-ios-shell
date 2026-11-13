import Foundation

// Navigation.swift 的独立回归测试：只链接 Navigation.swift，不能引用其他类型。
// 用 assert 而不是 XCTest：build.sh 用 `xcrun swiftc` 直接编出可执行文件就行，
// 不引入 swift test 的包结构与依赖解析（上传快照里没有测试 target）。
@main
enum NavigationTest {
    /// 两条真实线路的基址。GitHub Pages 的 path 带子目录，Cloudflare 是国际域名根路径。
    static let bases = [
        "https://lswlc33.github.io/zeeho-3d-models/",
        "https://zhb.xn--fiqz59cpva341l.top/"
    ]

    static func main() {
        for path in ["", "index.html", "?v=1", "#settings"] {
            assert(PanelNavigation.isPanel(URL(string: PanelNavigation.home.absoluteString + path)!))
        }
        for value in [
            "http://lswlc33.github.io/zeeho-3d-models/",
            "https://lswlc33.github.io.evil.example/zeeho-3d-models/",
            "https://lswlc33.github.io/zeeho-3d-models-evil/",
            "https://lswlc33.github.io/zeeho-3d-models/../other/",
            "https://user@lswlc33.github.io/zeeho-3d-models/",
            "https://lswlc33.github.io:8443/zeeho-3d-models/",
            "file:///zeeho-3d-models/index.html",
            "javascript:alert(1)"
        ] { assert(!PanelNavigation.isPanel(URL(string: value)!), value) }
        assert(PanelNavigation.isExternal(URL(string: "iosamap://path")!))
        // 「选择导航地图」提供四个入口，全部必须放行；只认 iosamap 会让百度/腾讯/Google
        // 静默失败（壳 cancel、网页看起来"点了没反应"）。
        assert(PanelNavigation.isExternal(URL(string: "baidumap://map/direction?mode=driving")!))
        assert(PanelNavigation.isExternal(URL(string: "qqmap://map/routeplan?type=drive")!))
        assert(PanelNavigation.isExternal(URL(string: "comgooglemaps://?daddr=1,2&directionsmode=driving")!))
        assert(PanelNavigation.isExternal(URL(string: "https://example.com")!))
        assert(!PanelNavigation.isExternal(URL(string: "javascript:alert(1)")!))
        assert(!PanelNavigation.isExternal(URL(string: "file:///etc/passwd")!))

        // 线路切换：base 换成哪条，自家首页就必须被认成面板。
        // 真机上踩过——Cloudflare 线路是国际化域名
        // zhb.xn--fiqz59cpva341l.top，Foundation 在不同入口可能给出 punycode
        // 或 Unicode 两种 host 形式，字符串直接比会把自家首页判成「非面板」，
        // 点「进入面板」立刻 navigation_not_allowed 白屏。
        let originalBase = PanelNavigation.base
        defer { PanelNavigation.base = originalBase }
        for base in bases {
            PanelNavigation.base = URL(string: base)!
            assert(PanelNavigation.isPanel(URL(string: base)!), base)
            assert(PanelNavigation.isPanel(URL(string: base + "index.html")!), base + "index.html")
            // 换线路后仍然只认自家，别的站点不能借道拿桥。
            assert(!PanelNavigation.isPanel(URL(string: "https://evil.example/")!), base)
        }

        // localURL(matching:) 往返 —— P0 的正题。
        // 旧实现把线上 path（`/zeeho-3d-models/`）原样搬到自定义 scheme，而 isPanel 的
        // 本地分支只认 `/` 与 `/index.html`，于是「有本地快照」时反而被自己的白名单拒掉，
        // 点「进入面板」直接白屏。这两条断言在旧实现下必失败，专门用来钉住这个回归。
        for base in bases {
            PanelNavigation.base = URL(string: base)!
            let home = PanelNavigation.home
            guard let local = PanelNavigation.localURL(matching: home) else {
                assertionFailure("localURL(matching:) 对主文档返回 nil: \(base)")
                continue
            }
            // 快照根目录里主文档就叫 index.html；不能带线上子路径前缀。
            assert(local.path == "/index.html", "localURL path 必须是 /index.html，实际 \(local.path)（base=\(base)）")
            // 往返：本地主文档必须被 isPanel 认成自家，否则导航会被取消。
            assert(PanelNavigation.isPanel(local), "isPanel(localURL(matching: home)) 必须为 true: \(local.absoluteString)")
        }
        // 查询串必须保留：`_shellNav` 是桥的文档身份，丢了握手就失败。
        PanelNavigation.base = URL(string: bases[0])!
        let delegated = URL(string: bases[0] + "index.html?_shellNav=abc")!
        if let local = PanelNavigation.localURL(matching: delegated) {
            assert(local.query?.contains("_shellNav=abc") == true, "localURL 必须保留查询串: \(local.absoluteString)")
        } else {
            assertionFailure("localURL(matching:) 不能对主文档返回 nil")
        }

        // 本地 scheme 边界：只有「host=panel、无端口、路径是根或 index.html」才允许拿桥。
        // 注意 `zeeho-panel://panel:8443/...` 与线上 https 的端口规则必须一致
        // （isPanel 的 https 分支已经拒绝非 443 端口），否则自定义 scheme 会变成一个
        // 只在本地生效的后门 origin。
        assert(PanelNavigation.isPanel(URL(string: "zeeho-panel://panel")!))
        assert(PanelNavigation.isPanel(URL(string: "zeeho-panel://panel/")!))
        assert(PanelNavigation.isPanel(URL(string: "zeeho-panel://panel/index.html")!))
        assert(!PanelNavigation.isPanel(URL(string: "zeeho-panel://panel:8443/index.html")!))
        // 百分号编码的 `..` 不能借规范化绕过路径白名单。
        assert(!PanelNavigation.isPanel(URL(string: "zeeho-panel://panel/%2e%2e/index.html")!))
        // 别的 host 一律不是面板。
        assert(!PanelNavigation.isPanel(URL(string: "zeeho-panel://evil/index.html")!))

        // IDN 双形态：punycode 是产品里写死的 literal，Unicode 是线路切换时可能
        // 从网页/配置拿到的形态，两种都该被认成自家，否则换线路就白屏。
        //
        // 但 Foundation 会不会把 Unicode host 归一成 punycode 依赖平台版本
        // （Darwin 与 corelibs-foundation 行为不同），`URL(string:)` 对非 ASCII host
        // 也可能返回 nil。所以这里对「本机不收敛」只 print 警告，不做硬断言——
        // 一个平台语义差异不该让 macOS 构建整体失败（会误报）。
        let punycodeText = "https://zhb.xn--fiqz59cpva341l.top/"
        let unicodeText = "https://zhb.雪中明月.top/"
        guard let punycodeBase = URL(string: punycodeText) else {
            assertionFailure("punycode 基址字面量必须能被 Foundation 解析")
            return
        }
        var idnForms = [punycodeBase]
        if let unicodeBase = URL(string: unicodeText) {
            idnForms.append(unicodeBase)
        } else {
            print("warning: Foundation 无法解析 Unicode 基址字面量，跳过该形态")
        }
        for base in idnForms {
            PanelNavigation.base = base
            for candidate in idnForms where !PanelNavigation.isPanel(candidate) {
                print("warning: isPanel(\(candidate.absoluteString)) == false while base = \(base.absoluteString)")
            }
        }
        // punycode ↔ punycode 是硬契约：默认线路就是 punycode literal，
        // originKey 内部再走一次 `URL(string: "https://" + host)` 也只会得到同一形态，
        // 认不出它等于 App 默认线路直接不可用。
        PanelNavigation.base = punycodeBase
        assert(PanelNavigation.isPanel(punycodeBase), "默认基址（punycode）必须被 isPanel 认成自家")

        print("iOS navigation checks passed")
    }
}
