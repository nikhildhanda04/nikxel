import Foundation

enum CaptureMode: String {
    case notes
    case meeting

    static let userDefaultsKey = "nikxel.captureMode"

    static var current: CaptureMode {
        get {
            let raw = UserDefaults.standard.string(forKey: userDefaultsKey) ?? ""
            return CaptureMode(rawValue: raw) ?? .notes
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: userDefaultsKey) }
    }

    var displayName: String {
        switch self {
        case .notes: return "Notes"
        case .meeting: return "Meeting"
        }
    }
}
