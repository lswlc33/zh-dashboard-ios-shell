import Foundation
import UIKit
import ZeehoSystemShared

// 小组件车模素材。
//
// 现状：iOS 侧还没有把车模/立绘写进 App Group 的链路（Android 走 WidgetCar 缓存 PNG）。
// 所以这里先只认一个约定路径，取不到就返回 nil，由布局层保持占位（不塌陷）。
// 后续把主 App 的 3D/立绘素材导出到这里即可，无需改布局代码。
enum ZeehoWidgetArt {
    /// 约定的共享素材文件名（放在 App Group 根目录）。
    static let fileName = "widget-vehicle-art.png"
    /// 素材解码上限，与 Android WidgetCar.MAX_W/H(420×280) 对齐。
    static let maxPixelWidth = 420
    static let maxPixelHeight = 280

    static func vehicleImage() -> UIImage? {
        guard let root = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: AppGroup.current()) else { return nil }
        let url = root.appendingPathComponent(fileName, isDirectory: false)
        guard let data = try? Data(contentsOf: url), !data.isEmpty,
              let image = UIImage(data: data) else { return nil }
        // 超过上限等比缩小：小组件里贴图不能吃满内存。
        let width = image.size.width * image.scale
        let height = image.size.height * image.scale
        guard width > 0, height > 0 else { return nil }
        let ratio = min(1, min(Double(maxPixelWidth) / Double(width), Double(maxPixelHeight) / Double(height)))
        guard ratio < 1 else { return image }
        let target = CGSize(width: width * ratio, height: height * ratio)
        let renderer = UIGraphicsImageRenderer(size: target)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
    }
}
