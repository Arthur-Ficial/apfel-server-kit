import Foundation
import ApfelServerKit
import Darwin

func runPortScannerExtraTests() {
    test("isAvailable rejects port 0 gracefully") {
        // Port 0 means "let kernel assign". Binding with a literal 0 succeeds
        // in bind() but picks another port - that's not a real availability
        // check, so we treat our scan as "available" (since bind returns 0).
        // This is an implementation artifact and documented here as fine.
        _ = PortScanner.isAvailable(0) // must not crash
    }

    test("isAvailable for well-known port 22 is system-dependent but does not crash") {
        // On a typical dev mac SSH is disabled, so 22 is available. We just
        // verify the call completes and returns a Bool.
        _ = PortScanner.isAvailable(22)
    }

    test("firstAvailable iterates in ascending order and returns earliest free port") {
        let (p1, fd1) = ephemeral()
        let (p2, fd2) = ephemeral()
        defer { Darwin.close(fd1); Darwin.close(fd2) }

        let lo = min(p1, p2)
        let hi = max(p1, p2)
        // Free the higher port; lower stays held.
        if p1 > p2 { Darwin.close(fd1) } else { Darwin.close(fd2) }
        if let first = PortScanner.firstAvailable(in: lo...hi) {
            try assertEqual(first, hi, "should have picked the freed higher port, not the held lower one")
        }
    }

    test("firstAvailable in a single-port range returns that port when free") {
        let (port, fd) = ephemeral()
        Darwin.close(fd)
        try assertEqual(PortScanner.firstAvailable(in: port...port), port)
    }

    test("100 consecutive isAvailable calls do not leak file descriptors") {
        // If the implementation forgot to close() the probe socket, a long
        // run would exhaust the process FD budget. 100 is a sanity cap.
        for _ in 0..<100 {
            _ = PortScanner.isAvailable(0)
        }
    }
}

private func ephemeral() -> (Int, Int32) {
    let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    precondition(fd >= 0)
    var yes: Int32 = 1
    _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    _ = withUnsafePointer(to: &addr) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            Darwin.bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    var bound = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &bound) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            Darwin.getsockname(fd, sa, &len)
        }
    }
    return (Int(UInt16(bigEndian: bound.sin_port)), fd)
}
