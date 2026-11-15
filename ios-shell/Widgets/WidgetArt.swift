import Foundation
import UIKit
import ZeehoSystemShared

// 小组件车模素材（读侧）。
//
// 素材由主 App 在 `system.snapshot` 落盘后按需下载（见 SystemSurfaces 的车模下载），
// 存进 App Group 的 `widget-vehicle-art-<ownerID>.png`（存取契约在
// Shared/SystemWidgetArt.swift）。扩展只读文件、不联网、不解码之外的任何事。
//
// 为什么按匿名 owner id 分文件，而不是一个固定 `widget-vehicle-art.png`：
// 换车/换账号时同一个固定文件会被上一辆车（或上一个账号）的图覆盖，
// 桌面小组件在刷新窗口内就会显示别人的车。ownerID 是
// accountVINHash + "." + scopeID 的匿名摘要，既不含原始 VIN 也不含账号名。
enum ZeehoWidgetArt {
    /// 素材解码上限，与 Android WidgetCar.MAX_W/H(420×280) 对齐。
    static let maxPixelWidth = SystemWidgetArt.maxPixelWidth
    static let maxPixelHeight = SystemWidgetArt.maxPixelHeight
    /// 读盘上限，与 Android WidgetCar.MAX_BYTES 同一口径（Shared 侧写入也按它截断）。
    static let maxBytes = SystemWidgetArt.maxBytes

    /// ownerID 为空（还没拿到快照）→ nil，由布局层保持占位（不塌陷）。
    static func vehicleImage(ownerID: String) -> UIImage? {
        guard !ownerID.isEmpty,
              let data = SystemWidgetArt.read(ownerID: ownerID, limit: maxBytes), !data.isEmpty,
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
