import Foundation
import MFanControlShared

public struct MenuBarViewModel {
    var currentTempC: Double?
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
        statusItem.button?.title = "MF"
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

        rebuildMenu()

        let header = NSMenuItem(title: "MFanControl", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "设备: \(model.deviceLabel)", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "状态: \(model.state) / \(model.source)", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "模式: \(model.mode)", action: nil, keyEquivalent: ""))
        if let temp = model.currentTempC {
            menu.addItem(NSMenuItem(title: "最高温度: \(model.hottestSensorLabel) \(Int(temp))℃", action: nil, keyEquivalent: ""))
        } else {
            menu.addItem(NSMenuItem(title: "最高温度: 不可用", action: nil, keyEquivalent: ""))
        }
        menu.addItem(NSMenuItem(title: "RPM: \(model.currentRPM) (目标 \(model.targetRPM))", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "热压力: \(Int(model.thermalScore))", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "降频: CPU \(model.cpuThrottled ? "是" : "否"), GPU \(model.gpuThrottled ? "是" : "否")", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "原因: \(model.reason)", action: nil, keyEquivalent: ""))

        menu.addItem(NSMenuItem.separator())
        let sensors = NSMenuItem(title: "传感器温度", action: nil, keyEquivalent: "")
        sensors.submenu = NSMenu(title: "sensors")
        for reading in model.sensorReadings {
            let title: String
            if reading.available, let value = reading.valueC {
                title = "\(reading.label): \(Int(value))℃"
            } else {
                title = "\(reading.label): 不可用 (\(reading.reason))"
            }
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            sensors.submenu?.addItem(item)
        }
        menu.addItem(sensors)

        menu.addItem(NSMenuItem.separator())
        let modeMenu = NSMenuItem(title: "切换模式", action: nil, keyEquivalent: "")
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

        let restore = NSMenuItem(title: "恢复 Apple 默认", action: #selector(didRestoreDefault), keyEquivalent: "r")
        restore.target = self
        menu.addItem(restore)

        menu.addItem(NSMenuItem.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
        if let hottest = model.sensorReadings.filter({ $0.available }).max(by: { ($0.valueC ?? -.infinity) < ($1.valueC ?? -.infinity) }) {
            model.currentTempC = hottest.valueC
            model.hottestSensorLabel = hottest.label
        }
        model.cpuThrottled = snapshot.throttleState.cpuThermalThrottled
        model.gpuThrottled = snapshot.throttleState.gpuThermalThrottled

        let hardware = snapshot.hardwareProfile ?? coordinator.hardwareProfile
        model.deviceLabel = "\(hardware.chip) / \(hardware.deviceModel)"

        return model
    }

    private func statusTitle(for model: MenuBarViewModel) -> String {
        guard model.canControl else { return "MFanControl" }
        guard let temp = model.currentTempC else {
            return "N/A"
        }
        return String(format: "%.0f°", temp)
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
}
#endif
