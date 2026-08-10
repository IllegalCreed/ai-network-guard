import AppKit
import SwiftUI
import ExitWatchCore

@MainActor
struct DashboardView: View {
    @ObservedObject var model: MonitorModel
    @ObservedObject var leakModel: LeakCheckModel
    @ObservedObject var agentGuardModel: AgentGuardModel
    let onQuit: () -> Void
    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if showingSettings {
                settingsCard
                    .padding(.horizontal, 16)
                    .padding(.top, 14)
                    .padding(.bottom, 4)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            ScrollView {
                VStack(spacing: 12) {
                    summaryCard
                    probeSection
                    leakSection
                    deviceInfoSection
                    privacyNote
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 430, height: 690)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(displayStatus.tint.opacity(0.14))
                    .frame(width: 38, height: 38)
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(displayStatus.tint)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(ProductInfo.displayName)
                    .font(.title3.weight(.semibold))
                Text("保护 Claude、ChatGPT 等 AI Agent 的网络环境")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)
            StatusPill(status: displayStatus)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private var summaryCard: some View {
        HStack(spacing: 13) {
            Image(systemName: displayStatus.systemImage)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(displayStatus.tint)
                .frame(width: 35)

            VStack(alignment: .leading, spacing: 4) {
                Text(displayStatusTitle)
                    .font(.headline)
                Text(displaySummaryText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)
            if model.isChecking {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 30, height: 30)
            } else {
                RefreshIconButton {
                    model.refresh()
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(displayStatus.tint.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(displayStatus.tint.opacity(0.22), lineWidth: 1)
        )
    }

    private var probeSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("出口探针")
                    .font(.headline)
                Spacer()
                Text("\(model.resolvedCount)/\(model.definitions.count) 已完成")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(model.probes) { result in
                ProbeCard(result: result)
            }

            if model.probes.isEmpty && !model.isChecking {
                EmptyProbeCard()
            }
        }
    }

    private var leakSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("泄漏检测")
                        .font(.headline)
                    Text("按需检查 DNS 解析器与 WebRTC/UDP 出口")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if leakModel.isChecking {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    LeakRunButton {
                        leakModel.runAll(knownPublicIPs: currentEgressIPs)
                    }
                }
            }

            dnsLeakCard
            webRTCLeakCard

            Text("检测会向 bash.ws 发送随机 DNS 探针，并向 Google STUN 发送一个 UDP Binding 请求；不会读取浏览历史、摄像头或麦克风。STUN 结果用于识别 WebRTC 常见的 UDP 旁路，浏览器自身策略仍可能不同。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var deviceInfoSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("设备信息")
                .font(.headline)
                .padding(.bottom, 4)

            ForEach(deviceInfoRows) { row in
                DeviceInfoRow(data: row)
                if row.id != deviceInfoRows.last?.id {
                    Divider()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 13)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var deviceInfoRows: [DeviceInfoRowData] {
        let local = DeviceEnvironmentSnapshot.current()
        return [
            timeZoneRowData(local: local),
            DeviceInfoRowData(
                id: "language",
                label: "语言",
                value: local.preferredLanguageIdentifier,
                detail: "仅显示本机语言；AI 客户端语言未暴露",
                state: .localOnly
            ),
            DeviceInfoRowData(
                id: "os",
                label: "操作系统",
                value: local.operatingSystemLabel,
                detail: "原生 macOS 应用",
                state: .localOnly
            ),
            DeviceInfoRowData(
                id: "network",
                label: "网络类型",
                value: model.networkInterfaceLabel,
                detail: networkDetailText,
                state: model.networkInterfaceLabel == "未检测" ? .unavailable : .localOnly
            )
        ]
    }

    private func timeZoneRowData(local: DeviceEnvironmentSnapshot) -> DeviceInfoRowData {
        let remoteTimeZones = Set(
            model.probes.compactMap { result in
                result.geo?.timeZoneIdentifier
            }
        )

        guard !remoteTimeZones.isEmpty else {
            return DeviceInfoRowData(
                id: "timezone",
                label: "时区",
                value: local.timeZoneLabel,
                detail: "等待出口定位后比较本机与出口时区",
                state: .unavailable
            )
        }

        let remoteText = remoteTimeZones.sorted().joined(separator: "、")
        if remoteTimeZones.contains(local.timeZoneIdentifier) {
            return DeviceInfoRowData(
                id: "timezone",
                label: "时区",
                value: local.timeZoneLabel,
                detail: "出口时区：\(remoteText)",
                state: .matched
            )
        }

        return DeviceInfoRowData(
            id: "timezone",
            label: "时区",
            value: local.timeZoneLabel,
            detail: "出口时区：\(remoteText)",
            state: .mismatched
        )
    }

    private var networkDetailText: String {
        let kinds = Set(model.probes.compactMap { $0.geo?.networkKind.label })
        guard !kinds.isEmpty else { return "等待出口探针定位" }
        return "出口类型：\(kinds.sorted().joined(separator: "、"))"
    }

    private var currentEgressIPs: Set<String> {
        Set(model.probes.compactMap(\.ip))
    }

    private var hasPrivacyRisk: Bool {
        leakModel.dnsStatus == .risk || leakModel.webRTCStatus == .risk
    }

    private var displayStatus: MonitorStatus {
        hasPrivacyRisk ? .risk : model.status
    }

    private var displayStatusTitle: String {
        hasPrivacyRisk ? "发现隐私风险" : model.status.label
    }

    private var displaySummaryText: String {
        guard hasPrivacyRisk else { return model.summaryText }
        if leakModel.dnsStatus == .risk && leakModel.webRTCStatus == .risk {
            return "DNS 与 WebRTC/STUN 探针均报告可能泄漏"
        }
        if leakModel.dnsStatus == .risk {
            return "DNS 探针观察到可能绕过代理的解析器"
        }
        return "WebRTC/STUN 的 UDP 出口与 HTTPS 出口不一致"
    }

    private var dnsLeakCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "network")
                    .foregroundStyle(leakModel.dnsStatus.tint)
                Text("DNS 泄漏")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                LeakStatusBadge(status: leakModel.dnsStatus)
            }

            if let result = leakModel.dnsResult {
                if let error = result.errorMessage, result.resolvers.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    if let conclusion = dnsConclusionText(for: result), !conclusion.isEmpty {
                        Text(conclusion)
                            .font(.caption)
                            .foregroundStyle(
                                result.assessment == .possibleLeak
                                    ? .red
                                    : result.assessment == .trustedUpstream
                                        ? .green
                                        : .secondary
                            )
                    }
                    if let clientIP = result.clientIP {
                        DetailLine(label: "探针看到的 IP", value: clientIP)
                    }
                    if !result.resolvers.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("观察到的 DNS 解析器")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            ForEach(Array(result.resolvers.prefix(3))) { resolver in
                                Text(resolver.detailText)
                                    .font(.system(.caption2, design: .monospaced))
                                    .lineLimit(1)
                            }
                            if result.resolvers.count > 3 {
                                Text("另有 \(result.resolvers.count - 3) 个解析器")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } else {
                Text("尚未运行。点击“检测”开始一次按需检测。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("远端探针：bash.ws")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("重测") {
                    leakModel.runDNSOnly()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(leakModel.isChecking)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(leakModel.dnsStatus.tint.opacity(0.25), lineWidth: 1)
        )
    }

    private func dnsConclusionText(for result: DNSLeakResult) -> String? {
        switch result.assessment {
        case .trustedUpstream:
            let providers = Array(Set(result.resolvers.compactMap(\.publicProviderName)))
                .sorted()
                .joined(separator: "、")
            if providers.isEmpty {
                return "已观察到受信任的公共 DNS 上游；通常表示代理的 DoH/DoT 已接管"
            }
            return "已观察到 \(providers) 公共 DNS 上游；通常表示代理的 DoH/DoT 已接管"
        case .noLeak, .possibleLeak, .unknown:
            return result.conclusion
        }
    }

    private var webRTCLeakCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "video.badge.waveform")
                    .foregroundStyle(leakModel.webRTCStatus.tint)
                Text("WebRTC / STUN")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                LeakStatusBadge(status: leakModel.webRTCStatus)
            }

