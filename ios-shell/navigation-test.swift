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
        print("iOS navigation checks passed")
    }
}
