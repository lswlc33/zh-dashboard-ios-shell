import Foundation

@main
enum NavigationTest {
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
        for base in ["https://lswlc33.github.io/zeeho-3d-models/",
                     "https://zhb.xn--fiqz59cpva341l.top/"] {
            PanelNavigation.base = URL(string: base)!
            assert(PanelNavigation.isPanel(URL(string: base)!), base)
            assert(PanelNavigation.isPanel(URL(string: base + "index.html")!), base + "index.html")
            // 换线路后仍然只认自家，别的站点不能借道拿桥。
            assert(!PanelNavigation.isPanel(URL(string: "https://evil.example/")!), base)
        }

        print("iOS navigation checks passed")
    }
}
