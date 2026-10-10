import Foundation
import Security

/// A version like 1.1.0, compared part by part, so 1.10 comes after 1.9 and 1.1 equals 1.1.0.
public struct Version: Comparable, CustomStringConvertible, Sendable {
    public let parts: [Int]
    public let description: String

    /// Parses "1.1.0" or a tag like "v1.1.0".
    public init?(_ string: String) {
        let text = string.hasPrefix("v") ? String(string.dropFirst()) : string
        let parts = text.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.allSatisfy({ $0 != nil }) else { return nil }
        self.parts = parts.compactMap { $0 }
        description = text
    }

    private func padded(to count: Int) -> [Int] {
        parts + Array(repeating: 0, count: max(0, count - parts.count))
    }

    public static func == (a: Version, b: Version) -> Bool {
        let count = max(a.parts.count, b.parts.count)
        return a.padded(to: count) == b.padded(to: count)
    }

    public static func < (a: Version, b: Version) -> Bool {
        let count = max(a.parts.count, b.parts.count)
        return a.padded(to: count).lexicographicallyPrecedes(b.padded(to: count))
    }
}

/// How a copy of Baton was made. `scripts/deploy.sh` signs its builds with the same Developer ID
/// as the releases, so the signature does not tell the two apart; `BatonBuild` in Info.plist does.
public enum BuildKind: String, Sendable {
    /// Built, notarized and published by `scripts/release.sh`. Updates itself.
    case release
    /// Anything else. Never replaced by a release, whatever its version.
    case development
}

/// A copy of Baton: its version and how it was made.
public struct Build: Equatable, CustomStringConvertible, Sendable {
    public var version: Version
    public var kind: BuildKind

    public init(version: Version, kind: BuildKind) {
        self.version = version
        self.kind = kind
    }

    /// Reads an Info.plist. A copy that does not say it is a release is a development build.
    public init(info: [String: Any]?) {
        version = (info?["CFBundleShortVersionString"] as? String).flatMap(Version.init) ?? Version("0.0.0")!
        kind = (info?[Build.kindKey] as? String).flatMap(BuildKind.init) ?? .development
    }

    public static let kindKey = "BatonBuild"
    /// The copy that is running.
    public static let current = Build(info: Bundle.main.infoDictionary)

    public var description: String {
        kind == .release ? "\(version)" : "\(version) (development build)"
    }
}

/// The decisions about updating that do not need a network or a disk.
public enum UpdatePolicy {
    public static let checkInterval: TimeInterval = 24 * 60 * 60

    /// Why `build` does not replace itself with release `version`, or nil if it does.
    /// A development build never does, and nothing is ever replaced by an older or equal version.
    public static func refusal(of version: Version, for build: Build) -> String? {
        if build.kind == .development { return "runs a development build, which doesn't update itself" }
        if version <= build.version { return "already has version \(build.version)" }
        return nil
    }

    /// Whether the daily look at GitHub is due.
    public static func isCheckDue(last: Date, now: Date) -> Bool {
        now.timeIntervalSince(last) > checkInterval
    }
}

public enum UpdateError: LocalizedError, Equatable {
    case noDownload, httpStatus(Int), unzipFailed, badSignature, wrongVersion, notARelease, notWritable(String)

    public var errorDescription: String? {
        switch self {
        case .noDownload: return "The latest release has no Baton download."
        case .httpStatus(let status): return "GitHub responded with HTTP status \(status)."
        case .unzipFailed: return "The download couldn't be unzipped."
        case .badSignature: return "The download isn't signed by Baton's developer."
        case .wrongVersion: return "The download isn't the version it should be."
        case .notARelease: return "The download isn't a release build."
        case .notWritable(let path): return "Baton can't replace itself at \(path)."
        }
    }
}

/// A release published on GitHub.
public struct Release: Sendable {
    public let version: Version
    /// The release notes.
    public let page: URL
    /// Baton-VERSION.zip, as published by .github/workflows/release.yml.
    public let download: URL

    /// Parses a response from GitHub's latest release API.
    public init(gitHubJSON data: Data) throws {
        struct Response: Decodable {
            struct Asset: Decodable {
                let name: String
                let browserDownloadUrl: URL
            }
            let tagName: String
            let htmlUrl: URL
            let assets: [Asset]
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let response = try decoder.decode(Response.self, from: data)
        guard let version = Version(response.tagName),
              let asset = response.assets.first(where: { $0.name == "Baton-\(version).zip" })
        else { throw UpdateError.noDownload }
        self.version = version
        page = response.htmlUrl
        download = asset.browserDownloadUrl
    }
}

/// Fetches Baton's GitHub releases and swaps one in for the running copy. A download is installed
/// only if it is the release build it claims to be and is signed to satisfy the designated
/// requirement of the app it replaces. When to install, and on which Macs, is `UpdateLeader`'s job.
public enum Updater {
    public static let releasesPage = URL(string: "https://github.com/xinding33/baton/releases")!
    public static let latestReleaseURL = URL(string: "https://api.github.com/repos/xinding33/baton/releases/latest")!

