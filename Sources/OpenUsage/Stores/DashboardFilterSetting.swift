/// The dashboard lens is shared by its controls, provider cards, and Total Spend presentation.
enum DashboardFilterMode: String, CaseIterable, Identifiable, Sendable {
    case all = "all"
    case quotas = "quotas"
    case alerts = "alerts"

    static let key = "dashboard.filterMode"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: "All"
        case .quotas: "Quotas"
        case .alerts: "Alerts"
        }
    }

    func matches(data: WidgetData) -> Bool {
        switch self {
        case .all: true
        case .quotas: !data.isUsagePeriod && !data.isChart
        case .alerts: Self.isAlerting(data: data)
        }
    }

    static func isAlerting(data: WidgetData) -> Bool {
        if data.isBounded {
            switch data.meterState().severity {
            case .warning, .critical: return true
            case .normal, nil: break
            }
        }
        switch data.expirySeverity() {
        case .warning, .critical: return true
        case .normal, nil: return data.hasUnknownModels
        }
    }
}

enum DashboardGroupingSetting {
    static let groupByFamilyKey = "dashboard.groupByFamily"
}
