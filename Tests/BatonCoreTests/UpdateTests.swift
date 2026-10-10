import Foundation
import XCTest
@testable import BatonCore

final class UpdateTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func version(_ string: String) throws -> Version { try XCTUnwrap(Version(string)) }

    func testVersionsCompareNumerically() throws {
        XCTAssertLessThan(try version("1.9.0"), try version("1.10.0"))
        XCTAssertLessThan(try version("1.1.0"), try version("v1.1.1"))
        XCTAssertEqual(try version("v1.1"), try version("1.1.0"))
        XCTAssertEqual(try version("v1.1.0").description, "1.1.0")
        XCTAssertNil(Version("1.1.0-beta"))
        XCTAssertNil(Version(""))
    }

    func testACopyIsADevelopmentBuildUnlessItSaysItIsARelease() throws {
        XCTAssertEqual(Build(info: ["CFBundleShortVersionString": "1.2.0", "BatonBuild": "release"]), Build(version: try version("1.2.0"), kind: .release))
        XCTAssertEqual(Build(info: ["CFBundleShortVersionString": "1.2.0"]).kind, .development)
        XCTAssertEqual(Build(info: ["CFBundleShortVersionString": "1.2.0", "BatonBuild": "nightly"]).kind, .development)
        // Run straight from the build folder, there is no Info.plist at all.
        XCTAssertEqual(Build(info: nil), Build(version: try version("0.0.0"), kind: .development))
        XCTAssertEqual(Build(version: try version("1.2.0"), kind: .development).description, "1.2.0 (development build)")
    }

    func testOnlyAReleaseBuildTakesAReleaseAndOnlyANewerOne() throws {
        let release = Build(version: try version("1.2.0"), kind: .release)
        XCTAssertNil(UpdatePolicy.refusal(of: try version("1.2.1"), for: release))
        XCTAssertNil(UpdatePolicy.refusal(of: try version("1.10"), for: release))
        XCTAssertNotNil(UpdatePolicy.refusal(of: try version("1.2.0"), for: release), "an equal release")
        XCTAssertNotNil(UpdatePolicy.refusal(of: try version("1.2"), for: release), "an equal release, written differently")
        XCTAssertNotNil(UpdatePolicy.refusal(of: try version("1.1.9"), for: release), "an older release")

        // scripts/deploy.sh signs with the releases' Developer ID, so only this keeps its builds in place.
        let development = Build(version: try version("1.2.0"), kind: .development)
        for candidate in ["1.1.0", "1.2.0", "1.2.1", "99.0.0"] {
            XCTAssertNotNil(UpdatePolicy.refusal(of: try version(candidate), for: development), candidate)
        }
    }

    func testTheCheckIsDueOnceADay() {
        let now = Date()
        XCTAssertTrue(UpdatePolicy.isCheckDue(last: .distantPast, now: now))
        XCTAssertTrue(UpdatePolicy.isCheckDue(last: now.addingTimeInterval(-25 * 60 * 60), now: now))
        XCTAssertFalse(UpdatePolicy.isCheckDue(last: now.addingTimeInterval(-23 * 60 * 60), now: now))
    }

    func testReleaseFindsTheZip() throws {
        let json = """
            {"tag_name": "v1.2.0", "html_url": "https://github.com/xinding33/baton/releases/tag/v1.2.0",
             "assets": [
               {"name": "notes.txt", "browser_download_url": "https://example.com/notes.txt"},
               {"name": "Baton-1.2.0.zip",
                "browser_download_url": "https://github.com/xinding33/baton/releases/download/v1.2.0/Baton-1.2.0.zip"}]}
            """
        let release = try Release(gitHubJSON: Data(json.utf8))
        XCTAssertEqual(release.version, Version("1.2.0"))
        XCTAssertEqual(release.page.absoluteString, "https://github.com/xinding33/baton/releases/tag/v1.2.0")
        // Every Mac works the address out from the version alone, and has to arrive at the same one.
        XCTAssertEqual(release.download, Updater.downloadURL(for: release.version))

        let noZip = #"{"tag_name": "v1.2.0", "html_url": "https://example.com", "assets": []}"#
        XCTAssertThrowsError(try Release(gitHubJSON: Data(noZip.utf8))) {
            XCTAssertEqual($0 as? UpdateError, .noDownload)
        }
    }

    func testInstallsUpdateSignedLikeTheApp() throws {
        let app = try makeApp(in: "installed", version: "1.1.0")
        let update = try zip(makeApp(in: "update", version: "1.2.0"))
        try Updater.verify(zip: update, version: version("1.2.0"), toReplace: app)
        XCTAssertEqual(installedVersion(of: app), "1.1.0", "checking a download leaves the app alone")
        try Updater.install(zip: update, version: version("1.2.0"), replacing: app)
        XCTAssertEqual(installedVersion(of: app), "1.2.0")
    }

    func testReplacesTheAppWhereverItIs() throws {
        let app = try makeApp(in: "Some Folder/Applications", version: "1.1.0")
        try Updater.install(zip: zip(makeApp(in: "update", version: "1.2.0")), version: version("1.2.0"), replacing: app)
        XCTAssertEqual(installedVersion(of: app), "1.2.0")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: app.deletingLastPathComponent().path), ["Baton.app"])
    }

    func testRejectsUpdateSignedDifferently() throws {
        let app = try makeApp(in: "installed", version: "1.1.0")
        let update = try zip(makeApp(in: "update", identifier: "test.impostor", version: "1.2.0"))
        XCTAssertThrowsError(try Updater.install(zip: update, version: version("1.2.0"), replacing: app)) {
            XCTAssertEqual($0 as? UpdateError, .badSignature)
        }
        XCTAssertEqual(installedVersion(of: app), "1.1.0")
    }

    func testRejectsUpdateOfTheWrongVersion() throws {
        let app = try makeApp(in: "installed", version: "1.1.0")
        let update = try zip(makeApp(in: "update", version: "1.0.0"))
        XCTAssertThrowsError(try Updater.install(zip: update, version: version("1.2.0"), replacing: app)) {
            XCTAssertEqual($0 as? UpdateError, .wrongVersion)
        }
        XCTAssertEqual(installedVersion(of: app), "1.1.0")
    }

    func testRejectsADevelopmentBuildAsAnUpdate() throws {
        let app = try makeApp(in: "installed", version: "1.1.0")
        let update = try zip(makeApp(in: "update", version: "1.2.0", kind: nil))
        XCTAssertThrowsError(try Updater.install(zip: update, version: version("1.2.0"), replacing: app)) {
            XCTAssertEqual($0 as? UpdateError, .notARelease)
        }
        XCTAssertEqual(installedVersion(of: app), "1.1.0")
    }

    func testRejectsModifiedUpdate() throws {
        let app = try makeApp(in: "installed", version: "1.1.0")
        let update = try makeApp(in: "update", version: "1.2.0")
        try Data("tampered".utf8).write(to: update.appendingPathComponent("Contents/MacOS/Baton"))
        XCTAssertThrowsError(try Updater.install(zip: zip(update), version: version("1.2.0"), replacing: app)) {
            XCTAssertEqual($0 as? UpdateError, .badSignature)
        }
        XCTAssertEqual(installedVersion(of: app), "1.1.0")
    }

    func testACopyThatCannotBeReplacedSaysSoBeforeAnythingIsDownloaded() throws {
        let app = try makeApp(in: "installed", version: "1.1.0")
        XCTAssertNoThrow(try Updater.checkReplaceable(app))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: app.deletingLastPathComponent().path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: app.deletingLastPathComponent().path) }
        XCTAssertThrowsError(try Updater.checkReplaceable(app)) {
            XCTAssertEqual($0 as? UpdateError, .notWritable(app.path))
        }
        // Run from the build folder, Baton is not an app bundle and has nothing to swap.
        XCTAssertThrowsError(try Updater.checkReplaceable(folder))
    }

    func testSourceBuildIsNotDeveloperIDSigned() throws {
        let app = try makeApp(in: "installed", version: "1.1.0")
        XCTAssertFalse(Updater.isDeveloperIDSigned(app))
        let signature = Updater.signature(of: app)
        XCTAssertFalse(signature.developerID)
        XCTAssertFalse(signature.hardenedRuntime)
        XCTAssertFalse(signature.notarized)
    }

    // MARK: - Fixtures

    /// An ad-hoc signed Baton.app whose designated requirement is just its identifier.
    private func makeApp(in name: String, identifier: String = "test.baton", version: String, kind: String? = "release") throws -> URL {
        let app = folder.appendingPathComponent(name).appendingPathComponent("Baton.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/usr/bin/true", toPath: macOS.appendingPathComponent("Baton").path)
        let info: NSMutableDictionary = [
            "CFBundleIdentifier": identifier, "CFBundleExecutable": "Baton",
            "CFBundlePackageType": "APPL", "CFBundleShortVersionString": version,
        ]
        info["BatonBuild"] = kind
        try info.write(to: app.appendingPathComponent("Contents/Info.plist"))
        try run("/usr/bin/codesign", "--force", "--sign", "-", "-r=designated => identifier \"\(identifier)\"", app.path)
        return app
    }

    /// Zips `app` the way scripts/release.sh does.
    private func zip(_ app: URL) throws -> URL {
        let zip = app.deletingLastPathComponent().appendingPathComponent("Baton.zip")
        try run("/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app.path, zip.path)
        return zip
    }

    private func run(_ path: String, _ arguments: String...) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(path) \(arguments)")
    }

    private func installedVersion(of app: URL) -> String? {
        NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
    }
}
