import Foundation
import SwiftUI
import MFanControlShared
#if canImport(AppKit)
import AppKit
#endif

struct MenuBarPopoverView: View {
    let model: MenuBarViewModel
    let onSelectMode: (ThermalPolicy.Mode) -> Void
    let onRestoreDefault: () -> Void
    let onRefresh: () -> Void
    let onClose: () -> Void

    private let panelWidth: CGFloat = 424
    private let panelHeight: CGFloat = 720

    var body: some View {
        ZStack {
            background

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    headerCard
                    metricGrid
                    sensorSection
                    decisionSection
                    historySection
                    modeSection
                    actionSection
                    footer
                }
                .padding(16)
            }
        }
        .frame(width: panelWidth, height: panelHeight)
    }

    private var background: some View {
        LinearGradient(
            colors: [
                Color.accentColor.opacity(0.18),
                Color(nsColor: .windowBackgroundColor).opacity(0.95),
                Color(nsColor: .controlBackgroundColor).opacity(0.92)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(
            RadialGradient(
                colors: [
                    Color.accentColor.opacity(0.10),
                    Color.clear
                ],
                center: .topTrailing,
                startRadius: 40,
                endRadius: 420
            )
        )
    }

    private var headerCard: some View {
        CardSurface(tint: model.stateTintColor, accentOpacity: 0.16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("MFanControl")
                            .font(.system(size: 21, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)
                        Text(model.deviceLabel)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    Spacer(minLength: 8)

                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .background(Color.primary.opacity(0.06), in: Circle())
                    .accessibilityLabel("关闭面板")
                }

                HStack(spacing: 8) {
                    StatusBadge(text: model.stateReadable, tint: model.stateTintColor)
                    StatusBadge(text: model.modeDisplayName, tint: model.modeTintColor)
                    StatusBadge(text: model.controlSourceLabel, tint: model.sourceTintColor)
                    if model.appBoostActive {
                        StatusBadge(text: "App 触发", tint: .orange)
                    }
                }

                HStack(spacing: 10) {
                    MetricInline(label: "热点", value: model.hottestTemperatureLabel, tint: model.temperatureTint)
                    MetricInline(label: "风扇", value: model.fanSummary, tint: .blue)
                }

                if let issue = model.controlIssue, !issue.isEmpty {
                    WarningBanner(text: issue)
                }
            }
        }
    }

    private var metricGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "核心状态", subtitle: "控制、热压力和硬件概览")

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 10),
                GridItem(.flexible(), spacing: 10)
            ], spacing: 10) {
                InfoTile(title: "热压力", icon: "thermometer.sun.fill", tint: model.thermalScoreTint) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(Int(model.thermalScore))")
                                .font(.system(size: 26, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(.primary)
                            Text(model.thermalBandLabel)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(model.thermalScoreTint)
                        }

                        ThermalBar(score: model.thermalScore, tint: model.thermalScoreTint)

                        Text(model.thermalScoreDetail)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                InfoTile(title: "风扇", icon: "fan.fill", tint: .blue) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(model.currentRPM) rpm")
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                        Text("目标 \(model.targetRPM) rpm")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Text(model.fanCapabilityLabel)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                InfoTile(title: "传感器", icon: "chart.line.uptrend.xyaxis", tint: .green) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.sensorCoverageLabel)
                            .font(.system(size: 19, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)
                        Text(model.sensorCoverageDetail)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                InfoTile(title: "控制源", icon: "slider.horizontal.3", tint: model.sourceTintColor) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.controlSourceLabel)
                            .font(.system(size: 19, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)
                        Text(model.stateReadable)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                InfoTile(title: "硬件", icon: "cpu.fill", tint: .purple) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.hardwareSummaryTitle)
                            .font(.system(size: 19, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(model.hardwareSummaryDetail)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }

                InfoTile(title: "电源", icon: "battery.100", tint: .orange) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.powerSourceLabel)
                            .font(.system(size: 19, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(model.powerDetail)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
    }

    private var sensorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "传感器明细", subtitle: "按当前可用性和温度排序")

            VStack(spacing: 8) {
                ForEach(model.orderedSensorReadings, id: \.id) { reading in
                    SensorRow(reading: reading)
                }
            }
        }
    }

    private var decisionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "决策解释", subtitle: "把当前状态拆开看清楚")

            CardSurface(tint: .blue, accentOpacity: 0.10) {
                VStack(alignment: .leading, spacing: 12) {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 106), spacing: 8)],
                        alignment: .leading,
                        spacing: 8
                    ) {
                        ForEach(model.decisionFacts) { fact in
                            FactChip(label: fact.key, value: fact.value, tint: fact.tint)
                        }
                    }

                    if model.hasDecisionReason {
                        Text(model.formattedDecisionReason)
                            .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineSpacing(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("暂无决策摘要")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            CardSurface(tint: .orange, accentOpacity: 0.08) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("最近执行")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.primary)
                    if model.hasRuntimeReason {
                        Text(model.formattedRuntimeReason)
                            .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineSpacing(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        Text("暂无执行原因")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Text(model.timestampLabel)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "历史与告警", subtitle: "最近采样和状态变更")

            CardSurface(tint: .green, accentOpacity: 0.08) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("采样概览")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(model.recentSampleSummary)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 10) {
                        MetricInline(label: "采样", value: "\(model.recentSamples.count)", tint: .green)
                        MetricInline(label: "事件", value: "\(model.recentEvents.count)", tint: .orange)
                        MetricInline(label: "最近", value: model.recentSampleTail, tint: .blue)
                    }

                    if model.recentSamples.isEmpty {
                        Text("暂无采样记录")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(model.recentSampleCards) { card in
                                    SampleChip(card: card)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }

            CardSurface(tint: .orange, accentOpacity: 0.07) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("最近事件")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(model.recentEventSummary)
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    if model.recentEvents.isEmpty {
                        Text("暂无状态事件")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 8) {
                            ForEach(model.recentEventCards) { card in
                                EventRow(card: card)
                            }
                        }
                    }
                }
            }
        }
    }

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "切换模式", subtitle: "当前 \(model.modeDisplayName) · \(model.modeSwitchHint)")

            LazyVGrid(columns: [
                GridItem(.flexible(), spacing: 8),
                GridItem(.flexible(), spacing: 8)
            ], spacing: 8) {
                ForEach(ThermalPolicy.Mode.allCases, id: \.self) { mode in
                    ModeButton(
                        mode: mode,
                        title: model.modeDisplayName(for: mode),
                        isSelected: model.isActive(mode: mode),
                        isEnabled: model.canSwitchModes,
                        tint: model.modeTint(for: mode),
                        action: { onSelectMode(mode) }
                    )
                }
            }
        }
    }

    private var actionSection: some View {
        HStack(spacing: 10) {
            Button {
                onRestoreDefault()
            } label: {
                Label("恢复默认", systemImage: "arrow.uturn.backward.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(!model.canRestoreDefault)

            Button {
                onRefresh()
            } label: {
                Label("刷新", systemImage: "arrow.clockwise")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(model.footerLabel)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(model.modeStatusLabel)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(model.stateTintColor)
            }

            Text(model.configSummary)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 2)
    }
}

private struct CardSurface<Content: View>: View {
    let tint: Color
    let accentOpacity: Double
    let content: () -> Content

    init(tint: Color, accentOpacity: Double, @ViewBuilder content: @escaping () -> Content) {
        self.tint = tint
        self.accentOpacity = accentOpacity
        self.content = content
    }

    var body: some View {
        content()
            .padding(14)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(tint.opacity(0.18), lineWidth: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                tint.opacity(accentOpacity),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .allowsHitTesting(false)
            )
    }
}

private struct SectionLabel: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 13.5, weight: .semibold))
                .foregroundStyle(.primary)
            Text(subtitle)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 2)
    }
}

