// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
import XCTest
import CoreAudio
import LayoutCore

/// LayoutCore keeps CoreAudio's transport FourCCs as plain numbers (it doesn't import CoreAudio); they must agree.
final class AudioTransportTests: XCTestCase {
    func testTransportConstantsMatchCoreAudio() {
        XCTAssertEqual(MonitorAudioMatcher.transportHDMI,UInt32(kAudioDeviceTransportTypeHDMI))
        XCTAssertEqual(MonitorAudioMatcher.transportDisplayPort,UInt32(kAudioDeviceTransportTypeDisplayPort))
        XCTAssertFalse(MonitorAudioMatcher.isDisplayTransport(UInt32(kAudioDeviceTransportTypeBuiltIn)))
        XCTAssertFalse(MonitorAudioMatcher.isDisplayTransport(UInt32(kAudioDeviceTransportTypeUSB)))
    }
}
