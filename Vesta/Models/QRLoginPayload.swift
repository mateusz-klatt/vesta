import Darwin
import Foundation

struct QRLoginPayload: Equatable, Sendable {
    let origin: URL
    let code: String

    init?(rawValue: String) {
        let prefix = "hestia-login:"
        guard rawValue.utf8.count <= 78, Self.isSafeASCII(rawValue), rawValue.hasPrefix(prefix) else { return nil }

        let parts = rawValue.dropFirst(prefix.count).split(separator: "#", omittingEmptySubsequences: false)
        guard parts.count == 2, Self.isCanonicalCode(parts[1]), let origin = Self.canonicalOrigin(parts[0]) else {
            return nil
        }
        self.origin = origin
        code = String(parts[1])
    }

    /// Check the raw authority before URL's permissive parser can normalize it.
    static func canonicalOrigin(_ raw: Substring) -> URL? {
        let scheme = "https://"
        guard raw.utf8.count <= 45, isSafeASCII(raw), raw.hasPrefix(scheme) else { return nil }
        let authority = raw.dropFirst(scheme.count)
        guard !authority.contains(where: { "@/#".contains($0) }) else { return nil }

        let host: Substring
        let port: Substring
        if authority.first == "[" {
            guard let end = authority.firstIndex(of: "]"),
                  isIPv6(authority[authority.index(after: authority.startIndex)..<end]) else { return nil }
            host = authority[...end]
            port = authority[authority.index(after: end)...]
        } else {
            let separator = authority.firstIndex(of: ":") ?? authority.endIndex
            host = authority[..<separator]
            port = authority[separator...]
            guard isHostnameOrIPv4(host) else { return nil }
        }

        var canonical = scheme + host.lowercased()
        if !port.isEmpty {
            let digits = port.dropFirst()
            guard port.first == ":", !digits.isEmpty, digits.first != "0", digits.utf8.allSatisfy(isDigit),
                  let number = UInt16(digits), number > 0 else { return nil }
            if number != 443 { canonical += ":\(number)" }
        }
        return URL(string: canonical)
    }

    private static func isSafeASCII(_ raw: some StringProtocol) -> Bool {
        raw.utf8.allSatisfy { byte in
            (0x21...0x7E).contains(byte) && byte != UInt8(ascii: "\\") && byte != UInt8(ascii: "%") && byte != UInt8(ascii: "?")
        }
    }

    private static func isCanonicalCode(_ code: Substring) -> Bool {
        guard code.utf8.count == 19, code.utf8.allSatisfy({ isAlphanumeric($0) || $0 == UInt8(ascii: "-") || $0 == UInt8(ascii: "_") }) else {
            return false
        }
        let standard = code.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="
        guard let decoded = Data(base64Encoded: standard), decoded.count == 14 else { return false }
        let roundTrip = decoded.base64EncodedString().dropLast()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        return roundTrip == code
    }

    private static func isIPv6(_ host: Substring) -> Bool {
        if host.contains(".") {
            let tail = host.split(separator: ":").last ?? ""
            guard isDottedIPv4(tail.split(separator: ".", omittingEmptySubsequences: false)) else { return false }
        }
        var address = in6_addr()
        return inet_pton(AF_INET6, String(host), &address) == 1
    }

    private static func isHostnameOrIPv4(_ host: Substring) -> Bool {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty, labels.allSatisfy({ label in
            guard let first = label.utf8.first, let last = label.utf8.last,
                  isAlphanumeric(first), isAlphanumeric(last) else { return false }
            return label.utf8.allSatisfy { isAlphanumeric($0) || $0 == UInt8(ascii: "-") }
        }) else { return false }

        // Resolver aliases like 127.1, 0177.0.0.1, and hexadecimal IPv4 spellings are ambiguous.
        return !labels.allSatisfy(isIPv4Number) || isDottedIPv4(labels)
    }

    private static func isDottedIPv4(_ labels: [Substring]) -> Bool {
        // Darwin's inet_pton also accepts leading zeroes, so validate each decimal octet explicitly.
        labels.count == 4 && labels.allSatisfy { label in
            (label.utf8.count == 1 || label.first != "0") && label.utf8.allSatisfy(isDigit) && UInt8(label) != nil
        }
    }

    private static func isIPv4Number(_ label: Substring) -> Bool {
        if label.utf8.allSatisfy(isDigit) { return true }
        let lower = label.lowercased()
        return lower.hasPrefix("0x") && lower.utf8.count > 2 && lower.utf8.dropFirst(2).allSatisfy {
            isDigit($0) || (0x61...0x66).contains($0)
        }
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        isDigit(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
    }

    private static func isDigit(_ byte: UInt8) -> Bool { (0x30...0x39).contains(byte) }
}