private struct InfoTile<Content: View>: View {
    let title: String
    let icon: String
    let tint: Color
    let content: () -> Content

    init(
        title: String,
        icon: String,
        tint: Color,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.icon = icon
        self.tint = tint
        self.content = content
    }

    var body: some View {
        CardSurface(tint: tint, accentOpacity: 0.12) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(width: 18, height: 18)
                        .background(tint.opacity(0.10), in: Circle())
                    Text(title)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }

                content()
            }
        }
    }
}

private struct StatusBadge: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

private struct MetricInline: View {
    let label: String
    let value: String
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(tint.opacity(0.08), in: Capsule())
    }
}

private struct WarningBanner: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text("当前控制受限")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(text)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.18), lineWidth: 1)
        )
    }
}

private struct ThermalBar: View {
    let score: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            let width = max(0, min(score, 100)) / 100 * proxy.size.width
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.12))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.95), tint.opacity(0.55)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: width)
            }
        }
        .frame(height: 8)
    }
}

private struct SensorRow: View {
    let reading: SensorDisplayReading

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(reading.available ? temperatureTint : Color.secondary.opacity(0.30))
                .frame(width: 9, height: 9)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 2) {
                Text(reading.label)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary)
                if reading.available {
                    Text("信心 \(Int(reading.confidence * 100))%")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                } else if !reading.reason.isEmpty {
                    Text(reading.reason)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(reading.available ? temperatureText : "不可用")
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(reading.available ? temperatureTint : .secondary)
                    .monospacedDigit()
                if reading.available {
                    Text("可用")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(reading.available ? temperatureTint.opacity(0.16) : Color.secondary.opacity(0.12), lineWidth: 1)
        )
    }

    private var temperatureText: String {
        guard let value = reading.valueC else { return "不可用" }
        return "\(Int(value))℃"
    }

    private var temperatureTint: Color {
        guard let value = reading.valueC else { return .secondary }
        switch value {
        case ..<55:
            return .green
        case 55..<70:
            return .yellow
        case 70..<80:
            return .orange
        default:
            return .red
        }
    }
}

