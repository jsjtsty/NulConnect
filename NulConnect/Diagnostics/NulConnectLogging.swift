import Foundation

#if DEBUG && NULCONNECT_ENABLE_LOGS
@inline(__always)
nonisolated func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    Swift.print(items.map { String(describing: $0) }.joined(separator: separator), terminator: terminator)
}
#else
@inline(__always)
nonisolated func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {}
#endif
