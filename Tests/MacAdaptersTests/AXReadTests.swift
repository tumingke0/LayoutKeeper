// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import XCTest
import ApplicationServices
@testable import MacAdapters

final class AXReadTests: XCTestCase {
    func testTimeoutKeepsOperationAndRawCode() {
        XCTAssertThrowsError(try AXAttributeReader.read(operation:"app/AXWindows",copy: { _ in .cannotComplete })) { error in
            guard let failure=error as? AXFailure else { return XCTFail("Original AX error must survive") }
            XCTAssertEqual(failure.operation,"app/AXWindows")
            XCTAssertEqual(failure.code,AXError.cannotComplete.rawValue)
        }
    }
    func testUnavailableAttributeKeepsItsCodeInsteadOfBecomingPermission() {
        XCTAssertThrowsError(try AXAttributeReader.read(operation:"window/AXDocument",copy: { _ in .attributeUnsupported })) { error in
            XCTAssertEqual((error as? AXFailure)?.code,AXError.attributeUnsupported.rawValue)
        }
    }
    func testSuccessfulEmptyValueIsReported() {
        XCTAssertThrowsError(try AXAttributeReader.read(operation:"AXWindows",copy: { _ in .success })) { error in
            XCTAssertEqual(error as? AXReadValueError,.emptyValue(operation:"AXWindows"))
        }
    }
    func testSuccessfulValueSurvives() throws {
        let value=try AXAttributeReader.read(operation:"AXTitle",copy: { value in value="fixture" as CFString; return .success })
        XCTAssertEqual(value as? String,"fixture")
    }
}
