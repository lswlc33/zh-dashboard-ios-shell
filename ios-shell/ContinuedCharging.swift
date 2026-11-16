import Foundation
import UIKit
import BackgroundTasks

/// 仅由当次前台「手动开始充电追踪」调用；自动充电检测、恢复与后台采样不得调用 start。
/// 本类只持有系统执行会话，真实采样由调用方负责，不创建 HTTP、定时器或车控。
/// 对外接口沿用 SystemSurfaces 的主线程约定，旧系统也可直接调用而无需 actor 可用性分支。
final class IOSContinuedCharging {
    static let shared = IOSContinuedCharging()

    // 不让 iOS 26 类型泄漏到旧系统的存储布局，也让旧编译器保留相同调用接口。
    private var current: AnyObject?
    private init() {}

    /// true 仅表示系统接受了本次请求，不保证持续时长；false 不影响车辆自身充电。
    @discardableResult
    func start(ownerID: String, socPercent: Double, onExpired: @escaping () -> Void) -> Bool {
        precondition(Thread.isMainThread)
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            guard UIApplication.shared.applicationState == .active,
                  !ownerID.isEmpty, Self.validSOC(socPercent), socPercent < 100,
                  current == nil else { return false }

            let identifier = "io.github.lswlc33.dashboard.ios.continued." + UUID().uuidString
            let session = Session(ownerID: ownerID, identifier: identifier,
                                  socPercent: socPercent, onExpired: onExpired)
            current = session
            // Info.plist 放 continued.*；动态注册必须用本次请求的精确 identifier。
            let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) {
                [weak self, weak session] task in
                // 明确指定主队列，立即安装 expirationHandler，不把安装延迟到另一个 Task。
                precondition(Thread.isMainThread)
                guard let self = self, let session = session,
                      self.current === session, !session.finished else {
                    task.setTaskCompleted(success: false)
                    return
                }
                guard let continued = task as? BGContinuedProcessingTask else {
                    self.finish(session, success: false, expired: true)
                    task.setTaskCompleted(success: false)
                    return
                }
                session.task = continued
                continued.expirationHandler = { [weak self, weak session] in
                    DispatchQueue.main.async {
                        guard let self = self, let session = session else { return }
                        self.finish(session, success: false, expired: true)
                    }
                }
                self.publish(session)
            }
            guard registered else { current = nil; return false }

            let request = BGContinuedProcessingTaskRequest(identifier: identifier,
                                                          title: Self.title,
                                                          subtitle: Self.subtitle(socPercent))
            // 不排队：必须当次用户操作立即申请，失败后不重提、不后台自动恢复。
            request.strategy = .fail
            do {
                try BGTaskScheduler.shared.submit(request)
                return true
            } catch {
                finish(session, success: false, expired: false)
                return false
            }
        }
        #endif
        return false
    }

    func update(ownerID: String, socPercent: Double, charging: Bool) {
        precondition(Thread.isMainThread)
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), let session = current as? Session,
           session.ownerID == ownerID, !session.finished {
            // 停充是真实结束信号，即使本次 SOC 缺损也要释放执行会话。
            if Self.validSOC(socPercent) {
                session.socPercent = socPercent
                publish(session)
            }
            if !charging || (Self.validSOC(socPercent) && socPercent >= 100) {
                finish(session, success: true, expired: false)
            }
        }
        #endif
    }

    func stop(ownerID: String, success: Bool) {
        precondition(Thread.isMainThread)
        #if compiler(>=6.2)
        if #available(iOS 26.0, *), let session = current as? Session, session.ownerID == ownerID {
            finish(session, success: success, expired: false)
        }
        #endif
    }

    #if compiler(>=6.2)
    @available(iOS 26.0, *)
    private final class Session {
        let ownerID: String
        let identifier: String
        var socPercent: Double
        var onExpired: (() -> Void)?
        var task: BGContinuedProcessingTask?
        var finished = false

        init(ownerID: String, identifier: String, socPercent: Double, onExpired: @escaping () -> Void) {
            self.ownerID = ownerID
            self.identifier = identifier
            self.socPercent = socPercent
            self.onExpired = onExpired
        }
    }

    private static let title = "充电追踪"
    private static func validSOC(_ value: Double) -> Bool { value.isFinite && (0...100).contains(value) }
    private static func subtitle(_ soc: Double) -> String { String(format: "电量 %.1f%%", soc) }

    @available(iOS 26.0, *)
    private func publish(_ session: Session) {
        guard !session.finished, let task = session.task else { return }
        // 1000 格对应真实电量的 0.1%；SOC 不变就不前进，也不在结束时伪造满格。
        task.progress.totalUnitCount = 1000
        task.progress.completedUnitCount = Int64(session.socPercent * 10)
        task.updateTitle(Self.title, subtitle: Self.subtitle(session.socPercent))
    }

    @available(iOS 26.0, *)
    private func finish(_ session: Session, success: Bool, expired: Bool) {
        guard !session.finished else { return }
        session.finished = true
        if current === session { current = nil }
        let task = session.task
        session.task = nil
        task?.expirationHandler = nil
        let callback = session.onExpired
        session.onExpired = nil
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: session.identifier)
        // 先清状态再回调：调用方可重入 stop，但只完成一次。回调只停止额外采样/活动，不能停车辆。
        // 系统强退不保证执行 expirationHandler；不持久化、不自动重启此会话。
        if expired { callback?() }
        task?.setTaskCompleted(success: success)
    }
    #endif
}
