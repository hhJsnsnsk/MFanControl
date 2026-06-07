import Foundation

enum SMCKeyCatalog {
    static let cpuCoreTemp = "TC0P"
    static let cpuClusterTemp = "TC0H"
    static let gpuTemp = "TG0P"
    static let socTemp = "TSOC"

    static func fanTargetRPMKey(for fanIndex: Int) -> String {
        "F\(max(0, fanIndex))Tg"
    }

    static func fanMinRPMKey(for fanIndex: Int) -> String {
        "F\(max(0, fanIndex))Mn"
    }

    static func fanMaxRPMKey(for fanIndex: Int) -> String {
        "F\(max(0, fanIndex))Mx"
    }

    static func fanCurrentRPMKey(for fanIndex: Int) -> String {
        "F\(max(0, fanIndex))Ac"
    }

    static let fanMinRPM = "F0Mn"
    static let fanMaxRPM = "F0Mx"
    static let fanCurrentRPM = "F0Ac"
}
