import Foundation
import SwiftUI
import AppKit
import UserNotifications

/// Leitura/escrita das definições em UserDefaults (com valor por omissão).
enum Pref {
    static func double(_ key: String, _ def: Double) -> Double { UserDefaults.standard.object(forKey: key) as? Double ?? def }
    static func bool(_ key: String, _ def: Bool) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? def }
    static func string(_ key: String) -> String? { UserDefaults.standard.string(forKey: key) }
    static func set(_ value: Any, _ key: String) { UserDefaults.standard.set(value, forKey: key) }
}
