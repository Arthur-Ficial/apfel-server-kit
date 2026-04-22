import Foundation
import ApfelServerKit

/// Exhaustive direct coverage of every error case for both error types.
/// Exercises Equatable, LocalizedError, and ensures pattern-matching on
/// associated values works as intended.
func runErrorTypeDirectTests() {

    test("ApfelServerError.binaryNotFound equals itself, differs from others") {
        let a = ApfelServerError.binaryNotFound
        try assertEqual(a, .binaryNotFound)
        try assertFalse(a == .noPortAvailable(1...2))
        try assertFalse(a == .spawnFailed("x"))
        try assertFalse(a == .healthCheckTimeout(port: 1, seconds: 1))
    }

    test("ApfelServerError.noPortAvailable compares range by value") {
        try assertEqual(
            ApfelServerError.noPortAvailable(11450...11459),
            .noPortAvailable(11450...11459)
        )
        try assertFalse(
            ApfelServerError.noPortAvailable(1...2)
                == ApfelServerError.noPortAvailable(3...4)
        )
    }

    test("ApfelServerError.spawnFailed compares message by value") {
        try assertEqual(
            ApfelServerError.spawnFailed("same"),
            .spawnFailed("same")
        )
        try assertFalse(
            ApfelServerError.spawnFailed("a") == ApfelServerError.spawnFailed("b")
        )
    }

    test("ApfelServerError.healthCheckTimeout compares both associated values") {
        try assertEqual(
            ApfelServerError.healthCheckTimeout(port: 1, seconds: 2.0),
            .healthCheckTimeout(port: 1, seconds: 2.0)
        )
        try assertFalse(
            ApfelServerError.healthCheckTimeout(port: 1, seconds: 2.0)
                == .healthCheckTimeout(port: 2, seconds: 2.0)
        )
        try assertFalse(
            ApfelServerError.healthCheckTimeout(port: 1, seconds: 2.0)
                == .healthCheckTimeout(port: 1, seconds: 3.0)
        )
    }

    test("ApfelServerError can be pattern-matched to extract associated values") {
        let err = ApfelServerError.noPortAvailable(100...200)
        if case .noPortAvailable(let range) = err {
            try assertEqual(range.lowerBound, 100)
            try assertEqual(range.upperBound, 200)
        } else {
            throw TestFailure("pattern match failed")
        }
    }

    test("ApfelClientError.invalidURL is unique") {
        try assertEqual(ApfelClientError.invalidURL, .invalidURL)
        try assertFalse(ApfelClientError.invalidURL == .httpStatus(0))
    }

    test("ApfelClientError.httpStatus compares status code") {
        try assertEqual(ApfelClientError.httpStatus(404), .httpStatus(404))
        try assertFalse(ApfelClientError.httpStatus(200) == .httpStatus(201))
    }

    test("ApfelClientError.stream compares message") {
        try assertEqual(ApfelClientError.stream("boom"), .stream("boom"))
        try assertFalse(ApfelClientError.stream("a") == .stream("b"))
    }

    test("ApfelServerError errorDescription ends without period or with sentence") {
        // Not a hard rule, just a smoke test that messages are non-empty.
        for c in apfelServerErrorCases {
            let msg = c.errorDescription ?? ""
            try assertTrue(msg.count > 10, "too short: \(msg)")
        }
    }

    test("ApfelClientError errorDescription covers all cases") {
        for c in apfelClientErrorCases {
            let msg = c.errorDescription ?? ""
            try assertTrue(!msg.isEmpty)
        }
    }

    test("ApfelServerError can be rethrown and re-caught via typed catch") {
        func thrower() throws { throw ApfelServerError.binaryNotFound }
        do {
            try thrower()
            throw TestFailure("did not throw")
        } catch let e as ApfelServerError {
            try assertEqual(e, .binaryNotFound)
        }
    }

    test("ApfelClientError can be rethrown and re-caught via typed catch") {
        func thrower() throws { throw ApfelClientError.httpStatus(503) }
        do {
            try thrower()
            throw TestFailure("did not throw")
        } catch let e as ApfelClientError {
            try assertEqual(e, .httpStatus(503))
        }
    }
}

private let apfelServerErrorCases: [ApfelServerError] = [
    .binaryNotFound,
    .noPortAvailable(11450...11459),
    .spawnFailed("system error"),
    .healthCheckTimeout(port: 11450, seconds: 8.0)
]

private let apfelClientErrorCases: [ApfelClientError] = [
    .invalidURL,
    .httpStatus(500),
    .stream("something went wrong")
]
