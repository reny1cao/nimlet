import XCTest

/// The pre-shared key is the only thing standing between a stranger on the
/// network and synthetic keystrokes on the user's Mac, and the salt it is
/// derived from has already broken every paired phone once.
final class PreSharedKeyTests: XCTestCase {

    func testTheSameCodeAlwaysDerivesTheSameKey() {
        XCTAssertEqual(NimletTransport.pskData(forCode: "ABC234"),
                       NimletTransport.pskData(forCode: "ABC234"))
    }

    func testTheDerivedKeyIsAFullSHA256Digest() {
        XCTAssertEqual(NimletTransport.pskData(forCode: "ABC234").count, 32)
    }

    func testTypingTheCodeInLowercaseDerivesTheSameKey() {
        XCTAssertEqual(NimletTransport.pskData(forCode: "abc234"),
                       NimletTransport.pskData(forCode: "ABC234"))
    }

    func testSpacesDashesAndUnderscoresInTheTypedCodeDoNotChangeTheKey() {
        let expected = NimletTransport.pskData(forCode: "ABC234")
        for typed in [" ABC 234 ", "ABC-234", "abc_234", "a b c 2 3 4"] {
            XCTAssertEqual(NimletTransport.pskData(forCode: typed), expected,
                           "\(typed) should derive the same key")
        }
    }

    func testTwoDifferentCodesDeriveDifferentKeys() {
        XCTAssertNotEqual(NimletTransport.pskData(forCode: "ABC234"),
                          NimletTransport.pskData(forCode: "ABC235"))
    }

    func testAnEmptyCodeStillDerivesAKeyRatherThanTrapping() {
        XCTAssertEqual(NimletTransport.pskData(forCode: "").count, 32)
    }
}

/// A mistyped character, a wrong code, a version mismatch and an unreachable
/// Mac all surface as the same TLS handshake failure, so the only one of the
/// four that can be named is the mistyped character — and only here.
final class PairingCodeTests: XCTestCase {

    func testNormalizeUppercasesAndStripsTheSeparatorsPeopleType() {
        XCTAssertEqual(PairingCode.normalize(" abc-234 "), "ABC234")
        XCTAssertEqual(PairingCode.normalize("a_b c\t2\n34"), "ABC234")
    }

    func testAnEmptyCodeIsReportedAsEmpty() {
        XCTAssertEqual(PairingCode.validate(""), .empty)
    }

    func testACodeOfNothingButSeparatorsIsReportedAsEmpty() {
        XCTAssertEqual(PairingCode.validate("  --  "), .empty)
    }

    func testATooShortCodeReportsHowManyCharactersItHas() {
        XCTAssertEqual(PairingCode.validate("ABC"), .wrongLength(3))
    }

    func testATooLongCodeReportsHowManyCharactersItHas() {
        XCTAssertEqual(PairingCode.validate("ABC2345"), .wrongLength(7))
    }

    func testSeparatorsAreNotCountedTowardsTheLength() {
        XCTAssertNil(PairingCode.validate("ABC-234"))
    }

    func testTheDigitsThatLookLikeLettersAreRejectedByName() {
        XCTAssertEqual(PairingCode.validate("ABC230"), .illegalCharacters("0"))
        XCTAssertEqual(PairingCode.validate("ABC231"), .illegalCharacters("1"))
    }

    func testTheLettersThatLookLikeDigitsAreRejectedByName() {
        XCTAssertEqual(PairingCode.validate("ABC23O"), .illegalCharacters("O"))
        XCTAssertEqual(PairingCode.validate("ABC23I"), .illegalCharacters("I"))
    }

    func testSeveralIllegalCharactersAreListedOnceEachInOrder() {
        XCTAssertEqual(PairingCode.validate("O1I0OO"), .illegalCharacters("0, 1, I, O"))
    }

    func testAnIllegalCharacterIsReportedEvenWhenTheLengthIsAlsoWrong() {
        // Naming the character is more use than naming the length: someone who
        // typed O for 0 will retype the same thing if all they are told is that
        // the code is too short.
        XCTAssertEqual(PairingCode.validate("O"), .illegalCharacters("O"))
    }

    func testAWellFormedCodeHasNoProblem() {
        XCTAssertNil(PairingCode.validate("ABC234"))
        XCTAssertTrue(PairingCode.isValid("abc 234"))
    }

    func testEveryProblemExplainsItselfInWordsAUserCanActOn() {
        for problem: PairingCode.Problem in [.empty, .wrongLength(3), .illegalCharacters("O")] {
            XCTAssertFalse(problem.message.isEmpty)
        }
        XCTAssertTrue(PairingCode.Problem.wrongLength(3).message.contains("3"))
        XCTAssertTrue(PairingCode.Problem.illegalCharacters("O").message.contains("O"))
    }

    func testTheAlphabetContainsNoneOfTheAmbiguousCharacters() {
        for ambiguous: Character in ["O", "0", "I", "1"] {
            XCTAssertFalse(PairingCode.alphabet.contains(ambiguous))
        }
        XCTAssertEqual(PairingCode.alphabet.count, 32)
    }

    func testAGeneratedCodeIsAlwaysOneThatValidates() {
        for _ in 0..<200 {
            let code = NimletTransport.newPairingCode()
            XCTAssertEqual(code.count, PairingCode.length)
            XCTAssertNil(PairingCode.validate(code), "\(code) should be well formed")
        }
    }

    func testGeneratedCodesAreNotAllTheSame() {
        let codes = Set((0..<64).map { _ in NimletTransport.newPairingCode() })
        XCTAssertGreaterThan(codes.count, 1)
    }
}
