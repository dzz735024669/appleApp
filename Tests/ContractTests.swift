import Foundation
import XCTest
@testable import WorkbenchCore

final class ContractTests: XCTestCase {
    func testClipboardCandidatesAllowMissingEventTimeForPreview() throws {
        let json = """
        {"request_id":"5666bafd-464d-4cfa-b782-5484e093580e","reference_time":"2026-11-18T10:00:00+08:00",
         "timezone":"Asia/Shanghai","model":"mimo-v2.6-flash","reason":"需要补充时间","candidates":[
          {"candidate_id":"5666bafd-464d-4cfa-b782-5484e093580f","fields":{"kind":"event","title":"考试","target_at":null},
           "evidence":"月底考试","missing_fields":["target_at"],"warnings":["请确认具体日期"],"status":"needs_details"}]}
        """
        let response = try WorkbenchAPI.decoder().decode(ClipboardParse.self, from: Data(json.utf8))
        let candidate = try XCTUnwrap(response.candidates.first)
        XCTAssertEqual(candidate.fields.kind, .event)
        XCTAssertNil(candidate.fields.targetAt)
        XCTAssertEqual(candidate.missingFields, ["target_at"])
        XCTAssertEqual(candidate.status, "needs_details")
    }

    func testBackendPayloadKeepsTheTaskAndDropsReadOnlyFields() throws {
        let json = """
        {"id":"5666bafd-464d-4cfa-b782-5484e093580e","revision":4,"kind":"task","title":"修复乱码",
         "description":"等样例","category":"work","status":"waiting","impact":"minor","priority":"urgent",
         "due_at":"2026-11-20T10:00:00Z","follow_up_at":"2026-11-19T07:00:00.123456Z","waiting_for":"样例"}
        """
        let item = try WorkbenchAPI.decoder().decode(Item.self, from: Data(json.utf8))
        XCTAssertEqual(item.fields.status, .waiting)
        XCTAssertEqual(item.revision, 4)
        XCTAssertNotNil(item.fields.followUpAt)
        let body = try WorkbenchAPI.encoder().encode(item.fields)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(fields["waiting_for"] as? String, "样例")
        XCTAssertEqual(fields["kind"] as? String, "task")
        XCTAssertNil(fields["id"])
        XCTAssertNil(fields["revision"])
    }

    func testDutyDatesAndRemindersUseBeijingTime() throws {
        let day = try XCTUnwrap(BeijingDates.parse("2026-11-20"))
        XCTAssertEqual(BeijingDates.key(day), "2026-11-20")
        XCTAssertEqual(BeijingDates.previousEvening(day).timeIntervalSince1970,
                       ISO8601DateFormatter().date(from: "2026-11-19T12:00:00Z")?.timeIntervalSince1970)
        let month = BeijingDates.monthInterval(day)
        XCTAssertEqual(BeijingDates.key(month.start), "2026-11-01")
        XCTAssertEqual(BeijingDates.key(month.end), "2026-12-01")
    }

    func testRequestUsesProductionHTTPSAndBasicCredentials() throws {
        let api = WorkbenchAPI(credentials: Credentials(username: "owner", password: "test-password"))
        let request = try api.request(["items"], query: [.init(name: "q", value: "论文+奖项")])
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertEqual(request.url?.host, "dzz.mcdkf.top")
        XCTAssertEqual(request.url?.port, 7736)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"),
                       "Basic " + Data("owner:test-password".utf8).base64EncodedString())
        let query = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(query.queryItems?.first?.value, "论文+奖项")
        XCTAssertTrue(query.percentEncodedQuery?.contains("%2B") == true)
    }
}
