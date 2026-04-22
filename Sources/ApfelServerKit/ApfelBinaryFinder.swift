import Foundation

/// Locates the apfel binary across the common install locations apfel ecosystem
/// tools have historically searched.
///
/// Search order (first match wins):
/// 1. Each component of `environment["PATH"]`
/// 2. The bundle executable's parent directory (e.g. `MyApp.app/Contents/MacOS/`)
/// 3. The bundle executable's `Helpers/` subdirectory
/// 4. `/opt/homebrew/bin`
/// 5. `/usr/local/bin`
/// 6. `$HOME/.local/bin`
///
/// All dependencies (env, bundle URL, filesystem check) are injectable so tests
/// can pin every path deterministically.
public enum ApfelBinaryFinder: Sendable {

    /// Find the given binary using the canonical apfel ecosystem search order.
    /// - Parameters:
    ///   - name: Binary name without a leading slash. Defaults to `"apfel"`.
    ///   - environment: Process environment; defaults to `ProcessInfo.processInfo.environment`.
    ///     Only `PATH` and `HOME` are consulted.
    ///   - bundleExecutableURL: Current bundle's executable URL. Pass `nil` for CLI contexts;
    ///     defaults to `Bundle.main.executableURL`.
    ///   - fileExists: Closure returning whether a file exists at the given absolute path.
    ///     Defaults to `FileManager.default.isExecutableFile(atPath:)`.
    /// - Returns: Absolute path of the first matching binary, or `nil` if none found.
    public static func find(
        name: String = "apfel",
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleExecutableURL: URL? = Bundle.main.executableURL,
        fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        // 1. PATH components
        if let path = environment["PATH"], !path.isEmpty {
            for component in path.split(separator: ":", omittingEmptySubsequences: true) {
                let candidate = "\(component)/\(name)"
                if fileExists(candidate) { return candidate }
            }
        }

        // 2. Bundle executable's parent directory
        if let bundle = bundleExecutableURL {
            let parent = bundle.deletingLastPathComponent().path
            let candidate = "\(parent)/\(name)"
            if fileExists(candidate) { return candidate }

            // 3. Bundle Helpers/
            let helpers = "\(parent)/Helpers/\(name)"
            if fileExists(helpers) { return helpers }
        }

        // 4-6. Hardcoded fallbacks (ordered as in the sibling implementations)
        let fallbacks: [String]
        if let home = environment["HOME"], !home.isEmpty {
            fallbacks = [
                "/opt/homebrew/bin/\(name)",
                "/usr/local/bin/\(name)",
                "\(home)/.local/bin/\(name)"
            ]
        } else {
            fallbacks = [
                "/opt/homebrew/bin/\(name)",
                "/usr/local/bin/\(name)"
            ]
        }
        for candidate in fallbacks {
            if fileExists(candidate) { return candidate }
        }

        return nil
    }
}
