import Foundation
import XCTest
@testable import WorkbenchCore

final class ContractTests: XCTestCase {
    func testClipboardCandidatesAllowMissingEventTimeForPreview() throws {
        let json = """
        {"request_id":"5666bafd-464d-4cfa-b782-5484e093580e","reference_time":"2026-11-18T10:00:00+08:00",
         "timezone":"Asia/Shanghai","model":"mimo-v2.6-flash","reason":"需要补充时间","candidates":[
          {"candidate_id":"5666bafd-464d-4cfa-b782-5484e093580f","fields":{"kind":"event","title":"考试","target_at":null},
           "evidence":"月底考试","time_hints":[{"field":"target_at","precision":"date","evidence":"11月29日","date":"2026-11-29"}],
           "missing_fields":["target_at"],"warnings":["请确认具体日期"],"status":"needs_details"}]}
        """
        let response = try WorkbenchAPI.decoder().decode(ClipboardParse.self, from: Data(json.utf8))
        let candidate = try XCTUnwrap(response.candidates.first)
        XCTAssertEqual(candidate.fields.kind, .event)
        XCTAssertNil(candidate.fields.targetAt)
        XCTAssertEqual(candidate.missingFields, ["target_at"])
        XCTAssertEqual(candidate.status, "needs_details")
        XCTAssertEqual(candidate.timeHints.first?.date, "2026-11-29")
        let suggested = try XCTUnwrap(candidate.suggestedDates["target_at"])
        XCTAssertEqual(BeijingDates.format(suggested, pattern: "yyyy-MM-dd HH:mm"), "2026-11-29 09:00")
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

    func testBeijingDatesHelpersAndRemainingFormatting() throws {
        let base = try XCTUnwrap(BeijingDates.defaultTime(on: "2026-11-20", hour: 15, minute: 30))
        XCTAssertEqual(BeijingDates.format(base, pattern: "yyyy-MM-dd HH:mm"), "2026-11-20 15:30")
        let morning = BeijingDates.nextMorning(from: base)
        XCTAssertEqual(BeijingDates.format(morning, pattern: "yyyy-MM-dd HH:mm"), "2026-11-21 09:00")
        XCTAssertEqual(BeijingDates.remaining(until: base.addingTimeInterval(-1), from: base), "已到期")
        XCTAssertEqual(BeijingDates.remaining(until: base.addingTimeInterval(61), from: base), "还有 2 分钟")
        XCTAssertEqual(BeijingDates.remaining(until: base.addingTimeInterval(3 * 3600), from: base), "还有 3 小时")
        XCTAssertEqual(BeijingDates.remaining(until: base.addingTimeInterval(26 * 3600), from: base), "还有 1 天 2 小时")
    }

    func testWidgetSnapshotFromHomeAndMidnightDutyRollover() throws {
        let json = """
        {"urgent":[
           {"id":"5666bafd-464d-4cfa-b782-5484e0935801","revision":1,"kind":"task","title":"紧急修复","status":"pending","priority":"urgent","due_at":"2026-11-20T09:00:00+08:00"}
         ],
         "overdue":[
           {"id":"5666bafd-464d-4cfa-b782-5484e0935801","revision":1,"kind":"task","title":"紧急修复","status":"pending","priority":"urgent","due_at":"2026-11-20T09:00:00+08:00"},
           {"id":"5666bafd-464d-4cfa-b782-5484e0935802","revision":1,"kind":"task","title":"逾期汇报","status":"in_progress","priority":"normal","due_at":"2026-11-19T18:00:00+08:00"}
         ],
         "due_today":[],
         "waiting":[
           {"id":"5666bafd-464d-4cfa-b782-5484e0935803","revision":1,"kind":"task","title":"等审稿意见","status":"waiting","priority":"normal"}
         ],
         "countdowns":[],
         "recent":[],
         "next_duty":{"id":"5666bafd-464d-4cfa-b782-5484e0935804","revision":1,"kind":"duty","title":"个人值班","date":"2026-11-20","days_remaining":1}}
        """
        let home = try WorkbenchAPI.decoder().decode(HomeData.self, from: Data(json.utf8))
        let nov19 = try XCTUnwrap(BeijingDates.defaultTime(on: "2026-11-19", hour: 21, minute: 0))
        let nov20 = try XCTUnwrap(BeijingDates.defaultTime(on: "2026-11-20", hour: 8, minute: 0))
        let snapshot = WidgetSnapshot.from(home: home, now: nov19)

        XCTAssertTrue(snapshot.signedIn)
        XCTAssertEqual(snapshot.urgentTasks.map(\.title), ["紧急修复", "逾期汇报"])
        XCTAssertEqual(snapshot.overdueCount, 2)
        XCTAssertEqual(snapshot.waitingCount, 1)
        XCTAssertEqual(snapshot.activeDuty(at: nov19)?.daysRemaining, 1)
        XCTAssertEqual(snapshot.activeDuty(at: nov20)?.daysRemaining, 0)

        let encoded = try WorkbenchAPI.encoder().encode(snapshot)
        let decoded = try WorkbenchAPI.decoder().decode(WidgetSnapshot.self, from: encoded)
        XCTAssertEqual(decoded.urgentTasks.count, 2)
        XCTAssertEqual(decoded.nextDuty?.date, "2026-11-20")
    }
}