private struct FactChip: View {
    let label: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint.opacity(0.85))
            Text(value)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tint.opacity(0.14), lineWidth: 1)
        )
    }
}

private struct ModeButton: View {
    let mode: ThermalPolicy.Mode
    let title: String
    let isSelected: Bool
    let isEnabled: Bool
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(isSelected ? tint : Color.secondary.opacity(0.22))
                        .frame(width: 7, height: 7)
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                Text(modeHint)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(backgroundFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(borderTint, lineWidth: isSelected ? 1.3 : 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityLabel(title)
    }

    private var backgroundFill: some ShapeStyle {
        if isSelected {
            return tint.opacity(0.16)
        }
        return Color.secondary.opacity(0.06)
    }

    private var borderTint: Color {
        isSelected ? tint.opacity(0.55) : Color.secondary.opacity(0.12)
    }

    private var modeHint: String {
        switch mode {
        case .quiet:
            return "优先安静，允许更温和的转速"
        case .balanced:
            return "默认策略，安静与温度平衡"
        case .performance:
            return "更积极压温，优先保性能"
        case .customCurve:
            return "按自定义曲线运行"
        }
    }
}

private struct MenuBarDecisionFact: Identifiable {
    let id = UUID()
    let key: String
    let value: String
    let tint: Color
}

private struct SampleCard: Identifiable {
    let id: String
    let label: String
    let value: String
    let detail: String
    let tint: Color
}

private struct EventCard: Identifiable {
    let id: String
    let timeLabel: String
    let title: String
    let detail: String
    let levelLabel: String
    let tint: Color
    let icon: String
}

private struct SampleChip: View {
    let card: SampleCard

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle()
                    .fill(card.tint)
                    .frame(width: 7, height: 7)
                Text(card.label)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Text(card.value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .monospacedDigit()
            Text(card.detail)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(width: 110, alignment: .leading)
        .background(card.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(card.tint.opacity(0.14), lineWidth: 1)
        )
    }
}

private struct EventRow: View {
    let card: EventCard

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: card.icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(card.tint)
                .frame(width: 18, height: 18)
                .background(card.tint.opacity(0.10), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(card.timeLabel)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(card.levelLabel)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(card.tint)
                }
                Text(card.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if !card.detail.isEmpty {
                    Text(card.detail)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineSpacing(2)
                        .lineLimit(3)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(card.tint.opacity(0.14), lineWidth: 1)
        )
    }
}

private extension MenuBarViewModel {
    var modeDisplayName: String {
        modeDisplayName(for: ThermalPolicy.Mode(rawValue: mode) ?? .balanced)
    }

