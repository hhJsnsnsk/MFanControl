import Foundation
import MFanControlShared

enum HelperMode: String {
    case running
    case fallback
}

final class HelperDaemon {
    func start() {
        print("MFanControlHelper daemon start")
    }
}

let daemon = HelperDaemon()
daemon.start()