            if let result = leakModel.webRTCResult {
                if let error = result.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if !result.unexpectedPublicAddresses.isEmpty {
                    DetailLine(
                        label: "未匹配出口 IP",
                        value: result.unexpectedPublicAddresses.joined(separator: ", ")
                    )
                }
                if !result.privateAddresses.isEmpty {
                    DetailLine(
                        label: "本地候选",
                        value: result.privateAddresses.joined(separator: ", ")
                    )
                }
                DetailLine(label: "ICE 候选", value: "\(result.candidates.count) 个")
                if !result.publicAddresses.isEmpty {
                    DetailLine(
                        label: "公网候选",
                        value: result.publicAddresses.joined(separator: ", ")
                    )
                }
            } else {
                Text("尚未运行。检测 WebRTC 常用的 UDP/STUN 出口是否绕过 HTTPS 代理。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("STUN：stun.l.google.com:19302")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("重测") {
                    leakModel.runWebRTCOnly(knownPublicIPs: currentEgressIPs)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(leakModel.isChecking)
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(leakModel.webRTCStatus.tint.opacity(0.25), lineWidth: 1)
        )
    }

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("设置", systemImage: "gearshape.fill")
                    .font(.headline)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showingSettings = false
                    }
                } label: {
                    Label("完成", systemImage: "xmark")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }

            Toggle("异常时发送系统通知", isOn: $model.alertsEnabled)
            Toggle("出口 IP 变化时自动检查 DNS/WebRTC", isOn: $leakModel.automaticChecksEnabled)
            Toggle("出口回到中国大陆/香港时关闭 Claude Code / ChatGPT", isOn: $agentGuardModel.enabled)

            HStack {
                Label("检查间隔", systemImage: "timer")
                Spacer()
                Stepper(
                    "\(Int(model.checkIntervalSeconds)) 秒",
                    value: $model.checkIntervalSeconds,
                    in: 15...600,
                    step: 15
                )
                .fixedSize()
            }

            Text("间隔范围 15–600 秒。断网或接口切换会立即触发刷新；DNS/WebRTC 仅在出口 IP 或接口变化时自动运行，避免重复发送探针流量。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("自动关闭默认关闭，仅在出口明确判定为中国大陆或中国香港时生效；不会因断网、探针失败或定位不完整而关闭软件。")
                .font(.caption2)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)

            if let action = agentGuardModel.lastActionText {
                Label(action, systemImage: "hand.raised.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }

    private var privacyNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text("检测会访问公共 IP 探针，并仅将返回的 IP 发送给 ipwho.is（失败时备用 ipapi.is）做定位；不会上传其他应用数据。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 2)
    }

    private var footer: some View {
        HStack {
            if let date = model.lastCheckedAt {
                Text("上次检查 \(date.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Text("尚未检查")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    showingSettings.toggle()
                }
            } label: {
                Label(showingSettings ? "关闭设置" : "设置", systemImage: showingSettings ? "xmark.circle" : "gearshape")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)

            Button("退出") {
                onQuit()
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

@MainActor
private struct ProbeCard: View {
    let result: ProbeResult

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: result.definition.symbolName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(result.isBlockedRegion ? .red : .secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(result.definition.name)
                        .font(.subheadline.weight(.semibold))
                    Text(result.definition.host)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                ProbeBadge(result: result)
            }

            Divider()

            HStack(alignment: .firstTextBaseline) {
                Text("IP")
                    .foregroundStyle(.secondary)
                Spacer()
                if let ip = result.ip {
                    Text(ip)
                        .font(.system(.subheadline, design: .monospaced).weight(.medium))
                        .textSelection(.enabled)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(ip, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("复制 IP")
                } else {
                    Text("未获取")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption)

            if let geo = result.geo {
                DetailLine(label: "位置", value: geo.locationText)
                DetailLine(label: "网络", value: geo.networkKind.label)
                if let organization = geo.organization, !organization.isEmpty {
                    DetailLine(label: "运营商", value: organization)
                }
                if let asn = geo.asn {
                    DetailLine(label: "ASN", value: "AS\(asn)")
                }
            } else if let error = result.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let trace = result.trace, trace.colo != nil || trace.reportedCountry != nil {
                HStack(spacing: 8) {
                    if let colo = trace.colo {
                        Text("边缘 \(colo)")
                    }
                    if let country = trace.reportedCountry {
                        Text("trace \(country)")
                    }
                    Spacer()
                    if let latency = result.latencyMilliseconds {
                        Text("\(latency) ms")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(13)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(result.isBlockedRegion ? Color.red.opacity(0.55) : Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

@MainActor
private struct DetailLine: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .font(.caption)
    }
}

private enum DeviceInfoState: Sendable {
    case matched
    case mismatched
    case localOnly
    case unavailable

    var label: String {
        switch self {
        case .matched: return "一致"
        case .mismatched: return "不一致"
        case .localOnly: return "本机"
        case .unavailable: return "未检测"
        }
    }

    var tint: Color {
        switch self {
        case .matched: return .green
        case .mismatched: return .orange
        case .localOnly: return .secondary
        case .unavailable: return .secondary
        }
    }
}

private struct DeviceInfoRowData: Identifiable {
    let id: String
    let label: String
    let value: String
    let detail: String?
    let state: DeviceInfoState
}

@MainActor
private struct DeviceInfoRow: View {
    let data: DeviceInfoRowData

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text(data.label)
                .foregroundStyle(.secondary)
                .frame(width: 108, alignment: .leading)

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 2) {
                Text(data.value)
                    .font(.subheadline.weight(.medium))
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
                if let detail = data.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                }
            }

            Text(data.state.label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(data.state.tint)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(data.state.tint.opacity(0.11), in: Capsule())
        }
        .padding(.vertical, 9)
    }
}

@MainActor
private struct ProbeBadge: View {
    let result: ProbeResult

    private var label: String {
        if result.isBlockedRegion { return "风险" }
        if result.geo != nil { return "正常" }
        if result.ip != nil { return "待定位" }
        return "失败"
    }

    private var color: Color {
        if result.isBlockedRegion { return .red }
        if result.geo != nil { return .green }
        if result.ip != nil { return .orange }
        return .secondary
    }

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.11), in: Capsule())
    }
}

@MainActor
private struct StatusPill: View {
    let status: MonitorStatus

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(status.tint)
                .frame(width: 7, height: 7)
            Text(status.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(status.tint)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(status.tint.opacity(0.11), in: Capsule())
    }
}

@MainActor
private struct LeakStatusBadge: View {
    let status: LeakProbeStatus

    var body: some View {
        Text(status.label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(status.tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(status.tint.opacity(0.11), in: Capsule())
    }
}

@MainActor
private struct RefreshIconButton: View {
    let action: () -> Void
    @State private var isHovering = false
    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 13, weight: .semibold))
                Text("刷新")
                    .font(.caption2.weight(.semibold))
            }
                .foregroundStyle(isHovering ? Color.accentColor : Color.primary.opacity(0.72))
                .padding(.horizontal, 9)
                .frame(height: 30)
                .background(
                    Capsule()
                        .fill(isHovering ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.055))
                )
                .overlay(
                    Capsule()
                        .stroke(
                            isHovering ? Color.accentColor.opacity(0.28) : Color.primary.opacity(0.09),
                            lineWidth: 0.6
                        )
                )
                .scaleEffect(isPressed ? 0.96 : 1)
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in isPressed = true }
                .onEnded { _ in isPressed = false }
        )
        .help("立即刷新")
        .accessibilityLabel("立即刷新出口状态")
    }
}

@MainActor
private struct LeakRunButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Label("检测", systemImage: "waveform.path.ecg")
                .font(.caption.weight(.medium))
                .foregroundStyle(isHovering ? Color.primary : Color.secondary)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(
                    Capsule()
                        .fill(Color.primary.opacity(isHovering ? 0.10 : 0.055))
                )
                .overlay(
                    Capsule()
                        .stroke(Color.primary.opacity(isHovering ? 0.11 : 0.06), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovering = hovering
            }
        }
        .help("运行 DNS 与 WebRTC/STUN 检测")
    }
}

@MainActor
private struct EmptyProbeCard: View {
    var body: some View {
        HStack(spacing: 9) {
            ProgressView()
                .controlSize(.small)
            Text("正在等待探针结果…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

private extension MonitorStatus {
    var tint: Color {
        switch self {
        case .safe: return .green
        case .risk: return .red
        case .unknown, .offline: return .orange
        case .checking, .idle: return .secondary
        }
    }
}

private extension LeakProbeStatus {
    var tint: Color {
        switch self {
        case .safe: return .green
        case .risk: return .red
        case .unknown: return .orange
        case .failed: return .orange
        case .checking, .idle: return .secondary
        }
    }
}