    func modeDisplayName(for mode: ThermalPolicy.Mode) -> String {
        switch mode {
        case .quiet:
            return "静音"
        case .balanced:
            return "均衡"
        case .performance:
            return "性能"
        case .customCurve:
            return "自定义曲线"
        }
    }

    var modeTintColor: Color {
        switch mode {
        case "quiet":
            return .blue
        case "performance":
            return .orange
        case "customCurve":
            return .purple
        default:
            return .green
        }
    }

    func modeTint(for mode: ThermalPolicy.Mode) -> Color {
        switch mode {
        case .quiet:
            return .blue
        case .balanced:
            return .green
        case .performance:
            return .orange
        case .customCurve:
            return .purple
        }
    }

    var stateTintColor: Color {
        if !canControl {
            return .secondary
        }
        if state == "safetyFallback" {
            return .red
        }
        if state == "manualDefault" {
            return .secondary
        }
        if cpuThrottled || gpuThrottled {
            return .orange
        }
        if appBoostActive {
            return .orange
        }
        switch mode {
        case "quiet":
            return .blue
        case "performance":
            return .orange
        case "customCurve":
            return .purple
        default:
            return .green
        }
    }

    var sourceTintColor: Color {
        switch source {
        case "appAuto":
            return .green
        case "userManual":
            return .blue
        case "safetyMode":
            return .red
        default:
            return .secondary
        }
    }

    var temperatureTint: Color {
        guard let temp = currentTempC else { return .secondary }
        switch temp {
        case ..<55:
            return .green
        case 55..<70:
            return .yellow
        case 70..<80:
            return .orange
        default:
            return .red
        }
    }

    var thermalScoreTint: Color {
        switch thermalScore {
        case ..<31:
            return .green
        case 31..<61:
            return .yellow
        case 61..<81:
            return .orange
        default:
            return .red
        }
    }

    var thermalBandLabel: String {
        switch thermalScore {
        case ..<31:
            return "安静"
        case 31..<61:
            return "预警"
        case 61..<81:
            return "加速"
        default:
            return "安全"
        }
    }

    var thermalScoreDetail: String {
        let hottest = hottestSensorLabel == "N/A" ? "无热点" : "\(hottestSensorLabel) \(hottestTemperatureValue)"
        return "当前热点 \(hottest) · \(stateReadable)"
    }

    var hottestTemperatureLabel: String {
        if let temp = currentTempC {
            return "\(hottestSensorLabel) \(Int(temp))℃"
        }
        return "\(hottestSensorLabel) 不可用"
    }

    var hottestTemperatureValue: String {
        guard let temp = currentTempC else { return "不可用" }
        return "\(Int(temp))℃"
    }

    var fanSummary: String {
        if fanCount > 0, fanMinRPM > 0, fanMaxRPM > 0 {
            return "\(fanCount) 个 · \(fanMinRPM)–\(fanMaxRPM) rpm"
        }
        if fanCount > 0 {
            return "\(fanCount) 个"
        }
        return canControl ? "可控" : "只读"
    }

    var fanCapabilityLabel: String {
        if canControl {
            return "可控 · \(fanSummary)"
        }
        return "只读 · Apple 默认接管"
    }

    var sensorCoverageLabel: String {
        "\(availableSensorsCount)/\(totalSensorsCount) 可用"
    }

