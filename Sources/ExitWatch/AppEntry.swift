import AppKit
import SwiftUI
import UserNotifications
import ExitWatchCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private let model: MonitorModel
    private let leakModel: LeakCheckModel
    private let agentGuardModel: AgentGuardModel
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var lastAutomaticLeakSignature: String?
    private var hasPrivacyRisk = false

    @MainActor
    init(
        model: MonitorModel? = nil,
        leakModel: LeakCheckModel? = nil,
        agentGuardModel: AgentGuardModel? = nil
    ) {
        self.model = model ?? MonitorModel()
        self.leakModel = leakModel ?? LeakCheckModel()
        self.agentGuardModel = agentGuardModel ?? AgentGuardModel()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        UNUserNotificationCenter.current().delegate = self
        configureStatusItem()
        configurePopover()

        model.onStatusChange = { [weak self] status in
            guard let self else { return }
            self.handleStatusChange(status)
            self.agentGuardModel.update(status: status, probes: self.model.probes)
        }
        model.onNetworkPathChange = { [weak self] in
            self?.lastAutomaticLeakSignature = nil
        }
        leakModel.onPrivacyRisk = { [weak self] title, body, signature in
            guard let self else { return }
            self.hasPrivacyRisk = true
            self.updateStatusItem(for: .risk)
            self.model.notifyPrivacyRisk(title: title, body: body, signature: signature)
        }
        leakModel.onPrivacyRiskCleared = { [weak self] in
            guard let self else { return }
            self.hasPrivacyRisk = false
            self.updateStatusItem(for: self.model.status)
            self.model.clearPrivacyRiskNotification()
        }
        agentGuardModel.onAgentsClosed = { [weak self] title, body, signature in
            self?.model.notifyAgentGuard(title: title, body: body, signature: signature)
        }
        updateStatusItem(for: model.status)
        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
        leakModel.stop()
        agentGuardModel.stop()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.isVisible = true
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.image = statusIcon(for: .idle)
        button.contentTintColor = nil
        button.title = button.image == nil ? "◈" : ""
        button.font = .systemFont(ofSize: 14, weight: .semibold)
        button.toolTip = ProductInfo.displayName
        button.setAccessibilityLabel(ProductInfo.displayName)
    }

    private func configurePopover() {
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 430, height: 690)
        popover.contentViewController = NSHostingController(
            rootView: DashboardView(
                model: model,
                leakModel: leakModel,
                agentGuardModel: agentGuardModel,
                onQuit: { NSApp.terminate(nil) }
            )
        )
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func updateStatusItem(for status: MonitorStatus) {
        guard let button = statusItem?.button else { return }
        button.image = statusIcon(for: status)
        // The status icon is deliberately rendered as a bright, non-template
        // image. Template masks can be auto-inverted to black on some dark
        // menu-bar configurations, making the monitor impossible to spot.
        button.contentTintColor = nil
        button.title = button.image == nil ? "◈" : ""
        button.toolTip = "\(ProductInfo.displayName)：\(status.label)"
    }

    private func statusIcon(for status: MonitorStatus) -> NSImage? {
        if let url = Bundle.main.url(forResource: "ExitWatchStatus", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 18, height: 18)
            return tintedStatusImage(image, color: statusBarColor(for: status), status: status)
        }

        let image = NSImage(
            systemSymbolName: status.systemImage,
            accessibilityDescription: "\(ProductInfo.displayName)：\(status.label)"
        )
        guard let image else { return nil }
        image.size = NSSize(width: 18, height: 18)
        return tintedStatusImage(image, color: statusBarColor(for: status), status: status)
    }

    private func tintedStatusImage(_ image: NSImage, color: NSColor, status: MonitorStatus) -> NSImage {
        let tinted = NSImage(size: image.size)
        tinted.lockFocus()
        let rect = NSRect(origin: .zero, size: image.size)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        color.set()
        rect.fill(using: .sourceAtop)
        tinted.unlockFocus()
        tinted.isTemplate = false
        tinted.accessibilityDescription = "\(ProductInfo.displayName)：\(status.label)"
        return tinted
    }

    private func handleStatusChange(_ status: MonitorStatus) {
        updateStatusItem(for: hasPrivacyRisk ? .risk : status)

        guard leakModel.automaticChecksEnabled else {
            lastAutomaticLeakSignature = nil
            return
        }

        switch status {
        case .offline:
            lastAutomaticLeakSignature = nil
        case .safe, .risk, .unknown:
            guard !leakModel.isChecking else { return }
            let egressIPs = Set(model.probes.compactMap(\.ip))
            guard !egressIPs.isEmpty else { return }
            let signature = egressIPs.sorted().joined(separator: "|")
            guard signature != lastAutomaticLeakSignature else { return }
            lastAutomaticLeakSignature = signature
            leakModel.runAll(knownPublicIPs: egressIPs)
        case .idle, .checking:
            break
        }
    }

    private func statusBarColor(for status: MonitorStatus) -> NSColor {
        switch status {
        case .safe:
            return NSColor(calibratedRed: 0.16, green: 0.86, blue: 0.46, alpha: 1)
        case .risk:
            return NSColor(calibratedRed: 1.00, green: 0.25, blue: 0.26, alpha: 1)
        case .unknown, .offline:
            return NSColor(calibratedRed: 1.00, green: 0.66, blue: 0.15, alpha: 1)
        case .checking, .idle:
            return NSColor(calibratedRed: 0.22, green: 0.72, blue: 1.00, alpha: 1)
        }
    }
}

@main
struct ExitWatchMain {
    @MainActor
    static func main() async {
        if CommandLine.arguments.contains("--version") {
            print("ExitWatch \(ProductInfo.version) / \(ProductInfo.displayName)")
            return
        }

        if CommandLine.arguments.contains("--probe-once") {
            let service = IPProbeService()
            let results = await service.check(DefaultProbes.all)
            for result in results {
                let location = result.geo?.locationText ?? "定位失败"
                let network = result.geo?.networkKind.label ?? "未知"
                print("\(result.definition.id)\t\(result.ip ?? "-")\t\(location)\t\(network)")
            }
            return
        }

        if CommandLine.arguments.contains("--dns-once") {
            let service = DNSLeakProbeService()
            let result = await service.check()
            let clientIP = result.clientIP ?? "-"
            let resolverIPs = result.resolvers.map(\.ip).joined(separator: ",")
            let conclusion = result.conclusion ?? result.errorMessage ?? "-"
            print("dns\t\(result.assessment.rawValue)\t\(clientIP)\t\(resolverIPs)\t\(conclusion)")
            return
        }

        if CommandLine.arguments.contains("--webrtc-once") {
            let service = WebRTCProbeService()
            let payload = await service.check()
            let candidates = WebRTCCandidateParser.parse(lines: payload.candidateLines)
            let publicIPs = candidates.filter(\.isPublicAddress).map(\.address).joined(separator: ",")
            let privateIPs = candidates.filter(\.isPrivateAddress).map(\.address).joined(separator: ",")
            let error = payload.errorMessage ?? "-"
            print("webrtc\tsupported=\(payload.supported)\tcandidates=\(candidates.count)\tpublic=\(publicIPs)\tprivate=\(privateIPs)\t\(error)")
            return
        }

        if CommandLine.arguments.contains("--agents-once") {
            let service = AgentGuardService()
            let agents = service.listAgents()
            if agents.isEmpty {
                print("agents\tnone")
            } else {
                for agent in agents {
                    print("agents\t\(agent.displayName)\tpid=\(agent.pid)")
                }
            }
            return
        }

        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }
}
