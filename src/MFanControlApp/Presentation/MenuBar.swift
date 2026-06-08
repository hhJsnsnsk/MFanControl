import Foundation
import MFanControlShared

public struct MenuBarViewModel {
    var currentTempC: Double?
    var availableSensorsCount: Int = 0
    var totalSensorsCount: Int = 0
    var hottestSensorLabel: String = "N/A"
    var currentRPM: Int = 0
    var targetRPM: Int = 0
    var mode: String = "balanced"
    var state: String = "idle"
    var source: String = "appleDefault"
    var controlIssue: String?
    var runtimeReason: String = "init"
    var decisionReason: String = "init"
    var thermalScore: Double = 0
    var cpuThrottled: Bool = false
    var gpuThrottled: Bool = false
    var canControl: Bool = false
    var deviceLabel: String = "Unknown"
    var powerSource: String = "unknown"
    var appBoostActive: Bool = false
    var fanCount: Int = 0
    var fanMinRPM: Int = 0
    var fanMaxRPM: Int = 0
    var snapshotTimestamp: Date = .init()
    var sensorReadings: [SensorDisplayReading] = []
    var recentSamples: [TelemetrySampleRecord] = []
    var recentEvents: [TelemetryEventRecord] = []
    var configSummary: String = "未读取配置"
    var stateReadable: String = "待机"
}

#if canImport(AppKit)
import AppKit
#if canImport(SwiftUI)
import SwiftUI
#endif

private enum Style {
    static let statusFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
    static let rowFont = NSFont.systemFont(ofSize: 9.2, weight: .regular)
    static let bodyFont = NSFont.systemFont(ofSize: 9.1, weight: .medium)
    static let rowValueFont = NSFont.monospacedDigitSystemFont(ofSize: 9.8, weight: .semibold)
    static let compactValueFont = NSFont.systemFont(ofSize: 9, weight: .regular)
    static let sectionTitleFont = NSFont.systemFont(ofSize: 8.6, weight: .medium)
    static let statusBarLength: CGFloat = NSStatusItem.squareLength
    static let statusImageSize: CGFloat = 11
    static let statusImageName = "fan.fill"
    static let fallbackStatusImageName = "fan"
    static let accentGreen = NSColor.systemGreen
    static let accentOrange = NSColor.systemOrange
    static let accentBlue = NSColor.systemBlue
    static let accentRed = NSColor.systemRed
    static let menuTitleFont = NSFont.systemFont(ofSize: 9.2, weight: .medium)
    static let actionFont = NSFont.systemFont(ofSize: 9.4, weight: .regular)
    static let subtleValueColor = NSColor.tertiaryLabelColor
}