    var sensorCoverageDetail: String {
        if let sensor = orderedSensorReadings.first(where: { $0.available }) {
            return "热点 \(sensor.label) \(sensorValueText(sensor))"
        }
        return "当前没有可用温度通道"
    }

    var controlSourceLabel: String {
        switch source {
        case "appleDefault":
            return "Apple 默认"
        case "appAuto":
            return "App 自动"
        case "userManual":
            return "用户手动"
        case "safetyMode":
            return "保护中"
        default:
            return source
        }
    }

    var powerSourceLabel: String {
        let normalized = powerSource.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? "unknown" : normalized
    }

    var powerDetail: String {
        if appBoostActive {
            return "App 触发开启"
        }
        return "无额外触发"
    }

    var hardwareSummaryTitle: String {
        let parts = deviceLabel.split(separator: "/").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let first = parts.first, !first.isEmpty {
            return first
        }
        return deviceLabel
    }

    var hardwareSummaryDetail: String {
        "风扇 \(fanSummary) · \(canControl ? "可控" : "只读")"
    }

    var modeSwitchHint: String {
        if controlIssue != nil {
            return "先处理这个问题"
        }
        if canSwitchModes {
            return "可直接切换"
        }
        return "当前只读"
    }

    var canSwitchModes: Bool {
        canControl && controlIssue == nil
    }

    var canRestoreDefault: Bool {
        true
    }

    var decisionFacts: [MenuBarDecisionFact] {
        parseDecisionReason(decisionReason)
    }

    var recentSampleCards: [SampleCard] {
        recentSamples.suffix(5).enumerated().map { index, record in
            SampleCard(
                id: "\(record.timestamp.timeIntervalSince1970)-\(index)",
                label: record.source,
                value: "\(Int(record.thermalScore))",
                detail: sampleDetail(for: record),
                tint: sampleTint(for: record.thermalScore)
            )
        }
    }

    var recentEventCards: [EventCard] {
        recentEvents.suffix(4).enumerated().map { index, record in
            EventCard(
                id: "\(record.timestamp.timeIntervalSince1970)-\(index)",
                timeLabel: timeString(from: record.timestamp),
                title: eventTitle(for: record),
                detail: eventDetail(for: record),
                levelLabel: eventLevelLabel(for: record.level),
                tint: eventTint(for: record.level),
                icon: eventIcon(for: record.level, state: record.state)
            )
        }
    }

    var hasDecisionReason: Bool {
        normalizedDiagnosticReason(decisionReason) != nil
    }

    var hasRuntimeReason: Bool {
        normalizedDiagnosticReason(runtimeReason) != nil
    }

    var formattedDecisionReason: String {
        prettyPrintDiagnostic(reason: decisionReason)
    }

    var formattedRuntimeReason: String {
        prettyPrintDiagnostic(reason: runtimeReason)
    }

    var timestampLabel: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return "更新于 \(formatter.string(from: snapshotTimestamp))"
    }

    var footerLabel: String {
        "最近更新 · \(timestampLabel.replacingOccurrences(of: "更新于 ", with: ""))"
    }

    var modeStatusLabel: String {
        if state == "safetyFallback" {
            return "已交回系统控制"
        }
        if controlIssue != nil {
            return "受限"
        }
        if state == "manualDefault" {
            return "手动"
        }
        return "正常"
    }

    func isActive(mode: ThermalPolicy.Mode) -> Bool {
        self.mode == mode.rawValue
    }

    func sensorValueText(_ reading: SensorDisplayReading) -> String {
        guard let value = reading.valueC else { return "不可用" }
        return "\(Int(value))℃"
    }

    var recentSampleSummary: String {
        guard let last = recentSamples.last else {
            return "暂无记录"
        }
        return "最新 \(sampleDetail(for: last))"
    }

    var recentSampleTail: String {
        let tail = recentSamples.suffix(3).map { "\($0.source):\(Int($0.thermalScore))" }
        if tail.isEmpty {
            return "暂无"
        }
        return tail.joined(separator: " · ")
    }

