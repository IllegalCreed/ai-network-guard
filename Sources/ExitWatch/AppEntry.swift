import AppKit
import SwiftUI
import ExitWatchCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model: MonitorModel
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!

    @MainActor
    init(model: MonitorModel? = nil) {
        self.model = model ?? MonitorModel()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        configureStatusItem()
        configurePopover()

        model.onStatusChange = { [weak self] status in
            self?.updateStatusItem(for: status)
        }
        updateStatusItem(for: model.status)
        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.imagePosition = .imageOnly
        button.toolTip = "出口守望"
        button.setAccessibilityLabel("出口守望")
    }

    private func configurePopover() {
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 430, height: 690)
        popover.contentViewController = NSHostingController(
            rootView: DashboardView(
                model: model,
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
        let image = NSImage(
            systemSymbolName: status.systemImage,
            accessibilityDescription: "出口守望：\(status.label)"
        )
        image?.isTemplate = false
        button.image = image?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        )
        button.contentTintColor = statusColor(for: status)
        button.toolTip = "出口守望：\(status.label)"
    }

    private func statusColor(for status: MonitorStatus) -> NSColor {
        switch status {
        case .safe: return .systemGreen
        case .risk: return .systemRed
        case .unknown: return .systemOrange
        case .offline: return .systemOrange
        case .checking: return .secondaryLabelColor
        case .idle: return .secondaryLabelColor
        }
    }
}

@main
struct ExitWatchMain {
    @MainActor
    static func main() async {
        if CommandLine.arguments.contains("--version") {
            print("ExitWatch 0.1.0")
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

        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }
}
