// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
#include <stdint.h>
#include <stddef.h>
#include <ApplicationServices/ApplicationServices.h>
// Experimental, fixture-only. A zero return means DISPATCHED, never verified success.
int SPDispatchOwnedFixture(uint32_t windowID, uint64_t spaceID, char * _Nonnull detail, size_t capacity);
// Runtime capability probe for cross-Space moves (no version table). Each field is 1 when present.
typedef struct {
    int skyLightLoaded, moveOperationClass, moveOperationABI, membershipRead, managedDisplaySpaces, mainConnection;
} SPCrossSpaceSymbols;
void SPProbeCrossSpaceSymbols(SPCrossSpaceSymbols * _Nonnull out);
// 1 when macOS >= 26 and every probed symbol resolves. Both dispatch entry points re-check this.
int SPControlledBridgeAvailable(void);
// Every argument comes from the confirmed preview. Zero means dispatched, never verified.
int SPDispatchVerifiedWindow(AXUIElementRef _Nullable element, int32_t expectedPID, uint32_t windowID,
    double expectedLaunchTime, const char * _Nonnull expectedBundleID, const char * _Nonnull expectedDocument, const char * _Nonnull expectedTitle,
    uint64_t sourceSpace, uint64_t targetSpace, const char * _Nonnull sourceDisplay, const char * _Nonnull targetDisplay,
    char * _Nonnull detail, size_t capacity);
