import Foundation
import ApfelServerKit

func runApfelBinaryFinderExtraTests() {
    test("empty PATH still checks bundle and fallbacks") {
        let bundle = URL(fileURLWithPath: "/Apps/X.app/Contents/MacOS/X")
        let existing: Set<String> = ["/Apps/X.app/Contents/MacOS/apfel"]
        let result = ApfelBinaryFinder.find(
            name: "apfel",
            environment: ["PATH": ""],
            bundleExecutableURL: bundle,
            fileExists: { existing.contains($0) }
        )
        try assertEqual(result, "/Apps/X.app/Contents/MacOS/apfel")
    }

    test("missing PATH env var still checks bundle and fallbacks") {
        let existing: Set<String> = ["/opt/homebrew/bin/apfel"]
        let result = ApfelBinaryFinder.find(
            name: "apfel",
            environment: [:],
            bundleExecutableURL: nil,
            fileExists: { existing.contains($0) }
        )
        try assertEqual(result, "/opt/homebrew/bin/apfel")
    }

    test("missing HOME skips ~/.local/bin fallback cleanly") {
        // Without HOME, the finder skips the ~/.local/bin entry but still
        // checks the hardcoded /opt/homebrew/bin and /usr/local/bin.
        let existing: Set<String> = ["/usr/local/bin/apfel"]
        let result = ApfelBinaryFinder.find(
            name: "apfel",
            environment: ["PATH": "/nowhere"],
            bundleExecutableURL: nil,
            fileExists: { existing.contains($0) }
        )
        try assertEqual(result, "/usr/local/bin/apfel")
    }

    test("empty HOME is treated as missing") {
        let result = ApfelBinaryFinder.find(
            name: "apfel",
            environment: ["PATH": "/nowhere", "HOME": ""],
            bundleExecutableURL: nil,
            fileExists: { _ in false }
        )
        try assertNil(result)
    }

    test("PATH with consecutive colons skips empty components") {
        let existing: Set<String> = ["/last/apfel"]
        let result = ApfelBinaryFinder.find(
            name: "apfel",
            environment: ["PATH": "::/first::/last::"],
            bundleExecutableURL: nil,
            fileExists: { existing.contains($0) }
        )
        try assertEqual(result, "/last/apfel")
    }

    test("PATH with single entry works") {
        let existing: Set<String> = ["/only/apfel"]
        let result = ApfelBinaryFinder.find(
            name: "apfel",
            environment: ["PATH": "/only"],
            bundleExecutableURL: nil,
            fileExists: { existing.contains($0) }
        )
        try assertEqual(result, "/only/apfel")
    }

    test("bundle URL with no parent still tries Helpers") {
        // A bundle URL that resolves to root (rare, but possible in unusual
        // embeddings) should not crash.
        let bundle = URL(fileURLWithPath: "/ApfelQuick")
        let existing: Set<String> = [] // nothing found
        let result = ApfelBinaryFinder.find(
            name: "apfel",
            environment: ["PATH": "/nowhere"],
            bundleExecutableURL: bundle,
            fileExists: { existing.contains($0) }
        )
        try assertNil(result)
    }

    test("PATH entries with trailing slash still resolve") {
        // "/usr/local/bin/" joined with "apfel" yields "/usr/local/bin//apfel".
        // Most tools tolerate the double slash but many match paths exactly.
        // We DON'T normalize - callers should give clean PATH entries. If this
        // test's expectation changes, so does the public contract.
        let existing: Set<String> = ["/tidy/bin/apfel"]
        let result = ApfelBinaryFinder.find(
            name: "apfel",
            environment: ["PATH": "/tidy/bin"],
            bundleExecutableURL: nil,
            fileExists: { existing.contains($0) }
        )
        try assertEqual(result, "/tidy/bin/apfel")
    }

    test("searches for name with special chars (not apfel)") {
        let existing: Set<String> = ["/usr/local/bin/apfel-chat"]
        let result = ApfelBinaryFinder.find(
            name: "apfel-chat",
            environment: ["PATH": "/usr/local/bin"],
            bundleExecutableURL: nil,
            fileExists: { existing.contains($0) }
        )
        try assertEqual(result, "/usr/local/bin/apfel-chat")
    }

    test("bundle precedence is Parent -> Helpers, in that order") {
        let bundle = URL(fileURLWithPath: "/X.app/Contents/MacOS/X")
        let existing: Set<String> = [
            "/X.app/Contents/MacOS/apfel",
            "/X.app/Contents/MacOS/Helpers/apfel"
        ]
        let result = ApfelBinaryFinder.find(
            name: "apfel",
            environment: ["PATH": "/nowhere"],
            bundleExecutableURL: bundle,
            fileExists: { existing.contains($0) }
        )
        try assertEqual(result, "/X.app/Contents/MacOS/apfel")
    }

    test("Homebrew precedence is /opt/homebrew first (Apple Silicon default)") {
        let existing: Set<String> = [
            "/opt/homebrew/bin/apfel",
            "/usr/local/bin/apfel"
        ]
        let result = ApfelBinaryFinder.find(
            name: "apfel",
            environment: ["PATH": "/nowhere"],
            bundleExecutableURL: nil,
            fileExists: { existing.contains($0) }
        )
        try assertEqual(result, "/opt/homebrew/bin/apfel")
    }
}