    var recentEventSummary: String {
        guard let last = recentEvents.last else {
            return "暂无记录"
        }
        return "\(timeString(from: last.timestamp)) \(eventLevelLabel(for: last.level))"
    }

    var orderedSensorReadings: [SensorDisplayReading] {
        sensorReadings.sorted {
            if $0.available != $1.available {
                return $0.available && !$1.available
            }
            return ($0.valueC ?? -.infinity) > ($1.valueC ?? -.infinity)
        }
    }

    private func parseDecisionReason(_ reason: String) -> [MenuBarDecisionFact] {
        let parts = reason
            .split(separator: ";", omittingEmptySubsequences: true)
            .map(String.init)

        return parts.compactMap { part in
            let pieces = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2 else { return nil }
            let key = String(pieces[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(pieces[1]).trimmingCharacters(in: .whitespacesAndNewlines)
            return MenuBarDecisionFact(
                key: displayDecisionKey(key),
                value: value,
                tint: decisionTint(for: key)
            )
        }
    }

    private func prettyPrintDiagnostic(reason: String) -> String {
        guard let trimmed = normalizedDiagnosticReason(reason) else { return "暂无" }
        return trimmed
            .replacingOccurrences(of: ";", with: "\n")
            .replacingOccurrences(of: "=", with: " = ")
    }

    private func normalizedDiagnosticReason(_ reason: String) -> String? {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "init" else { return nil }
        return trimmed
    }

    private func displayDecisionKey(_ key: String) -> String {
        switch key {
        case "mode":
            return "模式"
        case "score":
            return "分数"
        case "band":
            return "区间"
        case "appBoost":
            return "App 触发"
        case "conservative":
            return "保守"
        case "external":
            return "外接屏"
        case "battery":
            return "供电"
        case "throttling":
            return "降频"
        case "temps":
            return "温度"
        default:
            return key
        }
    }

    private func decisionTint(for key: String) -> Color {
        switch key {
        case "score", "band":
            return .orange
        case "appBoost":
            return .green
        case "throttling":
            return .red
        case "battery":
            return .blue
        default:
            return .secondary
        }
    }

    private func sampleDetail(for record: TelemetrySampleRecord) -> String {
        "\(record.source) · \(record.reason)"
    }

    private func sampleTint(for score: Double) -> Color {
        switch score {
        case ..<31:
            return .green
        case 31..<61:
            return .blue
        case 61..<81:
            return .orange
        default:
            return .red
        }
    }

    private func timeString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private func eventLevelLabel(for level: String) -> String {
        switch level.lowercased() {
        case "error":
            return "错误"
        case "warn":
            return "警告"
        default:
            return "信息"
        }
    }

    private func eventTint(for level: String) -> Color {
        switch level.lowercased() {
        case "error":
            return .red
        case "warn":
            return .orange
        default:
            return .green
        }
    }

    private func eventIcon(for level: String, state: String) -> String {
        if level.lowercased() == "error" {
            return "exclamationmark.triangle.fill"
        }
        if state == "safetyFallback" {
            return "shield.lefthalf.filled"
        }
        if state == "safetyMode" {
            return "shield.fill"
        }
        if state == "manualDefault" {
            return "hand.raised.fill"
        }
        return "bolt.fill"
    }

    private func eventTitle(for record: TelemetryEventRecord) -> String {
        let stateLabel = eventStateLabel(record.state)
        return "\(stateLabel) · \(record.reason)"
    }

    private func eventDetail(for record: TelemetryEventRecord) -> String {
        guard !record.payload.isEmpty else { return "" }
        return record.payload
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key): \($0.value)" }
            .joined(separator: " · ")
    }

    private func eventStateLabel(_ state: String) -> String {
        switch state {
        case "smartControl":
            return "智能控制"
        case "safetyFallback":
            return "已交回系统控制"
        case "safetyMode":
            return "保护中"
        case "manualDefault":
            return "手动默认"
        case "discovering":
            return "识别中"
        case "idle":
            return "待机"
        default:
            return state
        }
    }
}
