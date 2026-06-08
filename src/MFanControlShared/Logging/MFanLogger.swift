import Foundation

public enum MFanLogger {
    public static var isEnabled: Bool = false

    public static func log(_ message: @autoclosure () -> String, file: StaticString = #file, line: UInt = #line) {
        guard isEnabled else { return }
        let filename = (String(describing: file) as NSString).lastPathComponent
        print("[\(filename):\(line)] \(message())")
    }
}
