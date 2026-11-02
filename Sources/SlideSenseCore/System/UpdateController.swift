import CryptoKit
import Foundation

/// Compares dotted version strings the way Sparkle does: numerically, with
/// missing components treated as zero ("0.2" == "0.2.0", "0.1.10" > "0.1.9").
public enum UpdateVersion {
    public static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = components(lhs)
        let right = components(rhs)
        let count = max(left.count, right.count)

        for index in 0..<count {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a < b { return .orderedAscending }
            if a > b { return .orderedDescending }
        }
        return .orderedSame
    }

    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        compare(candidate, current) == .orderedDescending
    }

    private static func components(_ version: String) -> [Int] {
        var result: [Int] = []
        let trimmed = version.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))

        for part in trimmed.split(separator: ".") {
            let digits = part.prefix { $0.isNumber }
            result.append(Int(digits) ?? 0)
            // A prerelease or build suffix ends the comparable version:
            // "0.1.2-beta.1" compares as "0.1.2".
            if digits.count != part.count { break }
        }
        return result
    }
}

/// One published release, as advertised by the GitHub releases API.
public struct UpdateRelease: Sendable, Equatable {
    public let version: String
    public let notes: String
    public let downloadURL: URL
    public let pageURL: URL
    public let size: Int
    /// "sha256:…" from the release asset, if GitHub published one.
    public let digest: String?
}

public enum UpdateError: LocalizedError, Equatable {
    case badResponse(Int)
    case malformedRelease
    case noDownload
    case checksumMismatch
    case notWritable(String)
    case installFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .badResponse(code): return "GitHub returned HTTP \(code)."
        case .malformedRelease: return "The latest release could not be read."
        case .noDownload: return "The latest release has no app archive attached."
        case .checksumMismatch: return "The download does not match the published checksum."
        case let .notWritable(path): return "SlideSense cannot write to \(path). Move it to /Applications and try again."
        case let .installFailed(message): return message
        }
    }
}

/// Checks GitHub releases, verifies the archive and swaps the running bundle.
///
/// Deliberately no framework: the app is ad-hoc signed, and Sparkle refuses to
/// install updates into a bundle whose signature has no team identifier. Instead
/// the archive is verified against the SHA-256 GitHub publishes for the asset,
/// and only then unpacked and swapped in.
public final class UpdateController {
    public static let shared = UpdateController()

    private let repository = "shashvat1965/slidesense"
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    public var currentVersion: String {
        SlideSenseVersion.marketing
    }

    /// Overrides the bundle that gets replaced. Only used by tests, which
    /// install into a temporary copy instead of the running app.
    public var installTargetURL: URL?

    // MARK: - Checking

    /// Returns the newest release if it is newer than the running app.
    public func checkForUpdate(comparingTo versionOverride: String? = nil) async throws -> UpdateRelease? {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            throw UpdateError.malformedRelease
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UpdateError.badResponse(status) }

        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tag = json["tag_name"] as? String
        else { throw UpdateError.malformedRelease }

        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let running = versionOverride ?? currentVersion
        guard UpdateVersion.isNewer(version, than: running) else { return nil }

        let assets = json["assets"] as? [[String: Any]] ?? []
        guard
            let zip = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
            let downloadString = zip["browser_download_url"] as? String,
            let downloadURL = URL(string: downloadString)
        else { throw UpdateError.noDownload }

        let pageString = json["html_url"] as? String ?? "https://github.com/\(repository)/releases"
        return UpdateRelease(
            version: version,
            notes: json["body"] as? String ?? "",
            downloadURL: downloadURL,
            pageURL: URL(string: pageString) ?? URL(string: "https://github.com/\(repository)")!,
            size: zip["size"] as? Int ?? 0,
            digest: zip["digest"] as? String
        )
    }

    // MARK: - Downloading

    /// Downloads, verifies and unpacks the release. Returns the new bundle URL
    /// inside a temporary directory.
    public func download(_ release: UpdateRelease, progress: ((Double) -> Void)? = nil) async throws -> URL {
        let (temporary, response) = try await session.download(from: release.downloadURL)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw UpdateError.badResponse(status) }

        let data = try Data(contentsOf: temporary)
        if let digest = release.digest, digest.hasPrefix("sha256:") {
            let expected = String(digest.dropFirst("sha256:".count)).lowercased()
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard expected == actual else { throw UpdateError.checksumMismatch }
        }
        progress?(0.5)

        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("SlideSenseUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        let archive = work.appendingPathComponent("update.zip")
        try data.write(to: archive)

        let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
        try run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path])

        let app = try FileManager.default
            .contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "app" }
        guard let app else { throw UpdateError.installFailed("The archive did not contain an app.") }

        // The bundle inside must actually be the version we were promised.
        let plist = app.appendingPathComponent("Contents/Info.plist")
        if let info = NSDictionary(contentsOf: plist) as? [String: Any],
           let bundled = info["CFBundleShortVersionString"] as? String,
           bundled != release.version {
            throw UpdateError.installFailed("The archive contains \(bundled), not \(release.version).")
        }

        progress?(1.0)
        return app
    }

    // MARK: - Installing

    /// Swaps the new bundle in after this process exits, then relaunches it.
    public func install(_ newApp: URL) throws {
        let target = installTargetURL ?? Bundle.main.bundleURL
        let parent = target.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw UpdateError.notWritable(parent.path)
        }

        let script = """
        #!/bin/sh
        # Wait for the running app to quit, then swap the bundle in place.
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        sleep 0.4
        rm -rf "\(target.path)"
        /usr/bin/ditto "\(newApp.path)" "\(target.path)"
        /usr/bin/xattr -dr com.apple.quarantine "\(target.path)" 2>/dev/null
        /usr/bin/open "\(target.path)"
        rm -rf "\(newApp.deletingLastPathComponent().path)"
        """

        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("slidesense-update-\(UUID().uuidString).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path]
        try process.run()
    }

    // MARK: - Helpers

    private func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.installFailed("Could not unpack the update.")
        }
    }
}
