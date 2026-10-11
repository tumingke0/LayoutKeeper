// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import XCTest
@testable import MacAdapters

final class EmptyWindowTrialTests: XCTestCase {
    func testNormalLaunchHasNoTrialScope() throws { XCTAssertNil(try EmptyWindowTrial.parse(arguments:["SpacePort"])) }
    func testExplicitTemporaryTrialRootIsAccepted() throws {
        let trial=try XCTUnwrap(EmptyWindowTrial.parse(arguments:["SpacePort","--approved-empty-window-trial","/tmp/spaceport-trial-unit/Layouts"]))
        XCTAssertEqual(trial.root.lastPathComponent,"Layouts")
        XCTAssertTrue(trial.root.path.contains("spaceport-trial-unit"))
    }
    func testProductionDirectoryCannotBeTrialTarget() {
        XCTAssertThrowsError(try EmptyWindowTrial.parse(arguments:["SpacePort","--approved-empty-window-trial","/Users/test/Library/Application Support/SpacePort/Layouts"]))
    }
    func testMissingRelativeOrGenericTargetIsRejected() {
        for args in [["SpacePort","--approved-empty-window-trial"],["SpacePort","--approved-empty-window-trial","Layouts"],["SpacePort","--approved-empty-window-trial","/tmp/Layouts"]] {
            XCTAssertThrowsError(try EmptyWindowTrial.parse(arguments:args))
        }
    }
    func testNormalCaptureDoesNotRequireFixturesOrUseOwnedReader() throws {
        let trial=try EmptyWindowTrial.parse(arguments:["SpacePort"])
        var regularReads=0,ownedReads=0
        let result=try EmptyWindowTrial.capture(trial:trial,createdWindowIDs:[],regular:{ regularReads += 1;return 2 },owned:{ _,_ in ownedReads += 1;return 0 })
        XCTAssertEqual(result,2);XCTAssertEqual(regularReads,1);XCTAssertEqual(ownedReads,0)
    }
    func testEmptyExplicitTrialFailsBeforeAnyReaderWithActionableMessage() throws {
        let trial=try EmptyWindowTrial.parse(arguments:["SpacePort","--approved-empty-window-trial","/tmp/spaceport-trial-unit/Layouts"])
        var reads=0
        do {
            _ = try EmptyWindowTrial.capture(trial:trial,createdWindowIDs:[],regular:{ reads += 1;return 0 },owned:{ _,_ in reads += 1;return 0 })
            XCTFail("A fixture-less trial must not read existing work windows")
        } catch {
            let message=ExternalSaveMessage.failure(error:error,phase:.readWindows)
            print("Fixture-less trial save message: \(message)")
            XCTAssertTrue(message.contains("空白验收模式"))
            XCTAssertTrue(message.contains("尚未创建"))
            XCTAssertFalse(message.contains("稍后重试"))
        }
        XCTAssertEqual(reads,0)
    }
    func testExplicitTrialDispatchesOnlyOwnedReaderWithCreatedIDs() throws {
        let trial=try EmptyWindowTrial.parse(arguments:["SpacePort","--approved-empty-window-trial","/tmp/spaceport-trial-unit/Layouts"])
        var regularReads=0,receivedIDs=[Int]()
        let result=try EmptyWindowTrial.capture(trial:trial,createdWindowIDs:[7],regular:{ regularReads += 1;return 0 },owned:{ _,ids in receivedIDs=ids;return 1 })
        XCTAssertEqual(result,1);XCTAssertEqual(regularReads,0);XCTAssertEqual(receivedIDs,[7])
    }
    func testTrialScopeMatchesOnlyCreatedFixtureTokenAndTitle() throws {
        let trial=try XCTUnwrap(EmptyWindowTrial.parse(arguments:["SpacePort","--approved-empty-window-trial","/tmp/spaceport-trial-unit/Layouts"]))
        XCTAssertTrue(trial.accepts(token:"42:7",title:"LayoutKeeper Fixture 1",pid:42,createdWindowIDs:[7]))
        XCTAssertFalse(trial.accepts(token:"42:8",title:"LayoutKeeper Fixture 1",pid:42,createdWindowIDs:[7]))
        XCTAssertFalse(trial.accepts(token:"43:7",title:"LayoutKeeper Fixture 1",pid:42,createdWindowIDs:[7]))
        XCTAssertFalse(trial.accepts(token:"42:7",title:"User document",pid:42,createdWindowIDs:[7]))
    }
}