public final class MenuBarController {
    private let coordinator: AppCoordinator
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private var hostingController: NSHostingController<MenuBarPopoverView>?

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        self.statusItem = NSStatusBar.system.statusItem(withLength: Style.statusBarLength)
        self.popover = NSPopover()
        self.popover.behavior = .transient
        self.popover.animates = true
        self.popover.contentSize = NSSize(width: 424, height: 720)
    }

    public func start() {
        if let button = statusItem.button {
            button.title = ""
            button.imagePosition = .imageOnly
            button.image = nil
            button.imageScaling = .scaleProportionallyDown
            button.font = NSFont.menuBarFont(ofSize: 0)
            button.alignment = .center
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp])
            if #available(macOS 11.0, *) {
                button.contentTintColor = .white
            }
        }
        statusItem.button?.toolTip = "MFanControl"
        refresh()
    }

    public func stop() {
        closePopover()
        statusItem.button?.isHidden = true
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    public func refresh() {
        let snapshot = coordinator.currentStateSnapshot()
        let command = coordinator.lastCommand
        refresh(using: snapshot, command: command)
    }

    public func refresh(using snapshot: FanControlSnapshot, command: ControlCommand?) {
        guard let button = statusItem.button else { return }

        let model = model(from: snapshot, command: command)
        applyCompactStatusPresentation(to: button, model: model)
        button.toolTip = [
            "MFanControl · Apple Silicon 智能热管理",
            "设备: \(model.deviceLabel)",
            "状态: \(model.stateReadable)",
            "峰值: \(sensorLabelWithTemperature(model))",
            "风扇: \(model.currentRPM)/\(model.targetRPM) rpm",
            "模式: \(menuLabel(for: model.mode))",
            "传感器: \(model.availableSensorsCount)/\(model.totalSensorsCount)",
            "控制链路: \(model.controlIssue ?? "正常")"
        ].joined(separator: " ｜ ")
        updatePopoverContent(with: model)
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            closePopover()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func closePopover() {
        if popover.isShown {
            popover.performClose(nil)
        }
    }

    private func updatePopoverContent(with model: MenuBarViewModel) {
        let content = MenuBarPopoverView(
            model: model,
            onSelectMode: { [weak self] mode in
                self?.coordinator.setMode(mode)
                self?.refresh()
            },
            onRestoreDefault: { [weak self] in
                self?.coordinator.stop()
                self?.refresh()
            },
            onRefresh: { [weak self] in
                self?.refresh()
            },
            onClose: { [weak self] in
                self?.closePopover()
            }
        )

        if let hostingController {
            hostingController.rootView = content
        } else {
            let controller = NSHostingController(rootView: content)
            controller.view.translatesAutoresizingMaskIntoConstraints = false
            hostingController = controller
            popover.contentViewController = controller
        }
    }

    @objc private func didSelectMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = ThermalPolicy.Mode(rawValue: raw) else { return }
        coordinator.setMode(mode)
        refresh()
    }

    @objc private func didRestoreDefault() {
        coordinator.stop()
        refresh()
    }

    private func model(from snapshot: FanControlSnapshot, command: ControlCommand?) -> MenuBarViewModel {
        var model = MenuBarViewModel()
        model.currentRPM = snapshot.currentRPM
        model.targetRPM = snapshot.targetRPM
        model.mode = snapshot.activeProfile
        model.state = snapshot.state.rawValue
        model.source = snapshot.source.rawValue
        model.thermalScore = snapshot.thermalScore ?? 0
        model.canControl = snapshot.hardwareProfile?.fans.contains(where: { $0.controllable }) ?? false
        model.sensorReadings = coordinator.latestSensorReadings(availability: snapshot.sensorAvailability)
        model.powerSource = snapshot.powerSource
        model.appBoostActive = snapshot.appBoostActive
        model.runtimeReason = command?.reason ?? snapshot.reason
        model.decisionReason = coordinator.currentDecisionReason()
        model.snapshotTimestamp = snapshot.timestamp
        model.recentSamples = coordinator.recentTelemetrySamples(limit: 8)
        model.recentEvents = coordinator.recentTelemetryEvents(limit: 4)
        let config = coordinator.exportConfig()
        model.configSummary = [
            "策略 \(menuLabel(for: ThermalPolicy.Mode(rawValue: config.profile) ?? .balanced))",
            "白名单 \(config.whiteList.count) 项",
            "阈值 \(Int(config.safetyThresholds.thermalSafetyScore))",
            "采样 \(Int(config.safetyThresholds.sampleIntervalSec))s"
        ].joined(separator: " · ")
        if let fans = snapshot.hardwareProfile?.fans, !fans.isEmpty {
            model.fanCount = fans.reduce(0) { partialResult, fan in
                partialResult + max(1, fan.fanCount)
            }
            model.fanMinRPM = fans.map(\.minRPM).min() ?? 0
            model.fanMaxRPM = fans.map(\.maxRPM).max() ?? 0
        }

        if let hottest = model.sensorReadings
            .filter({ $0.available })
            .max(by: { ($0.valueC ?? -.infinity) < ($1.valueC ?? -.infinity) }) {
            model.currentTempC = hottest.valueC
            model.hottestSensorLabel = hottest.label
        }

        model.cpuThrottled = snapshot.throttleState.cpuThermalThrottled
        model.gpuThrottled = snapshot.throttleState.gpuThermalThrottled
        model.availableSensorsCount = model.sensorReadings.filter(\.available).count
        model.totalSensorsCount = model.sensorReadings.count

        let hardware = snapshot.hardwareProfile ?? coordinator.hardwareProfile
        model.deviceLabel = "\(hardware.chip) / \(hardware.deviceModel)"
        model.stateReadable = stateReadableLabel(
            state: model.state,
            source: model.source,
            hasThrottle: model.cpuThrottled || model.gpuThrottled,
            canControl: model.canControl
        )
        model.controlIssue = self.controlIssue(from: command?.reason ?? snapshot.reason)
        return model
    }

    private func controlIssue(from reason: String) -> String? {
        let raw = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty || raw == "init" {
            return nil
        }
        let normalized = raw.lowercased()
        if normalized.contains("safety-fallback") {
            return "已交回系统控制"
        }
        if normalized.contains("iokit-call-failed") {
            return "SMC 写入参数错误"
        }
        if normalized.contains("smc-write-failed") || normalized.contains("iokit") || normalized.contains("smc-not-found") {
            return "SMC 写入通道失败"
        }
        if normalized.contains("sensor-fault") || normalized.contains("sensor-critical") {
            return "传感器异常"
        }
        if normalized.contains("apply-failed") {
            return raw.replacingOccurrences(of: "apply-failed:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private func statusIssueItem(_ issue: String) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let prefix = "警告: "
        let displayIssue = trim(issue, to: 26)
        let full = "\(prefix)\(displayIssue)"
        let attributed = NSMutableAttributedString(string: full)
        attributed.addAttributes(
            [.font: Style.rowValueFont, .foregroundColor: NSColor.systemRed],
            range: NSRange(location: 0, length: (prefix as NSString).length)
        )
        attributed.addAttributes(
            [.font: Style.rowValueFont, .foregroundColor: NSColor.labelColor],
            range: NSRange(location: (prefix as NSString).length, length: (displayIssue as NSString).length)
        )
        item.attributedTitle = attributed
        item.isEnabled = false
        return item
    }

    private func applyCompactStatusPresentation(to button: NSStatusBarButton, model: MenuBarViewModel) {
        button.image = statusSystemImage(for: model)
        button.imagePosition = .imageOnly
        button.image?.isTemplate = true
        button.image?.size = NSSize(width: Style.statusImageSize, height: Style.statusImageSize)
        button.attributedTitle = NSAttributedString(string: "", attributes: [.font: Style.statusFont])
        if #available(macOS 11.0, *) {
            button.contentTintColor = .white
        }
    }

    private func statusSystemImage(for model: MenuBarViewModel) -> NSImage {
        let symbolName = statusSymbolName(for: model)
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "MFanControl") {
            return image
        }
        return fallbackDotImage()
    }

    private func statusSymbolName(for model: MenuBarViewModel) -> String {
        if !model.canControl {
            return "slash.circle.fill"
        }
        if model.state == "safetyFallback" || model.controlIssue != nil {
            return "exclamationmark.triangle.fill"
        }
        if model.state == "manualDefault" {
            return "hand.raised.fill"
        }
        if model.cpuThrottled || model.gpuThrottled {
            return "thermometer.medium"
        }
        if model.appBoostActive {
            return "bolt.fill"
        }
        switch model.mode {
        case "quiet":
            return "moon.stars.fill"
        case "performance":
            return "speedometer"
        case "balanced":
            return Style.statusImageName
        case "customCurve":
            return "chart.line.uptrend.xyaxis"
        default:
            return Style.statusImageName
        }
    }

    private func fallbackDotImage() -> NSImage {
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size)
        image.lockFocus()
        let inset: CGFloat = 2
        let rect = CGRect(x: inset, y: inset, width: size.width - inset * 2, height: size.height - inset * 2)
        let path = NSBezierPath(ovalIn: rect)
        NSColor.labelColor.setFill()
        path.fill()
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    private func sensorLabelWithTemperature(_ model: MenuBarViewModel) -> String {
        guard let temp = model.currentTempC else {
            return "\(trim(model.hottestSensorLabel, to: 10)) 不可用"
        }
        return "\(trim(model.hottestSensorLabel, to: 10)) \(Int(temp))℃"
    }

    private func menuLabel(for mode: ThermalPolicy.Mode) -> String {
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

    private func modeDisplayName(for modeName: String) -> String {
        guard let mode = ThermalPolicy.Mode(rawValue: modeName) else {
            return "未知"
        }
        switch mode {
        case .quiet:
            return "静音"
        case .balanced:
            return "均衡"
        case .performance:
            return "性能"
        case .customCurve:
            return "自定义"
        }
    }

    private func menuLabel(for mode: String) -> String {
        let translated = menuLabel(for: ThermalPolicy.Mode(rawValue: mode) ?? .balanced)
        return translated
    }

    private func makeActionItem(title: String, action: Selector, keyEquivalent: String, tint: NSColor) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: action, keyEquivalent: keyEquivalent)
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: Style.actionFont,
                .foregroundColor: tint
            ]
        )
        item.target = self
        return item
    }

    private func sectionTitleItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let full = "• \(title)"
        let attr = NSMutableAttributedString(string: full)
        attr.addAttributes(
            [.font: Style.sectionTitleFont, .foregroundColor: Style.subtleValueColor],
            range: NSRange(location: 0, length: (full as NSString).length)
        )
        item.attributedTitle = attr
        item.isEnabled = false
        return item
    }

    private func brandItem(for model: MenuBarViewModel) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let title = "MFanControl"
        let shortState = stateTag(model.stateReadable)
        let stateSuffix = "· \(shortState)"
        let full = "\(title) \(stateSuffix)"
        let stateColor = model.canControl ? NSColor.secondaryLabelColor : Style.accentOrange
        let attr = NSMutableAttributedString(string: full)
        let titleLen = (title as NSString).length
        let suffixLen = (stateSuffix as NSString).length
        let stateTextRange = (stateSuffix as NSString).range(of: shortState)

        attr.addAttributes(
            [.font: Style.rowValueFont, .foregroundColor: NSColor.labelColor],
            range: NSRange(location: 0, length: titleLen)
        )
        attr.addAttributes(
            [.font: Style.compactValueFont, .foregroundColor: NSColor.secondaryLabelColor],
            range: NSRange(location: titleLen, length: suffixLen)
        )
        if model.controlIssue != nil {
            attr.addAttributes(
                [.font: Style.compactValueFont, .foregroundColor: NSColor.systemRed],
                range: stateTextRange.location == NSNotFound
                ? NSRange(location: titleLen, length: max(0, suffixLen))
                : NSRange(location: titleLen + stateTextRange.location, length: max(0, stateTextRange.length))
            )
        } else {
            attr.addAttributes(
                [.foregroundColor: stateColor],
                range: stateTextRange.location == NSNotFound
                ? NSRange(location: titleLen, length: max(0, suffixLen))
                : NSRange(location: titleLen + stateTextRange.location, length: max(0, stateTextRange.length))
            )
        }
        item.attributedTitle = attr
        item.isEnabled = false
        return item
    }

    private func compactInfoItem(
        leftTitle: String,
        leftValue: String,
        rightTitle: String,
        rightValue: String,
        leftTitleColor: NSColor = NSColor.tertiaryLabelColor,
        rightTitleColor: NSColor = NSColor.tertiaryLabelColor,
        leftValueColor: NSColor = NSColor.labelColor,
        rightValueColor: NSColor = NSColor.labelColor
        ) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let leftHead = leftTitle
        let rightHead = rightTitle
        let leftValueText = trim(leftValue, to: 12)
        let rightValueText = trim(rightValue, to: 12)
        let filler = "   "
        let full = "\(leftHead) \(leftValueText)\(filler)\(rightHead) \(rightValueText)"
        let attributed = NSMutableAttributedString(string: full)

        let leftHeadLen = (leftHead as NSString).length
        let separatorLen = (filler as NSString).length
        let rightHeadLen = (rightHead as NSString).length + 1
        let leftHeadRange = NSRange(location: 0, length: leftHeadLen)
        let leftValueRange = NSRange(location: leftHeadLen + 1, length: leftValueText.count)
        let separatorRange = NSRange(location: leftHeadLen + 1 + leftValueText.count, length: separatorLen)
        let rightHeadRange = NSRange(location: leftHeadLen + 1 + leftValueText.count + separatorLen, length: rightHeadLen)
        let rightValueRange = NSRange(
            location: leftHeadLen + 1 + leftValueText.count + separatorLen + rightHeadLen,
            length: rightValueText.count
        )

        attributed.addAttributes(
            [.font: Style.bodyFont, .foregroundColor: leftTitleColor],
            range: leftHeadRange
        )
        attributed.addAttributes(
            [.font: Style.bodyFont, .foregroundColor: leftValueColor],
            range: leftValueRange
        )
        attributed.addAttributes(
            [.font: Style.compactValueFont, .foregroundColor: Style.subtleValueColor],
            range: separatorRange
        )
        attributed.addAttributes(
            [.font: Style.bodyFont, .foregroundColor: rightTitleColor],
            range: rightHeadRange
        )
        attributed.addAttributes(
            [.font: Style.bodyFont, .foregroundColor: rightValueColor],
            range: rightValueRange
        )

        item.attributedTitle = attributed
        item.isEnabled = false
        return item
    }

    private func modeMenuLabel(mode: String, isActive: Bool, enabled: Bool) -> NSAttributedString {
        let dot = isActive ? "●" : "○"
        let text = "\(dot) \(mode)"
        let color: NSColor
        if !enabled {
            color = Style.subtleValueColor
        } else if isActive {
            color = Style.accentGreen
        } else {
            color = NSColor.labelColor
        }
        return NSAttributedString(
            string: text,
            attributes: [
                .font: Style.rowFont,
                .foregroundColor: color
            ]
        )
    }

    private func fanRatioColor(currentRPM: Int, targetRPM: Int) -> NSColor {
        let ratio = targetRPM > 0 ? Double(currentRPM) / Double(max(1, targetRPM)) : 0
        switch ratio {
        case ..<0.45:
            return .systemGreen
        case ..<0.75:
            return .systemYellow
        case ..<0.95:
            return .systemOrange
        default:
            return .systemRed
        }
    }

    private func trim(_ input: String, to maxLength: Int) -> String {
        let normalized = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.count <= maxLength {
            return normalized
        }
        return String(normalized.prefix(maxLength - 1)) + "…"
    }

    private func compactSensorMenuTitle(_ readings: [SensorDisplayReading]) -> NSAttributedString {
        let total = readings.count
        let unavailable = readings.filter { !$0.available }.count
        let available = total - unavailable
        let hottest = readings
            .filter({ $0.available })
            .sorted { ($0.valueC ?? -.infinity) > ($1.valueC ?? -.infinity) }
            .first
        let text = total == 0
            ? "传感器无可用"
            : "传感器 \(available)/\(total) · \(hottest.flatMap { "\(trim($0.label, to: 4)) \(Int($0.valueC ?? 0))℃" } ?? "无可用数据")"
        return NSAttributedString(
            string: text,
            attributes: [
                .font: Style.rowFont,
                .foregroundColor: NSColor.labelColor
            ]
        )
    }

    private func buildCompactSensorSubmenu(_ readings: [SensorDisplayReading]) -> NSMenu {
        let menu = NSMenu(title: "sensors")
        let ordered = readings.sorted {
            if $0.available != $1.available {
                return $0.available
            }
            return ($0.valueC ?? -.infinity) > ($1.valueC ?? -.infinity)
        }
        for reading in ordered {
            menu.addItem(sensorDetailItem(reading))
        }
        if readings.isEmpty {
            let none = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            let noneText = NSAttributedString(
                string: "暂无传感器数据",
                attributes: [
                    .font: Style.compactValueFont,
                    .foregroundColor: NSColor.tertiaryLabelColor
                ]
            )
            none.attributedTitle = noneText
            none.isEnabled = false
            menu.addItem(none)
        }
        return menu
    }

    private func hottestTemperatureText(_ model: MenuBarViewModel) -> String {
        guard let temp = model.currentTempC else {
            return "不可用"
        }
        return "\(Int(temp))℃"
    }

    private func sensorLabelCompact(for label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 6 {
            return trimmed
        }
        return String(trimmed.prefix(5)) + "…"
    }

    private func sensorDetailItem(_ reading: SensorDisplayReading) -> NSMenuItem {
        let status = reading.available ? "◉" : "◌"
        let statusColor = reading.available ? NSColor.systemGreen : NSColor.tertiaryLabelColor
        let label = sensorLabelCompact(for: reading.label)
        let text = reading.available
            ? "\(Int(reading.valueC ?? 0))℃"
            : "不可用"
        let suffix = reading.available ? "" : " · \(reading.reason)"
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let prefix = "\(status) \(label) "
        let valueText = "\(text)\(suffix)"
        let full = "\(prefix)\(valueText)"
        let valueColor = reading.available
            ? temperatureColor(for: reading.valueC ?? 0)
            : NSColor.tertiaryLabelColor

        let attr = NSMutableAttributedString(string: full)
        attr.addAttributes(
            [.font: Style.rowValueFont, .foregroundColor: statusColor],
            range: NSRange(location: 0, length: (status as NSString).length)
        )
        attr.addAttributes(
            [.font: Style.rowFont, .foregroundColor: NSColor.secondaryLabelColor],
            range: NSRange(location: (status as NSString).length, length: max(0, (prefix as NSString).length - (status as NSString).length))
        )
        attr.addAttributes(
            [.font: Style.rowValueFont, .foregroundColor: valueColor],
            range: NSRange(location: (prefix as NSString).length, length: max(0, (valueText as NSString).length))
        )
        item.attributedTitle = attr
        item.isEnabled = false
        return item
    }

    private func temperatureColor(for temp: Double) -> NSColor {
        switch temp {
        case ..<55:
            return .systemGreen
        case 55..<70:
            return .systemYellow
        case 70..<80:
            return .systemOrange
        default:
            return .systemRed
        }
    }

    private func stateReadableLabel(state: String, source: String, hasThrottle: Bool, canControl: Bool) -> String {
        if !canControl {
            return "不可控"
        }
        if state == "safetyFallback" {
            return "已交回系统控制"
        }
        if state == "manualDefault" {
            return "手动默认"
        }
        if hasThrottle {
            return "降频保护"
        }
        if source == "safetyMode" {
            return "保护中"
        }
        if state == "smartControl" {
            return "智能控制"
        }
        if state == "manualDefault" {
            return "手动控制"
        }
        if state == "idle" {
            return "待机"
        }
        if state == "running" || state == "active" {
            return "运行中"
        }
        return state
    }

    private func stateTag(_ readableState: String) -> String {
        switch readableState {
        case "待机":
            return "待"
        case "智能控制":
            return "智"
        case "已交回系统控制":
            return "交"
        case "保护中":
            return "保"
        case "手动默认", "手动控制":
            return "手"
        case "降频保护":
            return "限"
        case "运行中":
            return "运"
        case "不可控":
            return "断"
        default:
            return readableState
        }
    }

}
#endif
