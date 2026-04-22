import Foundation
import Darwin

/// Check whether TCP ports on `127.0.0.1` are available, and pick the first
/// free one from a configured range.
///
/// Uses the same `socket + SO_REUSEADDR + bind()` pattern that apfel-quick,
/// apfel-chat, and apfel-clip all use. No `lsof`, no network connect probe.
public enum PortScanner: Sendable {

    /// Whether the given TCP port on `127.0.0.1` can currently be bound.
    public static func isAvailable(_ port: Int) -> Bool {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }

        var yes: Int32 = 1
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    /// The first port in the range that can currently be bound, or `nil`
    /// if every port is taken.
    public static func firstAvailable(in range: ClosedRange<Int>) -> Int? {
        for port in range where isAvailable(port) {
            return port
        }
        return nil
    }
}
