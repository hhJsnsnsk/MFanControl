import Foundation
import MFanControlShared

final class AppCoordinator {
    private(set) var state: ControlState = .idle

    func start() {
        state = .discovering
    }

    func stop() {
        state = .manualDefault
    }
}
