import Foundation

enum NulConnectProxyParserError: LocalizedError {
    case invalidRequest
    case unsupportedCommand(String)
    case unsupportedAddressType(UInt8)
    case malformedRequest

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            return "invalid proxy request"
        case .unsupportedCommand(let command):
            return "unsupported proxy command: \(command)"
        case .unsupportedAddressType(let type):
            return "unsupported socks5 address type: \(type)"
        case .malformedRequest:
            return "malformed proxy request"
        }
    }
}

struct NulConnectHTTPProxyRequest {
    var method: String
    var target: String
    var version: String
    var headers: [String: String]
    var headerLength: Int
    var body: Data
}

struct NulConnectSOCKS5ConnectRequest {
    var host: String
    var port: UInt16
    var remainingData: Data
}

enum NulConnectProxyParser {
    static func parseHTTPProxyRequest(_ data: Data) -> NulConnectHTTPProxyRequest? {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else {
            return nil
        }

        guard let headerText = String(data: data[..<headerRange.lowerBound], encoding: .utf8) else {
            return nil
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return nil
        }

        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 3 else {
            return nil
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colonIndex = line.firstIndex(of: ":") else {
                continue
            }
            let name = line[..<colonIndex].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: colonIndex)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }

        let bodyStart = headerRange.upperBound
        let body = bodyStart <= data.endIndex ? data[bodyStart...] : Data()

        return NulConnectHTTPProxyRequest(
            method: String(parts[0]),
            target: String(parts[1]),
            version: String(parts[2]),
            headers: headers,
            headerLength: bodyStart,
            body: Data(body)
        )
    }

    static func rewriteHTTPProxyRequest(
        _ request: NulConnectHTTPProxyRequest,
        host: String,
        port: UInt16
    ) -> Data {
        let normalizedPath = rewriteTarget(request.target)
        let headerLines = request.headers.map { key, value in
            "\(canonicalHeaderName(key)): \(value)"
        }

        var lines: [String] = []
        lines.append("\(request.method) \(normalizedPath) \(request.version)")
        lines.append(contentsOf: headerLines)
        if request.headers["host"] == nil {
            let defaultPort = port == 80 ? "" : ":\(port)"
            lines.append("Host: \(host)\(defaultPort)")
        }

        let data = (lines.joined(separator: "\r\n") + "\r\n\r\n").data(using: .utf8) ?? Data()
        return data + request.body
    }

    static func parseSOCKS5Greeting(_ data: Data) -> Bool? {
        guard data.count >= 2 else {
            return nil
        }
        guard data.first == 0x05 else {
            return false
        }
        let methodCount = Int(data[1])
        guard data.count >= 2 + methodCount else {
            return nil
        }
        return true
    }

    static func parseSOCKS5ConnectRequest(_ data: Data) throws -> NulConnectSOCKS5ConnectRequest? {
        guard data.count >= 4 else {
            return nil
        }
        guard data[0] == 0x05 else {
            throw NulConnectProxyParserError.invalidRequest
        }
        guard data[1] == 0x01 else {
            throw NulConnectProxyParserError.unsupportedCommand("0x\(String(data[1], radix: 16))")
        }
        let atyp = data[3]
        var index = 4

        let host: String
        switch atyp {
        case 0x01:
            guard data.count >= index + 4 + 2 else { return nil }
            let addressBytes = data[index..<(index + 4)]
            host = addressBytes.map { String($0) }.joined(separator: ".")
            index += 4
        case 0x03:
            guard data.count >= index + 1 else { return nil }
            let length = Int(data[index])
            index += 1
            guard data.count >= index + length + 2 else { return nil }
            guard let string = String(data: data[index..<(index + length)], encoding: .utf8) else {
                throw NulConnectProxyParserError.malformedRequest
            }
            host = string
            index += length
        case 0x04:
            guard data.count >= index + 16 + 2 else { return nil }
            let addressBytes = data[index..<(index + 16)]
            var segments: [String] = []
            for offset in stride(from: 0, to: 16, by: 2) {
                let value = UInt16(addressBytes[addressBytes.index(addressBytes.startIndex, offsetBy: offset)]) << 8
                    | UInt16(addressBytes[addressBytes.index(addressBytes.startIndex, offsetBy: offset + 1)])
                segments.append(String(value, radix: 16))
            }
            host = segments.joined(separator: ":")
            index += 16
        default:
            throw NulConnectProxyParserError.unsupportedAddressType(atyp)
        }

        guard data.count >= index + 2 else {
            return nil
        }
        let port = UInt16(data[index]) << 8 | UInt16(data[index + 1])
        index += 2

        return NulConnectSOCKS5ConnectRequest(
            host: host,
            port: port,
            remainingData: Data(data[index...])
        )
    }

    static func socks5GreetingResponse() -> Data {
        Data([0x05, 0x00])
    }

    static func socks5ConnectSuccessResponse() -> Data {
        Data([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
    }

    static func socks5FailureResponse() -> Data {
        Data([0x05, 0x01, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
    }

    private static func rewriteTarget(_ target: String) -> String {
        guard let url = URL(string: target), let components = URLComponents(url: url, resolvingAgainstBaseURL: false), let scheme = components.scheme?.lowercased(), let host = components.host else {
            return target
        }

        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        let query = components.percentEncodedQuery.map { "?\($0)" } ?? ""
        _ = scheme
        _ = host
        return path + query
    }

    private static func canonicalHeaderName(_ name: String) -> String {
        name.split(separator: "-").map { part in
            let first = part.prefix(1).uppercased()
            let rest = part.dropFirst().lowercased()
            return first + rest
        }.joined(separator: "-")
    }
}
