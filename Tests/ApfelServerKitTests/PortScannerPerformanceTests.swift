import Foundation
import ApfelServerKit

/// Sanity performance checks - the scanner must not be catastrophically
/// slow for reasonable inputs. These are loose upper bounds, not
/// micro-benchmarks.
func runPortScannerPerformanceTests() {

    test("scanning a 100-port range completes in under 1 second") {
        let start = Date()
        _ = PortScanner.firstAvailable(in: 60_000...60_099)
        let elapsed = Date().timeIntervalSince(start)
        try assertTrue(elapsed < 1.0, "100-port scan took \(elapsed)s")
    }

    test("isAvailable returns within 500ms for a single port") {
        let start = Date()
        _ = PortScanner.isAvailable(60_100)
        let elapsed = Date().timeIntervalSince(start)
        try assertTrue(elapsed < 0.5, "isAvailable took \(elapsed)s")
    }

    test("1000 consecutive isAvailable calls complete in under 5 seconds") {
        // Also catches FD leaks - the process would eventually run out.
        let start = Date()
        for i in 0..<1000 {
            _ = PortScanner.isAvailable(60_200 + (i % 10))
        }
        let elapsed = Date().timeIntervalSince(start)
        try assertTrue(elapsed < 5.0, "1000 calls took \(elapsed)s")
    }

    test("firstAvailable returns promptly when the first port is free") {
        let start = Date()
        _ = PortScanner.firstAvailable(in: 60_300...60_399)
        let elapsed = Date().timeIntervalSince(start)
        try assertTrue(elapsed < 0.1, "fast-path scan took \(elapsed)s")
    }
}
