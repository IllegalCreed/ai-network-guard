import AppKit
import SwiftUI
import ExitWatchCore

@MainActor
struct DashboardView: View {
    @ObservedObject var model: MonitorModel
    let onQuit: () -> Void
    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(spacing: 12) {
                    summaryCard
                    probeSection
                    if showingSettings {
                        settingsCard
                    }
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
                    .fill(model.status.tint.opacity(0.14))
                    .frame(width: 38, height: 38)
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(model.status.tint)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("出口守望")
                    .font(.title3.weight(.bold))
                Text("实时检查代理分流与 IP 地理位置")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)
            StatusPill(status: model.status)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private var summaryCard: some View {
        HStack(spacing: 13) {
            Image(systemName: model.status.systemImage)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(model.status.tint)
                .frame(width: 35)

            VStack(alignment: .leading, spacing: 4) {
                Text(model.status.label)
                    .font(.headline)
                Text(model.summaryText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)
            if model.isChecking {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    model.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("立即检查")
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(model.status.tint.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(model.status.tint.opacity(0.22), lineWidth: 1)
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

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("设置")
                .font(.headline)

            Toggle("异常时发送系统通知", isOn: $model.alertsEnabled)

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

            Text("间隔范围 15–600 秒。IP 地理信息来自第三方数据库，网络类型仅作推测。")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
            Text("检测会访问公共 IP 探针，并将返回的 IP 发送给 ipapi.is 做定位；不会上传其他应用数据。")
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
                Label("设置", systemImage: "gearshape")
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
