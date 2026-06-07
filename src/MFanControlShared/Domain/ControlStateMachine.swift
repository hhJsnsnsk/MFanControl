import Foundation

public struct ControlStateMachine {
    public var state: ControlState
    public var source: ControlSource
    public var activeMode: ThermalPolicy.Mode
    public var isControllable: Bool

    public init(
        state: ControlState = .idle,
        source: ControlSource = .appleDefault,
        activeMode: ThermalPolicy.Mode = .balanced,
        isControllable: Bool = false
    ) {
        self.state = state
        self.source = source
        self.activeMode = activeMode
        self.isControllable = isControllable
    }

    public mutating func apply(event: ControlEvent, hardwareProfile: HardwareProfile? = nil) -> String {
        let previous = state
        switch event {
        case .discovered:
            if let profile = hardwareProfile {
                isControllable = profile.isAppleSilicon
                    && profile.hasFans
                    && profile.fans.contains(where: { $0.controllable })
                if isControllable {
                    state = .smartControl
                    source = .appAuto
                } else {
                    state = .idle
                    source = .appleDefault
                }
            } else {
                isControllable = false
                state = .idle
                source = .appleDefault
            }

        case .helperUnavailable, .sensorFault, .safetyTriggered:
            state = .safetyFallback
            source = .safetyMode

        case .manualDefault:
            state = .manualDefault
            source = .userManual

        case .helperRecovered, .systemEvent:
            if state == .safetyFallback || state == .manualDefault || state == .discovering {
                state = .discovering
                source = .appleDefault
            }

        case .systemWake:
            if state == .safetyFallback || state == .manualDefault || state == .idle {
                state = .discovering
                source = .appleDefault
            }

        case .systemSleep:
            if state == .smartControl {
                state = .manualDefault
                source = .userManual
            }

        case .sensorRecovered, .safetyRecovered:
            if state == .safetyFallback {
                state = .discovering
                source = .appleDefault
            }

        case .appBoostStart, .appBoostStop:
            if state == .idle {
                state = .discovering
                source = .appAuto
            }

        case .userModeChange:
            if state == .idle || state == .manualDefault {
                state = .discovering
                source = .appAuto
            }
        }

        return "\(event.rawValue):\(previous.rawValue)->\(state.rawValue)"
    }

    public mutating func setMode(_ mode: ThermalPolicy.Mode) {
        activeMode = mode
    }
}
