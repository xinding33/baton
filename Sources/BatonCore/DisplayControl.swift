// Display disconnection, carried over from Wink (github.com/xinding33/wink, Sources/WinkCore/DisplayControl.swift
// at 7e7315e) with its safety and recovery logic unchanged, apart from `Display.asleep`. Baton's additions
// are in DisplayPanel.swift.

import Foundation
import CoreGraphics
import Darwin

public struct Display: Codable, Equatable {
    public var id: UInt32
    public var uuid: String
    public var name: String
    public var builtIn: Bool
    public var active: Bool
    public var online: Bool
    public var mirrors: UInt32
    /// Dark because the Mac put its screens to sleep. Such a display is not `active`, but it is still there.
    public var asleep: Bool

    public init(id: UInt32, uuid: String, name: String, builtIn: Bool = false,
                active: Bool = true, online: Bool = true, mirrors: UInt32 = 0, asleep: Bool = false) {
        self.id = id; self.uuid = uuid; self.name = name; self.builtIn = builtIn
        self.active = active; self.online = online; self.mirrors = mirrors; self.asleep = asleep
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UInt32.self, forKey: .id)
        uuid = try c.decode(String.self, forKey: .uuid)
        name = try c.decode(String.self, forKey: .name)
        builtIn = try c.decode(Bool.self, forKey: .builtIn)
        active = try c.decode(Bool.self, forKey: .active)
        online = try c.decode(Bool.self, forKey: .online)
        mirrors = try c.decode(UInt32.self, forKey: .mirrors)
        // Absent from the records an earlier Baton or Wink wrote.
        asleep = try c.decodeIfPresent(Bool.self, forKey: .asleep) ?? false
    }
}

public struct DisplayError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum DisplayPolicy {
    public static func reasonToKeepOn(_ target: Display, among displays: [Display]) -> String? {
        if target.builtIn { return "The built-in screen stays on." }
        if !target.online { return "This display is no longer connected." }
        if target.mirrors != 0 || displays.contains(where: { $0.online && $0.mirrors == target.id }) {
            return "Turn off mirroring in System Settings before disconnecting this display." }
        if !displays.contains(where: { $0.id != target.id && $0.online && $0.active && $0.mirrors == 0 }) {
            return "Keep at least one active screen on." }
        return nil
    }
}

public protocol DisplayBackend {
    var available: Bool { get }
    func displays() throws -> [Display]
    func setEnabled(_ id: UInt32, _ enabled: Bool) throws
}

public final class NativeDisplayBackend: DisplayBackend {
    private typealias Configure = @convention(c) (CGDisplayConfigRef, UInt32, Bool) -> CGError
    private typealias CreateUUID = @convention(c) (UInt32) -> Unmanaged<CFUUID>?
    private let handle: UnsafeMutableRawPointer?
    private let configure: Configure?
    private let createUUID: CreateUUID?
    public var names: [UInt32: String] = [:]
    public var available: Bool { configure != nil && createUUID != nil }

    public init() {
        handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
        if let handle, let symbol = dlsym(handle, "SLSConfigureDisplayEnabled") ?? dlsym(handle, "CGSConfigureDisplayEnabled") {
            configure = unsafeBitCast(symbol, to: Configure.self)
        } else { configure = nil }
        if let handle, let symbol = dlsym(handle, "CGDisplayCreateUUIDFromDisplayID") {
            createUUID = unsafeBitCast(symbol, to: CreateUUID.self)
        } else { createUUID = nil }
    }

    public func displays() throws -> [Display] {
        var count: UInt32 = 0
        var ids = [UInt32](repeating: 0, count: 64)
        let error = CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count)
        guard error == .success else { throw DisplayError("Cannot read displays (\(error.rawValue)).") }
        return ids.prefix(Int(count)).map { id in
            let uuid = createUUID?(id).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String } ?? "id-\(id)"
            return Display(id: id, uuid: uuid, name: names[id] ?? (CGDisplayIsBuiltin(id) != 0 ? "Built-in Display" : "External Display \(id)"),
                           builtIn: CGDisplayIsBuiltin(id) != 0, active: CGDisplayIsActive(id) != 0,
                           online: true, mirrors: CGDisplayMirrorsDisplay(id), asleep: CGDisplayIsAsleep(id) != 0)
        }
    }

    public func setEnabled(_ id: UInt32, _ enabled: Bool) throws {
        guard let configure else { throw DisplayError("This macOS version does not provide the display disconnect API.") }
        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        guard begin == .success, let config else { throw DisplayError("Cannot start a display change (\(begin.rawValue)).") }
        let result = configure(config, id, enabled)
        guard result == .success else {
            CGCancelDisplayConfiguration(config)
            throw DisplayError("macOS rejected the display change (\(result.rawValue)).")
        }
        // Never change the user's permanent display preferences.
        let commit = CGCompleteDisplayConfiguration(config, .forSession)
        guard commit == .success else { throw DisplayError("Cannot apply the display change (\(commit.rawValue)).") }
    }
}

public struct RecoveryState: Codable {
    public var boot: String
    public var displays: [Display]
}

public final class RecoveryStore {
    public let url: URL
    public let boot: String
    public init(url: URL, boot: String = RecoveryStore.currentBoot()) { self.url = url; self.boot = boot }

