import XCTest
@testable import BatonCore

final class PairingTests: XCTestCase {
    /// Hands out the same numbers every time, so a generated code can be written down here.
    struct Counter: RandomNumberGenerator {
        var value: UInt64 = 0
        mutating func next() -> UInt64 {
            value &+= 0x9E37_79B9_7F4A_7C15
            return value
        }
    }

    func testAGeneratedCodeIsFiveGroupsOfFiveFromTheAlphabet() {
        let code = PairingCode.generate()
        let groups = code.split(separator: "-")
        XCTAssertEqual(groups.count, 5)
        XCTAssertTrue(groups.allSatisfy { $0.count == 5 })
        XCTAssertTrue(PairingCode.normalize(code).allSatisfy(PairingCode.alphabet.contains))
        XCTAssertNil(PairingCode.problem(with: code))
        // 24 characters of five bits each carry the secret; the 25th only checks them.
        XCTAssertEqual(PairingCode.randomCharacters * 5, 120)
        XCTAssertEqual(PairingCode.alphabet.count, 32)
        XCTAssertEqual(Set(PairingCode.alphabet).count, 32)
    }

    func testCodesDoNotRepeat() {
        XCTAssertEqual(Set((0..<200).map { _ in PairingCode.generate() }).count, 200)
    }

    func testEveryCharacterOfTheCodeComesFromTheGenerator() {
        var first = Counter(), second = Counter(value: 0x1234_5678_9ABC_DEF0)
        let a = PairingCode.generate(using: &first), b = PairingCode.generate(using: &second)
        XCTAssertNotEqual(a, b)
        var again = Counter()
        XCTAssertEqual(PairingCode.generate(using: &again), a)
    }

    func testACodeIsReadHoweverItIsTyped() throws {
        let code = PairingCode.generate()
        let secret = try PairingCode.secret(from: code)
        let plain = PairingCode.normalize(code)
        XCTAssertEqual(plain.count, 25)
        for typed in [plain, plain.lowercased(), "  \(code.lowercased())\n", code.replacingOccurrences(of: "-", with: " "), code.replacingOccurrences(of: "-", with: " – ")] {
            XCTAssertEqual(try PairingCode.secret(from: typed), secret, typed)
        }
        XCTAssertEqual(PairingCode.format(plain.lowercased()), code)
    }

    func testTheSecretIsWhatSecretKeyHolds() throws {
        let secret = try PairingCode.secret(from: "AAAAA-AAAAA-AAAAA-AAAAA-AAAAA")
        XCTAssertEqual(secret.count, 32, "secret.key must hold at least 32 bytes")
        // HKDF-SHA256 over the 25 characters, worked out separately. A change here would unpair
        // every Mac that was paired by code.
        XCTAssertEqual(secret.map { String(format: "%02x", $0) }.joined(), "7fb85bdf018a5d7c3d7bf61f5200f249766409b1a61ad884ee5f0871c407577b")
        XCTAssertNotEqual(try PairingCode.secret(from: PairingCode.generate()), try PairingCode.secret(from: PairingCode.generate()))
    }

    func testAnyOneWrongCharacterIsCaught() {
        let code = Array(PairingCode.normalize(PairingCode.generate()))
        for index in code.indices {
            for replacement in PairingCode.alphabet where replacement != code[index] {
                var typed = code
                typed[index] = replacement
                XCTAssertEqual(PairingCode.problem(with: String(typed)), .mistyped, "\(String(typed))")
            }
        }
    }

    func testWhatIsWrongWithACodeIsSaid() {
        let code = PairingCode.normalize(PairingCode.generate())
        XCTAssertEqual(PairingCode.problem(with: ""), .empty)
        XCTAssertEqual(PairingCode.problem(with: " - "), .empty)
        XCTAssertEqual(PairingCode.problem(with: String(code.dropLast())), .wrongLength(24))
        XCTAssertEqual(PairingCode.problem(with: code + "A"), .wrongLength(26))
        XCTAssertEqual(PairingCode.problem(with: "0" + code.dropFirst()), .foreignCharacter("0"))
        XCTAssertEqual(PairingCode.problem(with: "é" + code.dropFirst()), .foreignCharacter("É"))
        XCTAssertTrue(PairingCode.Problem.foreignCharacter("0").description.contains("the digit 0"))
        XCTAssertTrue(PairingCode.Problem.foreignCharacter("O").description.contains("the letter O"))
        XCTAssertThrowsError(try PairingCode.secret(from: String(code.dropLast())))
    }
}