    /// Where the release workflow publishes `version`. Every Mac can work this out for itself, so
    /// a Mac told to move to a version needs nothing but the number.
    public static func downloadURL(for version: Version) -> URL {
        releasesPage.appendingPathComponent("download/v\(version)/Baton-\(version).zip")
    }

    /// The latest release, or nil while nothing has been released.
    public static func latestRelease() async throws -> Release? {
        var request = URLRequest(url: latestReleaseURL, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 404 { return nil }
        try check(response)
        return try Release(gitHubJSON: data)
    }

    /// Downloads release `version` into `folder` and checks that it could replace `app`, without
    /// touching `app`. Returns the ZIP, which `install` takes later.
    public static func download(_ version: Version, into folder: URL, toReplace app: URL) async throws -> URL {
        try checkReplaceable(app)
        let files = FileManager.default
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        let zip = folder.appendingPathComponent("Baton-\(version).zip")
        if (try? verify(zip: zip, version: version, toReplace: app)) != nil { return zip }

        let (downloaded, response) = try await URLSession.shared.download(from: downloadURL(for: version))
        defer { try? files.removeItem(at: downloaded) }
        try check(response)
        try? files.removeItem(at: zip)
        try files.moveItem(at: downloaded, to: zip)
        do {
            try verify(zip: zip, version: version, toReplace: app)
        } catch {
            try? files.removeItem(at: zip)
            throw error
        }
        return zip
    }

    /// Unzips `zip` somewhere temporary and checks it as `install` would.
    public static func verify(zip: URL, version: Version, toReplace app: URL) throws {
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent("baton-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        _ = try unpack(zip: zip, version: version, toReplace: app, into: staging)
    }

    /// Unzips Baton.app from `zip`, checks that it's release `version` and is signed to satisfy
    /// `app`'s designated requirement, then swaps it in for `app`. Restart afterwards to run it.
    public static func install(zip: URL, version: Version, replacing app: URL) throws {
        let files = FileManager.default
        // On the same volume as the app, so the swap is a rename.
        let staging = try files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)
        defer { try? files.removeItem(at: staging) }
        let update = try unpack(zip: zip, version: version, toReplace: app, into: staging)
        _ = try files.replaceItemAt(app, withItemAt: update)
    }

    /// Fails if this user cannot swap another bundle in for `app`.
    public static func checkReplaceable(_ app: URL) throws {
        let files = FileManager.default
        guard app.pathExtension == "app", files.isWritableFile(atPath: app.path),
              files.isWritableFile(atPath: app.deletingLastPathComponent().path)
        else { throw UpdateError.notWritable(app.path) }
    }

    private static func unpack(zip: URL, version: Version, toReplace app: URL, into staging: URL) throws -> URL {
        let requirement = try designatedRequirement(of: app)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zip.path, staging.path]
        unzip.standardError = FileHandle.nullDevice
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { throw UpdateError.unzipFailed }

        let update = staging.appendingPathComponent("Baton.app")
        guard satisfies(update, requirement) else { throw UpdateError.badSignature }
        let build = Build(info: NSDictionary(contentsOf: update.appendingPathComponent("Contents/Info.plist")) as? [String: Any])
        guard build.version == version else { throw UpdateError.wrongVersion }
        guard build.kind == .release else { throw UpdateError.notARelease }
        return update
    }

    /// Whether `app` is signed with a Developer ID, as releases are.
    public static func isDeveloperIDSigned(_ app: URL) -> Bool {
        let developerID = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(developerID as CFString, [], &requirement) == errSecSuccess,
              let requirement
        else { return false }
        return satisfies(app, requirement)
    }

    /// How `app` is signed, for `Baton update-check`.
    public static func signature(of app: URL) -> (developerID: Bool, hardenedRuntime: Bool, notarized: Bool) {
        var code: SecStaticCode?
        var information: CFDictionary?
        var flags: UInt32 = 0
        if SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
           SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess {
            flags = ((information as? [String: Any])?[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        }
        var notarized: SecRequirement?
        SecRequirementCreateWithString("notarized" as CFString, [], &notarized)
        return (isDeveloperIDSigned(app), flags & SecCodeSignatureFlags.runtime.rawValue != 0, notarized.map { satisfies(app, $0) } ?? false)
    }

    static func designatedRequirement(of app: URL) throws -> SecRequirement {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement
        else { throw UpdateError.badSignature }
        return requirement
    }

    static func satisfies(_ app: URL, _ requirement: SecRequirement) -> Bool {
        var code: SecStaticCode?
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return false }
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    private static func check(_ response: URLResponse) throws {
        if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
            throw UpdateError.httpStatus(status)
        }
    }
}
