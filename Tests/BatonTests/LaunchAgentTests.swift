import BatonCore
import XCTest

/// The launch agent the app writes has to be the one `scripts/install-agent.sh` wrote before it,
/// since the Macs that were set up by that script keep theirs.
final class LaunchAgentTests: XCTestCase {
    /// The agent as `scripts/install-agent.sh` wrote it until Baton wrote its own.
    static func installAgentScriptPlist(home: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>com.xinding.baton</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(home)/Applications/Baton.app/Contents/MacOS/Baton</string>
            </array>
            <key>AssociatedBundleIdentifiers</key>
            <string>com.xinding.baton</string>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <dict>
                <key>SuccessfulExit</key>
                <false/>
            </dict>
            <key>ThrottleInterval</key>
            <integer>5</integer>
            <key>ProcessType</key>
            <string>Interactive</string>
            <key>LimitLoadToSessionType</key>
            <string>Aqua</string>
            <key>StandardErrorPath</key>
            <string>/dev/null</string>
        </dict>
        </plist>

        """
    }

    func testTheAppWritesTheAgentTheInstallScriptWrote() throws {
        let script = try PropertyListSerialization.propertyList(from: Data(Self.installAgentScriptPlist(home: "/Users/someone").utf8), format: nil)
        let ours = LaunchAgent.propertyList(executable: "/Users/someone/Applications/Baton.app/Contents/MacOS/Baton")
        XCTAssertEqual(script as? NSDictionary, ours as NSDictionary)
    }
}
