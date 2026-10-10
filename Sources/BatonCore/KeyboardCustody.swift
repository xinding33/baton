import Foundation

/// Keeps track of which Mac the shared keyboard is paired with, and decides when another Mac has
/// to pair with it afresh because the one that had it is gone. Times are in milliseconds.
public struct KeyboardCustody: Sendable {
    /// The machine the keyboard is paired with, as far as is known.
    public private(set) var holder: String?
    private var claimNotBefore: UInt64?
    private var failedClaims = 0
    /// The Mac that had the keyboard is gone, so a pairing any other Mac reports is out of date.
    private var abandoned = false

    /// How long a Mac that vanished without a word may take to come back with the keyboard still
    /// attached, and how long to wait when it was never seen attached anywhere.
    public static let lostGrace: UInt64 = 10000
    public static let unknownGrace: UInt64 = 3000

    public init() {}

    /// The keyboard is attached to `owner` right now.
    public mutating func attached(to owner: String) {
        holder = owner
        claimNotBefore = nil
        failedClaims = 0
        abandoned = false
    }

    /// A handoff began. Until the keyboard turns up somewhere, no Mac is known to hold its pairing.
    public mutating func handoffStarted() {
        holder = nil
    }

    /// `machine` disconnected. One that said goodbye first has let go of the keyboard; one that
    /// just vanished may be back in a moment with the keyboard still attached.
    public mutating func departed(_ machine: String, saidGoodbye: Bool, now: UInt64) {
        guard holder == machine else { return }
        holder = nil
        abandoned = true
        claimNotBefore = now + (saidGoodbye ? 0 : KeyboardCustody.lostGrace)
    }

    /// Whether a Mac should pair with the keyboard now, given that it is attached nowhere.
    /// While a connected Mac still holds its pairing, the keyboard is merely switched off or out
    /// of range, and returns to that Mac by itself. Once none does, it cannot come back unaided.
    public mutating func shouldClaim(now: UInt64, pairedSomewhere: Bool) -> Bool {
        if pairedSomewhere, !abandoned {
            claimNotBefore = nil
            return false
        }
        let notBefore = claimNotBefore ?? now + KeyboardCustody.unknownGrace
        claimNotBefore = notBefore
        return now >= notBefore
    }

    /// A claim failed, most likely because the keyboard is switched off. Returns how long to wait
    /// before the next one: a minute at first, then longer, up to ten minutes.
    public mutating func claimFailed() -> UInt64 {
        failedClaims += 1
        return min(60000 << UInt64(min(failedClaims - 1, 4)), 600_000)
    }
}
