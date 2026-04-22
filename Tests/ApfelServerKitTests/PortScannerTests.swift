import Foundation
import ApfelServerKit
import Darwin

func runPortScannerTests() {
    test("isAvailable returns true for a free port") {
        // The OS assigns a random port when we bind to port 0. If we close it
        // again, that port is normally available to re-bind.
        let (port, fd) = reserveRandomEphemeralPort()
        Darwin.close(fd)
        try assertTrue(PortScanner.isAvailable(port))
    }

    test("isAvailable returns false while port is held") {
        let (port, fd) = reserveRandomEphemeralPort()
        defer { Darwin.close(fd) }
        try assertFalse(PortScanner.isAvailable(port))
    }

    test("firstAvailable returns nil when range is entirely bound") {
        // Reserve two adjacent ephemeral ports and ask the scanner for the exact range.
        let (p1, fd1) = reserveRandomEphemeralPort()
        let (p2, fd2) = reserveRandomEphemeralPort()
        defer { Darwin.close(fd1); Darwin.close(fd2) }

        let lo = min(p1, p2)
        let hi = max(p1, p2)
        if lo == hi {
            // Fluke - skip
            return
        }
        // Narrow the range to the two held ports only, if they happen to be adjacent.
        // Otherwise use each individually.
        try assertNil(PortScanner.firstAvailable(in: p1...p1))
    }

    test("firstAvailable returns free port when one exists") {
        let (port, fd) = reserveRandomEphemeralPort()
        Darwin.close(fd)
        try assertEqual(PortScanner.firstAvailable(in: port...port), port)
    }
}

/// Ask the kernel for an ephemeral port on 127.0.0.1 and return it along with
/// the bound socket FD. Caller is responsible for `close()`-ing the FD.
private func reserveRandomEphemeralPort() -> (Int, Int32) {
    let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    precondition(fd >= 0, "socket() failed")

    var yes: Int32 = 1
    _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0  // let the kernel pick
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")

    let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    precondition(bindResult == 0, "bind() failed")

    var bound = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &bound) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            Darwin.getsockname(fd, sa, &len)
        }
    }
    let port = Int(UInt16(bigEndian: bound.sin_port))
    return (port, fd)
}
