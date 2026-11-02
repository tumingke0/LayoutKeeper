// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import XCTest
@testable import LayoutCore

final class UsagePingTests: XCTestCase {
    let p=UsagePing.Payload(version:"0.6.16",build:"36",arch:"arm64",osMajor:27,osMinor:0,screens:2)
    var shanghai: Calendar { var c=Calendar(identifier:.gregorian); c.timeZone=TimeZone(identifier:"Asia/Shanghai")!; return c }

    func testPathAndURL() {
        XCTAssertEqual(UsagePing.path(.launch,p),"/app/macos/0.6.16/arm64/macos27.0/screens2")
        XCTAssertEqual(UsagePing.path(.feature("input-switch"),p),"/feature/input-switch/0.6.16")
        let url=UsagePing.url(.launch,p,installId:"0f8e2a4c-1d2b-4c3a-9e8f-7a6b5c4d3e2f")!.absoluteString
        XCTAssertEqual(url,"https://layoutkeeper.goatcounter.com/count?p=/app/macos/0.6.16/arm64/macos27.0/screens2&t=LayoutKeeper&e=false&uid=0f8e2a4c-1d2b-4c3a-9e8f-7a6b5c4d3e2f")
        let event=URLComponents(string:UsagePing.url(.feature("x"),p,installId:"id")!.absoluteString)!
        XCTAssertEqual(event.queryItems?.first { $0.name=="e" }?.value,"true")
    }

    func testBucketsAndSegments() {
        XCTAssertEqual(UsagePing.screenBucket(0),"screens1")
        XCTAssertEqual(UsagePing.screenBucket(1),"screens1")
        XCTAssertEqual(UsagePing.screenBucket(2),"screens2")
        XCTAssertEqual(UsagePing.screenBucket(3),"screens3plus")
        XCTAssertEqual(UsagePing.screenBucket(6),"screens3plus")
        XCTAssertEqual(UsagePing.segment("0.6.16 beta/../x?&"),"0.6.16_beta_.._x__")
        XCTAssertEqual(UsagePing.segment(""),"_")
        XCTAssertEqual(UsagePing.segment(String(repeating:"a",count:50)).count,32)
        // A hostile version string can't add query parameters or path levels.
        var odd=p; odd.version="1/2&e=true"
        let c=URLComponents(url:UsagePing.url(.launch,odd,installId:"id")!,resolvingAgainstBaseURL:false)!
        XCTAssertEqual(c.queryItems?.count,4)
        XCTAssertEqual(c.queryItems?.first { $0.name=="p" }?.value,"/app/macos/1_2_e_true/arm64/macos27.0/screens2")
        XCTAssertEqual(c.queryItems?.first { $0.name=="e" }?.value,"false")
    }

    func testUserAgentPassesBotFilter() {
        let ua=UsagePing.userAgent(p)
        XCTAssertEqual(ua,"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) LayoutKeeper/0.6.16 (36)")
        // zgo.at/isbot: >= 10 chars, has a space and a slash, no "://", no client-library or "bot" words.
        XCTAssertTrue(ua.count>=10 && ua.contains(" ") && ua.contains("/"))
        XCTAssertFalse(ua.contains("://"))
        for word in ["bot","crawler","spider","curl/","okhttp/","CFNetwork","HttpClient/"] { XCTAssertFalse(ua.lowercased().contains(word.lowercased()),word) }
    }

    func testDayKeyUsesLocalCalendar() {
        // 2026-11-02 16:30 UTC is 2026-11-03 00:30 in Shanghai.
        let d=Date(timeIntervalSince1970:1_793_637_000)
        XCTAssertEqual(UsagePing.dayKey(d,calendar:shanghai),"2026-11-03")
        var utc=Calendar(identifier:.gregorian); utc.timeZone=TimeZone(identifier:"UTC")!
        XCTAssertEqual(UsagePing.dayKey(d,calendar:utc),"2026-11-02")
    }

    func testOncePerDay() {
        let morning=Date(timeIntervalSince1970:1_793_581_200)   // 2026-11-02 09:00 Shanghai
        var made=0
        let first=UsagePing.plan(lastDay:nil,installId:nil,now:morning,calendar:shanghai,payload:p,makeId:{ made+=1; return "new-id" })
        XCTAssertEqual(made,1)
        XCTAssertEqual(first.installId,"new-id")
        XCTAssertEqual(first.day,"2026-11-02")
        XCTAssertNotNil(first.url)
        // Same day again (relaunch, wake, hourly check): nothing to send, ID unchanged.
        let again=UsagePing.plan(lastDay:first.day,installId:first.installId,now:morning.addingTimeInterval(14*3600),calendar:shanghai,payload:p,makeId:{ made+=1; return "other" })
        XCTAssertNil(again.url)
        XCTAssertEqual(again.installId,"new-id")
        XCTAssertEqual(made,1)
        // Past local midnight while the app keeps running: one more count, same ID.
        let next=UsagePing.plan(lastDay:first.day,installId:first.installId,now:morning.addingTimeInterval(15*3600+60),calendar:shanghai,payload:p)
        XCTAssertEqual(next.day,"2026-11-03")
        XCTAssertNotNil(next.url)
        XCTAssertTrue(next.url!.absoluteString.hasSuffix("uid=new-id"))
        // An empty stored ID is replaced.
        XCTAssertEqual(UsagePing.plan(lastDay:nil,installId:"",now:morning,payload:p,makeId:{ "fresh" }).installId,"fresh")
    }

    func testNewInstallIdIsRandomUUID() {
        let a=UsagePing.newInstallId(),b=UsagePing.newInstallId()
        XCTAssertNotEqual(a,b)
        XCTAssertNotNil(UUID(uuidString:a))
        XCTAssertEqual(a,a.lowercased())
    }
}
