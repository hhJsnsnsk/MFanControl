import Foundation

public enum HardwareDiscovery {
    public static func detect() -> HardwareProfile {
        let chip = detectChip()
        let model = detectModel()
        let modelCategory = modelCategory(model)
        let normalizedChip = normalizeChipLabel(chip)
        let isAppleSilicon = chip.contains("Apple")
        let hasFans = detectHasFans(model: model, isAppleSilicon: isAppleSilicon)
        let fanRPMRange = fanRange(for: modelCategory)
        let fanCount = fanCount(for: modelCategory, chip: normalizedChip)

        let minRPM = hasFans ? fanRPMRange.min : 0
        let maxRPM = hasFans ? fanRPMRange.max : 0
        let fans = hasFans ? [FanCapability(
            fanCount: fanCount,
            minRPM: minRPM,
            maxRPM: maxRPM,
            modelIdentifier: "\(model)-\(chip)-\(modelCategory)",
            controllable: isAppleSilicon && hasFans
        )] : []

        return HardwareProfile(
            chip: chip.isEmpty ? "Unknown" : chip,
            deviceModel: "\(modelCategory):\(model.isEmpty ? "Unknown" : model)",
            isAppleSilicon: isAppleSilicon,
            hasFans: hasFans,
            fans: fans
        )
    }

    public static func detectChip() -> String {
        if let override = ProcessInfo.processInfo.environment["MFANCONTROL_CHIP"] {
            return override
        }
        return runShell(["sysctl", "-n", "machdep.cpu.brand_string"])?
            .replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown"
    }

    public static func detectModel() -> String {
        if let override = ProcessInfo.processInfo.environment["MFANCONTROL_MODEL"] {
            return override
        }
        return runShell(["sysctl", "-n", "hw.model"])?
            .replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown"
    }

    public static func modelCategory(_ model: String) -> String {
        let lower = model.lowercased()
        if lower.contains("air") || lower.contains("macbookair") {
            return "MacBookAir"
        }
        if lower.contains("pro") || lower.contains("macbookpro") {
            return "MacBookPro"
        }
        if lower.contains("mini") {
            return "Mac mini"
        }
        if lower.contains("studio") {
            return "Mac Studio"
        }
        if lower.contains("imac") {
            return "iMac"
        }
        if lower.contains("macpro") || lower.contains("pro") {
            return "Mac Pro"
        }
        return "Mac"
    }

    public static func fanCount(for category: String, chip: String) -> Int {
        if chip.contains("M4") && category == "Mac mini" {
            return 2
        }
        if category == "Mac Studio" || category == "Mac Pro" {
            return 2
        }
        if category == "MacBookPro" || category == "iMac" || category == "Mac" {
            return 1
        }
        return 0
    }

    private static func fanRange(for category: String) -> (min: Int, max: Int) {
        switch category {
        case "Mac Studio":
            return (900, 6500)
        case "Mac mini":
            return (900, 6200)
        case "MacBookPro":
            return (1000, 6200)
        case "Mac Pro":
            return (900, 6800)
        case "iMac":
            return (950, 6200)
        default:
            return (1200, 6200)
        }
    }

    private static func normalizeChipLabel(_ chip: String) -> String {
        if chip.contains("M1") { return "M1" }
        if chip.contains("M2") { return "M2" }
        if chip.contains("M3") { return "M3" }
        if chip.contains("M4") { return "M4" }
        if chip.contains("M5") { return "M5" }
        return chip.isEmpty ? "Unknown" : chip
    }

    public static func detectHasFans(model: String, isAppleSilicon: Bool) -> Bool {
        if let override = ProcessInfo.processInfo.environment["MFANCONTROL_HAS_FANS"] {
            return override == "1" || override.lowercased() == "true"
        }
        if !isAppleSilicon { return false }
        return !modelCategory(model).contains("MacBookAir")
    }

    private static func runShell(_ arguments: [String]) -> String? {
        let proc = Process()
        proc.launchPath = "/usr/bin/env"
        proc.arguments = arguments
        let pipe = Pipe()
        proc.standardOutput = pipe
        do {
            try proc.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }
}
