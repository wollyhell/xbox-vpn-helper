import Foundation

enum AppMode: String, CaseIterable, Identifiable {
    case basic
    case advanced

    var id: String { rawValue }

    var title: String {
        switch self {
        case .basic:
            return "Простой"
        case .advanced:
            return "Расширенный"
        }
    }
}

enum HealthLevel: String {
    case ok
    case warning
    case error
    case unknown

    var symbol: String {
        switch self {
        case .ok:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .error:
            return "xmark.octagon.fill"
        case .unknown:
            return "questionmark.circle.fill"
        }
    }

    var priority: Int {
        switch self {
        case .error:
            return 3
        case .warning:
            return 2
        case .unknown:
            return 1
        case .ok:
            return 0
        }
    }
}

struct StatusItem: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let level: HealthLevel
}

struct ResolvedConfig {
    let ethernetInterface: String
    let ethernetLabel: String
    let macAddress: String
    let xboxAddress: String
    let detectedVPNInterface: String?
    let detectedVPNAddress: String?
}

enum SetupStage {
    case idle
    case readyForXboxReboot
    case verifyingAfterXboxReboot
    case complete

    var title: String {
        switch self {
        case .idle:
            return "Ожидание запуска"
        case .readyForXboxReboot:
            return "Нужно перезагрузить Xbox"
        case .verifyingAfterXboxReboot:
            return "Проверяю после перезагрузки Xbox"
        case .complete:
            return "Настройка завершена"
        }
    }
}

struct AppSnapshot {
    var resolvedConfig: ResolvedConfig?
    var detectedVPNInterface: String?
    var detectedVPNAddress: String?
    var ethernetIsActive = false
    var ethernetHasExpectedIP = false
    var staleIPInterfaces: [String] = []
    var xboxVisibleOnLAN = false
    var ipForwardingEnabled = false
    var caffeinateRunning = false
    var pfAnchorStatus = "Проверка NAT требует прав администратора."
    var items: [StatusItem] = []

    var overallLevel: HealthLevel {
        if items.contains(where: { $0.level == .error }) {
            return .error
        }
        if items.contains(where: { $0.level == .warning }) {
            return .warning
        }
        if items.contains(where: { $0.level == .ok }) {
            return .ok
        }
        return .unknown
    }

    var overallTitle: String {
        switch overallLevel {
        case .ok:
            return "Подключение выглядит готовым"
        case .warning:
            return "Есть пара моментов, которые стоит поправить"
        case .error:
            return "Подключение сейчас не готово"
        case .unknown:
            return "Часть статуса не удалось подтвердить"
        }
    }

    var failingItems: [StatusItem] {
        items.filter { $0.level != .ok }
    }
}
