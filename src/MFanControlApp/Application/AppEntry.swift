import Foundation
import MFanControlShared
#if canImport(AppKit)
import AppKit
#endif

public enum MFanControlAppEntry {
    static func main() {
        let coordinator = AppCoordinator()
        coordinator.start()

        #if canImport(AppKit)
        terminateDuplicateMenuInstances()

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.activate(ignoringOtherApps: true)

        var menuBar: MenuBarController?
        let loop = AppLifecycleLoop(coordinator: coordinator) { _, snapshot in
            let command = coordinator.lastCommand
            DispatchQueue.main.async {
                menuBar?.refresh(using: snapshot, command: command)
            }
        }
        menuBar = MenuBarController(coordinator: coordinator)
        menuBar?.start()

        loop.start(runLoop: false)
        app.run()

        menuBar?.stop()
        loop.stop()
        #else
        let loop = AppLifecycleLoop(coordinator: coordinator)
        loop.start()
        #endif
    }

    private static func terminateDuplicateMenuInstances() {
        #if canImport(AppKit)
        guard let bundleID = Bundle.main.bundleIdentifier else {
            return
        }
        let currentPID = Int32(ProcessInfo.processInfo.processIdentifier)
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier == bundleID && $0.processIdentifier != currentPID
        }
        for app in running {
            app.terminate()
        }
        #endif
    }
}

final class AppLifecycleLoop {
    private let coordinator: AppCoordinator
    private let tickInterval: TimeInterval
    private let onTick: ((ControlCommand, FanControlSnapshot) -> Void)?
    private var notifications: [NSObjectProtocol] = []
    private var timer: Timer?
    private var timerSource: DispatchSourceTimer?

    init(
        coordinator: AppCoordinator,
        tickInterval: TimeInterval = 2.0,
        tickHandler: ((ControlCommand, FanControlSnapshot) -> Void)? = nil
    ) {
        self.coordinator = coordinator
        self.tickInterval = tickInterval
        self.onTick = tickHandler
    }

    func start(runLoop: Bool = true) {
        #if canImport(AppKit)
        let workspace = NSWorkspace.shared
        notifications.append(
            workspace.notificationCenter.addObserver(
                forName: NSWorkspace.willSleepNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.coordinator.handleSystemSleep()
            }
        )
        notifications.append(
            workspace.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.coordinator.handleSystemWake()
            }
        )

        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + tickInterval, repeating: tickInterval, leeway: .milliseconds(100))
        source.setEventHandler { [weak self] in
            self?.tick()
        }
        source.resume()
        timerSource = source

        guard runLoop else {
            return
        }
        RunLoop.main.run()
        #else
        for i in 0..<5 {
            tick()
            print("Tick \(i): mode=\(coordinator.mode.rawValue) state=\(coordinator.state.rawValue) rpm=\(coordinator.activeRPM) reason=\(coordinator.currentDecisionReason())")
        }
        #endif
    }

    func stop() {
        timerSource?.cancel()
        timerSource = nil
        #if !canImport(AppKit)
        timer?.invalidate()
        timer = nil
        #endif
        for token in notifications {
            #if canImport(AppKit)
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            #endif
        }
        notifications.removeAll()
    }

    private func tick() {
        let command = coordinator.evaluate()
        let snapshot = coordinator.currentStateSnapshot()
        onTick?(command, snapshot)
        #if !canImport(AppKit)
        print("Tick: mode=\(coordinator.mode.rawValue) state=\(coordinator.state.rawValue) rpm=\(coordinator.activeRPM) reason=\(coordinator.currentDecisionReason())")
        #endif
    }
}
