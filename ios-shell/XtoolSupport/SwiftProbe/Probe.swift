import UIKit
import WebKit

// 独立工具链探针，不带业务桥、账户、KMP 或假 extension；绝不能当成完整面板发布。
@main
final class SwiftProbeApp: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let controller = UIViewController()
        let web = WKWebView(frame: .zero)
        controller.view = web
        web.loadHTMLString("<h1>SwiftProbe</h1><p>UIKit / WebKit cross-compile probe only. Not DashboardIOS.</p>", baseURL: nil)
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        self.window = window
        return true
    }
}
