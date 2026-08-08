import Foundation

@inline(__always)
nonisolated func print(_ items: Any..., separator: String = " ", terminator: String = "\n") {
    let message = items.map { String(describing: $0) }.joined(separator: separator)
    NulConnectDiagnostics.log(message + (terminator == "\n" ? "" : terminator))
}