    public static func currentBoot() -> String {
        var value = timeval(); var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &value, &size, nil, 0) == 0 else { return "unknown" }
        return "\(value.tv_sec)-\(value.tv_usec)"
    }

    public func load() throws -> [Display] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let state = try JSONDecoder().decode(RecoveryState.self, from: Data(contentsOf: url))
        // Display IDs may be reused after a reboot. Never replay an old ID.
        return state.boot == boot && boot != "unknown" ? state.displays : []
    }

    public func save(_ displays: [Display]) throws {
        guard boot != "unknown" else { throw DisplayError("Cannot identify this login's boot session.") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(RecoveryState(boot: boot, displays: displays)).write(to: url, options: .atomic)
    }
}

public struct RememberedDisplay: Codable, Equatable {
    public var uuid: String
    public var name: String
    public init(uuid: String, name: String) { self.uuid = uuid; self.name = name }
}

/// Displays the user chose to keep off. Keyed by UUID, which stays stable across reboots.
public final class PreferenceStore {
    public let url: URL
    public init(url: URL) { self.url = url }

    public func load() throws -> [RememberedDisplay] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try JSONDecoder().decode([RememberedDisplay].self, from: Data(contentsOf: url))
    }

    public func save(_ displays: [RememberedDisplay]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(displays).write(to: url, options: .atomic)
    }

    public func remember(_ display: Display) throws {
        try save(load().filter { $0.uuid != display.uuid } + [RememberedDisplay(uuid: display.uuid, name: display.name)])
    }

    public func forget(_ uuid: String) throws {
        let current = try load()
        if current.contains(where: { $0.uuid == uuid }) { try save(current.filter { $0.uuid != uuid }) }
    }
}

public final class DisplayController {
    public let backend: DisplayBackend
    public let store: RecoveryStore
    public let preferences: PreferenceStore?
    public let wait: (TimeInterval) -> Void
    public init(backend: DisplayBackend, store: RecoveryStore, preferences: PreferenceStore? = nil,
                wait: @escaping (TimeInterval) -> Void = Thread.sleep) {
        self.backend = backend; self.store = store; self.preferences = preferences; self.wait = wait
    }

    public func remembered() throws -> [Display] { try store.load() }

    private func isOnline(_ display: Display) throws -> Bool {
        try backend.displays().contains { $0.uuid == display.uuid }
    }

    private func awaitState(_ display: Display, online: Bool) throws -> Bool {
        for _ in 0..<20 {
            if try isOnline(display) == online { return true }
            wait(0.1)
        }
        return try isOnline(display) == online
    }

    public func disconnect(_ id: UInt32) throws {
        guard backend.available else { throw DisplayError("Display disconnection is unavailable on this macOS version.") }
        let current = try backend.displays()
        guard let target = current.first(where: { $0.id == id }) else { throw DisplayError("That display is no longer connected.") }
        if let reason = DisplayPolicy.reasonToKeepOn(target, among: current) { throw DisplayError(reason) }
        var saved = try store.load().filter { $0.uuid != target.uuid }
        saved.append(target)
        // The recovery helper must have the ID before it disappears from CoreGraphics.
        try store.save(saved)
        do {
            try backend.setEnabled(id, false)
            guard try awaitState(target, online: false) else {
                throw DisplayError("This display did not disconnect. It may not support software disconnection.")
            }
        } catch {
            // A failed transaction can still partially apply; attempt to reconnect.
            try? backend.setEnabled(id, true)
            if (try? awaitState(target, online: true)) == true { try? forget(target) }
            throw error
        }
        try preferences?.remember(target)
    }

    /// Reconnects a display at the user's request and stops keeping it off.
    public func turnOn(_ display: Display) throws {
        // Forget first so a screen-change re-apply cannot turn it straight back off.
        try preferences?.forget(display.uuid)
        try reconnect(display)
    }

    /// Turns off connected displays the user chose to keep off. Displays that must stay on are skipped.
    /// Returns failure messages keyed by display UUID.
    public func applyPreferences(skipping skipped: Set<String> = []) -> [String: String] {
        guard let preferences, backend.available else { return [:] }
        var failures: [String: String] = [:]
        do {
            for wanted in try preferences.load() where !skipped.contains(wanted.uuid) {
                let live = try backend.displays()
                guard let target = live.first(where: { $0.uuid == wanted.uuid && $0.active }),
                      DisplayPolicy.reasonToKeepOn(target, among: live) == nil else { continue }
                do { try disconnect(target.id) }
                catch { failures[wanted.uuid] = "\(wanted.name): \(error.localizedDescription)" }
            }
        } catch { failures[""] = error.localizedDescription }
        return failures
    }

    private func forget(_ display: Display) throws {
        try store.save(store.load().filter { $0.uuid != display.uuid })
    }

    public func reconnect(_ display: Display) throws {
        let live = try backend.displays()
        if live.contains(where: { $0.uuid == display.uuid }) { try forget(display); return }
        if live.contains(where: { $0.id == display.id && $0.uuid != display.uuid }) {
            // A physically replaced monitor must never inherit the old monitor's action.
            try forget(display)
            throw DisplayError("\(display.name) was replaced or reconnected with a different identity. Refresh the display list.")
        }
        try backend.setEnabled(display.id, true)
        guard try awaitState(display, online: true) else {
            throw DisplayError("\(display.name) has not reconnected. Check its cable and power, then try again.")
        }
        try forget(display)
    }

    public func reconnectAll() -> [String] {
        do {
            var errors: [String] = []
            for display in try store.load() {
                do { try reconnect(display) } catch { errors.append(error.localizedDescription) }
            }
            return errors
        } catch { return [error.localizedDescription] }
    }
}
