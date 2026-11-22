import Foundation
import SwiftUI
import AppKit
import UserNotifications

struct SystemAlert: Identifiable, Sendable {
    enum Kind: String { case cpu, temp, memory, disk, battery }
    var id: String { kind.rawValue }
    let kind: Kind
    let value: String
    let since: Date
    let detail: String?
}

extension SystemAlert.Kind {
    var label: String {
        switch self {
        case .cpu: "CPU alta"
        case .temp: "Temperatura alta"
        case .memory: "Memória alta"
        case .disk: "Pouco espaço em disco"
        case .battery: "Bateria fraca"
        }
    }
}
