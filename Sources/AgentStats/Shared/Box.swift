import SwiftUI
import AppKit

/// Substituto de @State (as Command Line Tools não incluem o plugin de macros do SwiftUI).
final class Box<T>: ObservableObject {
    @Published var value: T
    init(_ v: T) { value = v }
}
