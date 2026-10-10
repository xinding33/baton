import CryptoKit
import Foundation

/// The code a person carries from one Mac to the next to pair them: generated on one, typed
/// into the others. Every Mac turns the same code into the same `secret.key`.
///
/// The secret is a TLS pre-shared key with no key exchange on top (`Net.tlsParameters`). Someone
/// who records one handshake can therefore try codes against it for as long as they like, on
/// their own hardware, and a code found later opens everything recorded earlier. Nothing can
/// slow that search down from here, so the code has to be out of its reach by size alone: 24
/// random characters from a 32-letter alphabet, 120 bits. A code short enough to read out in
/// one breath would need a password-authenticated key exchange instead.
public enum PairingCode {
    /// No 0, O, 1 or I, which read alike. The same alphabet as Ripple's codes.
    static let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    /// How many characters carry the secret. Each is worth five bits.
    public static let randomCharacters = 24
    /// With the check character, which is last.
    public static let length = randomCharacters + 1
    private static let groupSize = 5

    public enum Problem: Error, Equatable, CustomStringConvertible {
        case empty
        case foreignCharacter(Character)
        case wrongLength(Int)
        case mistyped

        public var description: String {
            switch self {
            case .empty:
                return "Generate a code here, or type in the one from another Mac."
            case let .foreignCharacter(character):
                let lookalikes: [Character: String] = ["0": "the digit 0", "O": "the letter O", "1": "the digit 1", "I": "the letter I"]
                if let name = lookalikes[character] {
                    return "A code never contains \(name). Check that character against the other Mac."
                }
                return "A code is made of letters and digits only, not “\(character)”."
            case let .wrongLength(count):
                return "A code has \(length) letters and digits. This one has \(count)."
            case .mistyped:
                return "This code has a typing mistake in it. Compare it with the other Mac, or use Copy there."
            }
        }
    }

    /// A new code, drawn from the system's cryptographic random number generator.
    public static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        return generate(using: &generator)
    }

    static func generate<Generator: RandomNumberGenerator>(using generator: inout Generator) -> String {
        let random = (0..<randomCharacters).map { _ in alphabet.randomElement(using: &generator)! }
        return format(String(random + [checkCharacter(for: random)]))
    }

    /// The code as its characters alone: upper case, without the dashes and spaces it is shown
    /// and typed with.
    public static func normalize(_ text: String) -> String {
        String(text.uppercased().filter { !$0.isWhitespace && !"-–—_.".contains($0) })
    }

    /// The code as it is shown: groups of five with dashes between.
    public static func format(_ text: String) -> String {
        let characters = Array(normalize(text))
        return stride(from: 0, to: characters.count, by: groupSize)
            .map { String(characters[$0..<min($0 + groupSize, characters.count)]) }
            .joined(separator: "-")
    }

    /// What is wrong with a code as typed, or nil if it is one this app could have generated.
    public static func problem(with text: String) -> Problem? {
        let characters = Array(normalize(text))
        if characters.isEmpty { return .empty }
        if let foreign = characters.first(where: { !alphabet.contains($0) }) { return .foreignCharacter(foreign) }
        guard characters.count == length else { return .wrongLength(characters.count) }
        return checkCharacter(for: Array(characters.dropLast())) == characters.last ? nil : .mistyped
    }

    /// The last character of a code, worked out from the others (Luhn's algorithm for 32
    /// symbols). It catches any single wrong character, so a slip of the finger is reported as
    /// one, and not later as a Mac that cannot be reached.
    static func checkCharacter(for characters: [Character]) -> Character {
        let count = alphabet.count
        var factor = 2
        var sum = 0
        for character in characters.reversed() {
            let addend = factor * (alphabet.firstIndex(of: character) ?? 0)
            factor = factor == 2 ? 1 : 2
            sum += addend / count + addend % count
        }
        return alphabet[(count - sum % count) % count]
    }

    /// The 32 bytes kept in `secret.key` on every Mac that was given this code.
    ///
    /// HKDF is enough to get there: it spreads the code's 120 bits over the key, and a slow
    /// password hash would add nothing a search of that size could feel.
    public static func secret(from text: String) throws -> Data {
        if let problem = problem(with: text) { throw problem }
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(normalize(text).utf8)),
            salt: Data("baton-pairing-v1".utf8),
            info: Data("secret.key".utf8),
            outputByteCount: 32
        )
        return key.withUnsafeBytes { Data($0) }
    }
}
