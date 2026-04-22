import Foundation
import ApfelServerKit

func runApfelBinaryFinderTests() {
    test("finds apfel on PATH first entry") {
        let existing: Set<String> = ["/usr/local/bin/apfel", "/opt/homebrew/bin/apfel"]
        let result = ApfelBinaryFinder.find(
            name: "apfel",
            environment: ["PATH": "/usr/local/bin:/opt/homebrew/bin"],
            bundleExecutableURL: nil,
            fileExists: { existing.contains($0) }
        )
        try assertEqual(result, "/usr/local/bin/apfel")
    }

    test("finds apfel at second PATH entry when first missing") {
        let existing: Set<String> = ["/opt/homebrew/bin/apfel"]
        let result = ApfelBinaryFinder.find(
            name: "apfel",
            environment: ["PATH": "/usr/local/bin:/opt/homebrew/bin"],
            bundleExecutableURL: nil,
            fileExists: { existing.contains($0) }
        )
        try assertEqual(result, "/opt/homebrew/bin/apfel")
    }

    test("falls back to bundle directory when not on PATH") {
        let bundle = URL(fileURLWithPath: "/Applications/ApfelQuick.app/Contents/MacOS/ApfelQuick")
        let existing: Set<String> = ["/Applications/ApfelQuick.app/Contents/MacOS/apfel"]
        let result = ApfelBinaryFinder.find(
            name: "apfel",
            environment: ["PATH": "/usr/bin"],
            bundleExecutableURL: bundle,
            fileExists: { existing.contains($0) }
        )
        try assertEqual(result, "/Applications/ApfelQuick.app/Contents/MacOS/apfel")
    }

    test("falls back to bundle Helpers subdirectory") {
        let bundle = URL(fileURLWithPath: "/Applications/ApfelQuick.app/Contents/MacOS/ApfelQuick")
        let existing: Set<String> = ["/Applications/ApfelQuick.app/Contents/MacOS/Helpers/apfel"]
        let result = ApfelBinaryFinder.find(
            name: "apfel",
            environment: ["PATH": "/usr/bin"],
            bundleExecutableURL: bundle,
            fileExists: { existing.contains($0) }
        )
        try assertEqual(result, "/Applications/ApfelQuick.app/Contents/MacOS/Helpers/apfel")
    }

    test("falls back to /opt/homebrew/bin") {
        let existing: Set<String> = ["/opt/homebrew/bin/apfel"]
        let result = ApfelBinaryFinder.find(
            name: "apfel",
            environment: ["PATH": "/nowhere"],
            bundleExecutableURL: nil,
            fileExists: { existing.contains($0) }
        )
        try assertEqual(result, "/opt/homebrew/bin/apfel")
    }

    test("falls back to /usr/local/bin") {
        let existing: Set<String> = ["/usr/local/bin/apfel"]
        let result = ApfelBinaryFinder.find(
            name: "apfel",
            environment: ["PATH": "/nowhere"],
            bundleExecutableURL: nil,
            fileExists: { existing.contains($0) }
        )
        try assertEqual(result, "/usr/local/bin/apfel")
    }

    test("falls back to HOME/.local/bin") {
        let existing: Set<String> = ["/Users/stub/.local/bin/apfel"]
        let result = ApfelBinaryFinder.find(
            name: "apfel",
            environment: ["PATH": "/nowhere", "HOME": "/Users/stub"],
            bundleExecutableURL: nil,
            fileExists: { existing.contains($0) }
        )
        try assertEqual(result, "/Users/stub/.local/bin/apfel")
    }

    test("returns nil when binary is nowhere") {
        let result = ApfelBinaryFinder.find(
            name: "apfel",
            environment: ["PATH": "/nowhere", "HOME": "/home/stub"],
            bundleExecutableURL: nil,
            fileExists: { _ in false }
        )
        try assertNil(result)
    }

    test("accepts alternate binary name (e.g. ohr)") {
        let existing: Set<String> = ["/usr/local/bin/ohr"]
        let result = ApfelBinaryFinder.find(
            name: "ohr",
            environment: ["PATH": "/usr/local/bin"],
            bundleExecutableURL: nil,
            fileExists: { existing.contains($0) }
        )
        try assertEqual(result, "/usr/local/bin/ohr")
    }

    test("PATH order wins over bundle and fallbacks") {
        let bundle = URL(fileURLWithPath: "/Applications/X.app/Contents/MacOS/X")
        let existing: Set<String> = [
            "/pathwins/apfel",
            "/Applications/X.app/Contents/MacOS/apfel",
            "/opt/homebrew/bin/apfel",
            "/usr/local/bin/apfel"
        ]
        let result = ApfelBinaryFinder.find(
            name: "apfel",
            environment: ["PATH": "/pathwins"],
            bundleExecutableURL: bundle,
            fileExists: { existing.contains($0) }
        )
        try assertEqual(result, "/pathwins/apfel")
    }
}
