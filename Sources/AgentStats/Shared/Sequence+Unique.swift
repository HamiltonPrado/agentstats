import Foundation

extension Sequence where Element: Hashable {
    /// Remove repetidos mantendo a ordem da primeira ocorrência.
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
