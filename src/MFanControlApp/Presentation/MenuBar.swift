import Foundation
import MFanControlShared

public struct MenuBarViewModel {
    var currentTempC: Double?
    var tempStatusEmoji: String = "🟢"
    var controlStateEmoji: String = "⚪️"
    var availableSensorsCount: Int = 0
    var totalSensorsCount: Int = 0
    var hottestSensorLabel: String = "N/A"
    var currentRPM: Int = 0
    var targetRPM: Int = 0
    var mode: String = "balanced"
    var state: String = "idle"
    var source: String = "appleDefault"
    var thermalScore: Double = 0
    var reason: String = "init"
    var cpuThrottled: Bool = false
    var gpuThrottled: Bool = false
    var canControl: Bool = false
    var deviceLabel: String = "Unknown"
    var sensorReadings: [SensorDisplayReading] = []
}

#if canImport(AppKit)
import AppKit

public final class MenuBarController {
    private let coordinator: AppCoordinator
    private let menu: NSMenu
    private let statusItem: NSStatusItem

    public init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        self.menu = NSMenu(title: "MFanControl")
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    }

    public func start() {
        statusItem.menu = menu
        statusItem.button?.title = "🧊 MF"
        statusItem.button?.toolTip = "Apple Silicon Smart Thermal Manager"
        refresh()
    }

    public func stop() {
        statusItem.button?.isHidden = true
        statusItem.menu = nil
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
        button.title = statusTitle(for: model)
        button.toolTip = [
            "MFanControl",
            "设备: \(model.deviceLabel)",
            "状态: \(model.state) / \(model.source)",
            "模式: \(model.mode)",
            model.currentTempC.map { "最高温: \(Int($0))°C (\(model.hottestSensorLabel))" } ?? "最高温: 不可用"
        ].joined(separator: " ｜ ")

        rebuildMenu()

        menu.addItem(headerItem("🧠 MFanControl"))
        menu.addItem(NSMenuItem.separator())

        menu.addItem(infoItem("🖥 设备", "\(model.deviceLabel)"))
        menu.addItem(infoItem("🧭 状态", "\(model.state) / \(model.source)"))
        menu.addItem(infoItem("⚙️ 模式", menuLabel(for: model.mode)))
        menu.addItem(infoItem("🌡️ 最高温", hottestTemperatureText(model)))
        menu.addItem(infoItem("🌀 风扇", "\(model.currentRPM)rpm 目标\(model.targetRPM)rpm"))
        menu.addItem(infoItem("📈 热压力", "\(Int(model.thermalScore))"))
        menu.addItem(infoItem("🔧 降频", model.cpuThrottled || model.gpuThrottled ? "已触发（CPU: \(model.cpuThrottled ? "是" : "否"), GPU: \(model.gpuThrottled ? "是" : "否")）" : "未触发"))
        menu.addItem(infoItem("📡 传感器", "\(model.availableSensorsCount)/\(model.totalSensorsCount) 可用"))
        menu.addItem(infoItem("🔬 原因", model.reason))

        menu.addItem(NSMenuItem.separator())
        let sensors = NSMenuItem(title: "🌡️ 传感器明细", action: nil, keyEquivalent: "")
        sensors.submenu = NSMenu(title: "sensors")
        for reading in model.sensorReadings {
            let status = reading.available ? "✅" : "⚠️"
            let label = reading.label
            let text = reading.available
                ? "\(Int(reading.valueC ?? 0))℃"
                : "不可用 (\(reading.reason))"
            let detail = "\(status) \(label)：\(text)"
            let item = NSMenuItem(title: detail, action: nil, keyEquivalent: "")
            item.isEnabled = false
            sensors.submenu?.addItem(item)
        }
        menu.addItem(sensors)

        menu.addItem(NSMenuItem.separator())
        let modeMenu = NSMenuItem(title: "🎛️ 切换模式", action: nil, keyEquivalent: "")
        modeMenu.submenu = NSMenu(title: "mode")
        for mode in ThermalPolicy.Mode.allCases {
            let item = NSMenuItem(title: menuLabel(for: mode), action: #selector(didSelectMode(_:)), keyEquivalent: "")
            item.representedObject = mode.rawValue
            item.target = self
            item.isEnabled = model.canControl
            item.state = (coordinator.mode == mode) ? .on : .off
            modeMenu.submenu?.addItem(item)
        }
        menu.addItem(modeMenu)

        let restore = NSMenuItem(title: "♻️ 恢复 Apple 默认", action: #selector(didRestoreDefault), keyEquivalent: "r")
        restore.target = self
        menu.addItem(restore)

        menu.addItem(NSMenuItem.separator())
        let quit = NSMenuItem(title: "🚪 退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
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
        model.reason = command?.reason ?? snapshot.reason
        model.sensorReadings = coordinator.latestSensorReadings(availability: snapshot.sensorAvailability)

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
        model.controlStateEmoji = stateIcon(
            for: model.state,
            source: model.source,
            hasThrottle: model.cpuThrottled || model.gpuThrottled,
            canControl: model.canControl
        )
        if let temperature = model.currentTempC {
            model.tempStatusEmoji = temperatureBandEmoji(temperature)
        }

        let hardware = snapshot.hardwareProfile ?? coordinator.hardwareProfile
        model.deviceLabel = "\(hardware.chip) / \(hardware.deviceModel)"
        return model
    }

    private func statusTitle(for model: MenuBarViewModel) -> String {
        guard model.canControl else { return "MFanControl" }
        guard let temp = model.currentTempC else {
            return "\(model.controlStateEmoji) N/A"
        }
        return "\(model.tempStatusEmoji) \(String(format: "%.0f°", temp))"
    }

    private func rebuildMenu() {
        while menu.numberOfItems > 0 {
            menu.removeItem(at: 0)
        }
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

    private func menuLabel(for modeName: String) -> String {
        let translated = menuLabel(for: ThermalPolicy.Mode(rawValue: modeName) ?? .balanced)
        return translated
    }

    private func infoItem(_ title: String, _ value: String) -> NSMenuItem {
        NSMenuItem(title: "\(title)：\(value)", action: nil, keyEquivalent: "")
    }

    private func headerItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func hottestTemperatureText(_ model: MenuBarViewModel) -> String {
        guard let temp = model.currentTempC else {
            return "不可用"
        }
        return "\(model.hottestSensorLabel) \(Int(temp))℃"
    }

    private func stateIcon(for state: String, source: String, hasThrottle: Bool, canControl: Bool) -> String {
        if hasThrottle {
            return "🟠"
        }
        if !canControl {
            return "⚪️"
        }
        if state == "safetyFallback" || state == "manualDefault" {
            return "🛑"
        }
        if source == "safetyMode" {
            return "🔶"
        }
        if state == "smartControl" {
            return "🟢"
        }
        return "🔵"
    }

    private func temperatureBandEmoji(_ temp: Double) -> String {
        switch Int(temp) {
        case ..<70:
            return "🟢"
        case 70..<80:
            return "🟡"
        case 80..<90:
            return "🟠"
        default:
            return "🔴"
        }
    }
}
#endif
