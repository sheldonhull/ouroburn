import Foundation

enum ViewMode: String, CaseIterable, Sendable {
    case day
    case week
    case month
    case sessionBlock
    case session

    var title: String {
        switch self {
        case .day: "Daily"
        case .week: "Weekly"
        case .month: "Monthly"
        case .sessionBlock: "5h Block"
        case .session: "Session"
        }
    }
}
