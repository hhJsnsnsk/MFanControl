import Foundation
import MFanControlHelperCore

private var activeListener: FanControlXPCListener?

private func terminationSignalHandler(_ signal: Int32) {
    FanControlDaemon.shared.recoverSafetyDefaults()
    activeListener?.stop()
    exit(0)
}

@main
struct MFanControlHelperMain {
    private static var listenerInstance: FanControlXPCListener?

    static func main() {
        let daemon = FanControlDaemon.shared
        daemon.start()

        installSignalHandlers()

        var listener: FanControlXPCListener?
        if ProcessInfo.processInfo.environment[FanControlXPCDefaults.useRemoteEnv] == "1" {
            let serviceName = ProcessInfo.processInfo.environment["MFANCONTROL_XPC_SERVICE_NAME"]
                ?? FanControlXPCDefaults.serviceName
            listener = FanControlXPCListener(serviceName: serviceName)
            listenerInstance = listener
            activeListener = listener
            listener?.start()
        }

        RunLoop.main.run()
    }

    private static func installSignalHandlers() {
        signal(SIGINT, terminationSignalHandler)
        signal(SIGTERM, terminationSignalHandler)
        signal(SIGQUIT, terminationSignalHandler)
    }
}
