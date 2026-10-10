import Foundation

/// macOS's own clipboard sharing, part of Handoff. Where it is on, it offers every copy to the
/// other Macs as well, more slowly, and can put its copy in place of the one Baton delivered.
public enum UniversalClipboard {
    /// Where System Settings keeps the Handoff switch.
    public static let domain = "com.apple.coreservices.useractivityd"
    /// System Settings › General › AirDrop & Continuity (AirDrop & Handoff before macOS 27).
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.AirDrop-Handoff-Settings.extension")!
    static let settingsBundle = "/System/Library/ExtensionKit/Extensions/AirDropHandoffExtension.appex"

    /// Whether the settings leave Universal Clipboard on. The Handoff switch sets the first two
    /// keys; the third is a hidden one that turns off the clipboard alone. All default to on.
    public static func isOn(_ setting: (String) -> Bool? = { systemSetting($0) }) -> Bool {
        if setting("ClipboardSharingEnabled") == false { return false }
        return setting("ActivityAdvertisingAllowed") != false || setting("ActivityReceivingAllowed") != false
    }

    public static func systemSetting(_ key: String, domain: String = domain) -> Bool? {
        CFPreferencesAppSynchronize(domain as CFString)
        let value = CFPreferencesCopyAppValue(key as CFString, domain as CFString)
        // `defaults write … 0` stores a string.
        return (value as? NSNumber)?.boolValue ?? (value as? NSString)?.boolValue
    }

    /// The Macs to turn it off on. One Mac may keep it, for the iPhone's sake: it has no other
    /// Mac to share with. From two up, the clients give it up and the anchor keeps it.
    public static func turnOff(anchorOn: Bool, clientsOn: [String]) -> [String] {
        (anchorOn ? 1 : 0) + clientsOn.count >= 2 ? clientsOn.sorted() : []
    }

    /// The pane's name as this macOS shows it.
    public static var settingsPaneName: String {
        let bundle = Bundle(path: settingsBundle)
        let name = bundle?.localizedInfoDictionary?["CFBundleDisplayName"] ?? bundle?.infoDictionary?["CFBundleDisplayName"]
        return name as? String ?? "AirDrop & Handoff"
    }
}
