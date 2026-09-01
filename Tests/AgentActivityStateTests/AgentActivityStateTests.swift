import XCTest
@testable import AgentActivityState

/// The first tests this repo has for anything outside Sources/HerdrKit.
///
/// A review measured why they were needed: while these types were nested inside the
/// ActivityKit-importing file they were untestable on Linux, and this repo has no app-side
/// unit bundle, so changing one line in LiveActivityController reintroduced a shipped
/// lock-screen defect in full and survived all 434 tests AND the UI receipt, because
/// XCUITest cannot see a Live Activity.
final class AgentActivityStateTests: XCTestCase {

    private func decode(_ json: String) throws -> AgentActivityState {
        try JSONDecoder().decode(AgentActivityState.self, from: Data(json.utf8))
    }

    // MARK: - additive-FIELD tolerance

    /// A payload from a build that predates `unconfirmedCount` must still decode. A
    /// stored-property default does NOT achieve this: Codable synthesis never consults it
    /// and throws keyNotFound, which ActivityKit answers by DROPPING the activity, after
    /// which it can never be reclaimed or ended. Only the hand-written decodeIfPresent does.
    func testAnOldPayloadWithoutUnconfirmedCountDecodesToZero() throws {
        let s = try decode(#"{"headline":"jarvis","status":"needsYou","needsYouCount":2,"workingCount":1,"totalCount":9}"#)
        XCTAssertEqual(s.unconfirmedCount, 0)
        XCTAssertEqual(s.needsYouCount, 2)
        XCTAssertEqual(s.status, .needsYou)
        XCTAssertNil(s.workingSince, "an absent workingSince is legitimately nil, not an error")
    }

    /// The tolerance is scoped to that ONE key. A genuinely malformed payload must still
    /// fail loudly rather than decoding into a plausible zero.
    ///
    /// `status` IS IN THIS LOOP DELIBERATELY, and it is the subtle member. This type treats
    /// an ABSENT status and an UNRECOGNISED status differently on purpose: an unrecognised
    /// word falls back to `needsYou` (see the additive-ENUM-CASE test below, because a new
    /// writer may ship a bucket this reader has never heard of), while an absent key is
    /// malformed and must throw. A review found the loop omitting it, and the mutant that
    /// exploits the omission — `decodeIfPresent(String.self, forKey: .status) ?? "needsYou"`
    /// — survived all 441 tests while COLLAPSING that distinction, decoding a status-less
    /// payload into the maximally attention-grabbing bucket. Tolerating an unknown value is
    /// not the same as inventing a missing one.
    func testAMissingRequiredKeyStillThrows() throws {
        for missing in ["headline", "status", "needsYouCount", "workingCount", "totalCount"] {
            var obj: [String: Any] = ["headline": "a", "status": "idle", "needsYouCount": 0,
                                      "workingCount": 0, "totalCount": 3]
            obj.removeValue(forKey: missing)
            let data = try JSONSerialization.data(withJSONObject: obj)
            XCTAssertThrowsError(try JSONDecoder().decode(AgentActivityState.self, from: data),
                                 "a payload missing \(missing) must not decode")
        }
        // And a wrong TYPE is still an error, not a coerced value. `status` is checked here
        // too: a non-string status is malformed input, NOT an unrecognised bucket, so the
        // enum fallback must not launder it into needsYou either.
        XCTAssertThrowsError(try decode(#"{"headline":"a","status":"idle","needsYouCount":"two","workingCount":0,"totalCount":3}"#))
        XCTAssertThrowsError(try decode(#"{"headline":"a","status":42,"needsYouCount":0,"workingCount":0,"totalCount":3}"#),
                             "a non-string status is malformed, not an unknown bucket")
    }

    // MARK: - additive-ENUM-CASE tolerance

    /// An unrecognised status word must not make the whole activity undecodable, which is
    /// the same drop-the-activity outcome as a missing key. It falls back to needsYou,
    /// matching HerdrKit's rule that something uninterpretable SURFACES rather than sinking:
    /// a wrongly attention-grabbing lock screen is recoverable, a dropped activity is not.
    func testAnUnknownStatusWordFallsBackInsteadOfThrowing() throws {
        let s = try decode(#"{"headline":"a","status":"wat","needsYouCount":1,"workingCount":0,"totalCount":3}"#)
        XCTAssertEqual(s.status, .needsYou, "an unknown bucket must surface, not sink")
        XCTAssertEqual(s.needsYouCount, 1, "the rest of the payload still decodes")
    }

    /// Every known word still maps to itself, so the fallback above cannot be hiding a
    /// broken mapping.
    func testEveryKnownStatusWordRoundTrips() throws {
        for (word, expected) in [("needsYou", AgentActivityStatus.needsYou), ("working", .working),
                                 ("idle", .idle), ("stopped", .stopped)] {
            let s = try decode(#"{"headline":"a","status":"\#(word)","needsYouCount":0,"workingCount":0,"totalCount":1}"#)
            XCTAssertEqual(s.status, expected, "status \(word) must map to itself")
        }
    }

    /// Encoding is still synthesized, so a state this build writes must be readable by it.
    func testRoundTripThroughEncodeAndDecode() throws {
        let original = AgentActivityState(headline: "jarvis", status: .working, needsYouCount: 2,
                                          unconfirmedCount: 1, workingCount: 3, totalCount: 9,
                                          workingSince: 1_788_200_000)
        let back = try JSONDecoder().decode(AgentActivityState.self,
                                            from: try JSONEncoder().encode(original))
        XCTAssertEqual(back, original)
    }

    // MARK: - summary wording

    /// The wording table. Duplicated on purpose in HerdrKit's AgentList tests, because the
    /// widget target cannot see HerdrKit and HerdrKit cannot see this target without putting
    /// these symbols in the app binary twice. If you change one table, change both.
    func testSummaryQualifiesUnconfirmedCounts() {
        func line(needsYou: Int, unconfirmed: Int, working: Int = 0,
                  status: AgentActivityStatus = .idle) -> String {
            AgentActivitySummary.line(.init(headline: "a", status: status, needsYouCount: needsYou,
                                            unconfirmedCount: unconfirmed, workingCount: working,
                                            totalCount: 9, workingSince: nil))
        }
        XCTAssertEqual(line(needsYou: 1, unconfirmed: 0), "1 need you")
        XCTAssertEqual(line(needsYou: 1, unconfirmed: 1), "1 may need you",
                       "all unconfirmed means the whole claim is a maybe")
        XCTAssertEqual(line(needsYou: 5, unconfirmed: 5), "5 may need you")
        XCTAssertEqual(line(needsYou: 2, unconfirmed: 1), "2 need you · 1 stale",
                       "mixed: lead with the fact, then name the doubt")
        // Falls through only when nothing is waiting.
        XCTAssertEqual(line(needsYou: 0, unconfirmed: 0, working: 2), "2 working")
        XCTAssertEqual(line(needsYou: 0, unconfirmed: 0, working: 0, status: .stopped), "Stopped")
    }

    /// An unconfirmed count exceeding the waiting count is nonsense the surfaces should
    /// survive rather than crash on, so pin the branch it lands in.
    func testAnOverlargeUnconfirmedCountStillReadsAsAMaybe() {
        let s = AgentActivityState(headline: "a", status: .needsYou, needsYouCount: 1,
                                   unconfirmedCount: 4, workingCount: 0, totalCount: 1,
                                   workingSince: nil)
        XCTAssertEqual(AgentActivitySummary.line(s), "1 may need you")
    }
}
