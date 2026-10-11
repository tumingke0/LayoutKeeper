// SPDX-License-Identifier: GPL-3.0-only
// Copyright (C) 2026 LayoutKeeper contributors
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import "SpaceProbe.h"

// ABI first read from the 27.0/26A428 runtime; every call re-checks the method signatures at runtime. No hidden function addresses are used.
@interface NSObject (SpacePortObservedABI)
- (instancetype)initWithWindows:(NSArray *)windows spaceID:(uint64_t)spaceID;
- (void)performWithWMBridgeDelegate;
@end

static int fail(char *detail, size_t capacity, const char *reason) {
    if (capacity) snprintf(detail,capacity,"%s",reason);
    return -1;
}
int SPDispatchOwnedFixture(uint32_t windowID, uint64_t spaceID, char *detail, size_t capacity) {
    if (![NSThread isMainThread]) return fail(detail,capacity,"Must run on the main thread");
    if (!SPControlledBridgeAvailable()) return fail(detail,capacity,"Cross-Space capability unavailable on this macOS");
    NSWindow *owned=nil;
    for (NSWindow *w in NSApp.windows) {
        if (w.windowNumber == windowID && [w.title isEqual:@"LayoutKeeper Fixture 1"]) { owned=w; break; }
    }
    if (!owned || (owned.styleMask & NSWindowStyleMaskFullScreen) || owned.isMiniaturized || !spaceID)
        return fail(detail,capacity,"Rejected: not a live ordinary fixture owned by this process");
    void *library=dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",RTLD_LAZY | RTLD_LOCAL);
    if (!library) return fail(detail,capacity,"SkyLight unavailable");
    Class cls=NSClassFromString(@"SLSBridgedMoveWindowsToManagedSpaceOperation");
    NSMethodSignature *init=[cls instanceMethodSignatureForSelector:@selector(initWithWindows:spaceID:)];
    NSMethodSignature *perform=[cls instanceMethodSignatureForSelector:@selector(performWithWMBridgeDelegate)];
    BOOL valid=init && init.numberOfArguments==4 && !strcmp(init.methodReturnType,"@") && !strcmp([init getArgumentTypeAtIndex:2],"@") && !strcmp([init getArgumentTypeAtIndex:3],"Q") && perform && perform.numberOfArguments==2 && !strcmp(perform.methodReturnType,"v");
    if (!valid) { dlclose(library); return fail(detail,capacity,"Private ABI does not match read-only evidence"); }
    @try {
        id operation=[[cls alloc] initWithWindows:@[@(windowID)] spaceID:spaceID];
        if (!operation) { dlclose(library); return fail(detail,capacity,"Initializer returned nil"); }
        [operation performWithWMBridgeDelegate];
    } @catch (NSException *exception) {
        if (capacity) snprintf(detail,capacity,"Exception: %s",exception.name.UTF8String);
        dlclose(library); return -1;
    }
    dlclose(library);
    if (capacity) snprintf(detail,capacity,"Dispatched; must verify membership by readback");
    return 0;
}

#import <math.h>
static BOOL moveABIMatches(Class cls) {
    if (!cls) return NO;
    NSMethodSignature *init=[cls instanceMethodSignatureForSelector:@selector(initWithWindows:spaceID:)];
    NSMethodSignature *perform=[cls instanceMethodSignatureForSelector:@selector(performWithWMBridgeDelegate)];
    return init && init.numberOfArguments==4 && !strcmp(init.methodReturnType,"@") && !strcmp([init getArgumentTypeAtIndex:2],"@") && !strcmp([init getArgumentTypeAtIndex:3],"Q") && perform && perform.numberOfArguments==2 && !strcmp(perform.methodReturnType,"v");
}
void SPProbeCrossSpaceSymbols(SPCrossSpaceSymbols *out) {
    if (!out) return;
    memset(out,0,sizeof(*out));
    // Read-only: resolves symbols and inspects method signatures; nothing is called.
    void *library=dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",RTLD_LAZY|RTLD_LOCAL);
    if (!library) return;
    out->skyLightLoaded=1;
    Class cls=NSClassFromString(@"SLSBridgedMoveWindowsToManagedSpaceOperation");
    out->moveOperationClass=cls!=nil;
    out->moveOperationABI=moveABIMatches(cls);
    out->membershipRead=dlsym(library,"SLSCopySpacesForWindows")!=NULL;
    out->managedDisplaySpaces=dlsym(library,"SLSCopyManagedDisplaySpaces")!=NULL;
    out->mainConnection=dlsym(library,"SLSMainConnectionID")!=NULL;
    dlclose(library);
}
int SPControlledBridgeAvailable(void) {
    if (NSProcessInfo.processInfo.operatingSystemVersion.majorVersion<26) return 0;
    SPCrossSpaceSymbols s;SPProbeCrossSpaceSymbols(&s);
    return s.skyLightLoaded && s.moveOperationClass && s.moveOperationABI && s.membershipRead && s.managedDisplaySpaces && s.mainConnection;
}
static id controlledAttribute(AXUIElementRef element,CFStringRef key) {
    CFTypeRef value=NULL;
    if (AXUIElementCopyAttributeValue(element,key,&value)!=kAXErrorSuccess || !value) return nil;
    return CFBridgingRelease(value);
}
static NSString *displayTokenForManagedRow(NSDictionary *row) {
    NSString *identifier=row[@"Display Identifier"];
    if (![identifier isKindOfClass:NSString.class]) return nil;
    if (![identifier isEqual:@"Main"]) return identifier;
    CFUUIDRef uuid=CGDisplayCreateUUIDFromDisplayID(CGMainDisplayID());
    if (!uuid) return nil;
    NSString *token=CFBridgingRelease(CFUUIDCreateString(NULL,uuid));CFRelease(uuid);return token;
}
static BOOL ordinarySpaceOnDisplay(NSArray *rows,uint64_t space,NSString *display) {
    int count=0;
    for (id candidate in rows) {
        if (![candidate isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *row=candidate;
        NSString *token=displayTokenForManagedRow(row);
        if (!token || [token caseInsensitiveCompare:display]!=NSOrderedSame) continue;
        NSArray *spaces=row[@"Spaces"];
        if (![spaces isKindOfClass:NSArray.class]) continue;
        for (id item in spaces) {
            if (![item isKindOfClass:NSDictionary.class]) continue;
            NSDictionary *entry=item;NSNumber *identifier=entry[@"ManagedSpaceID"];NSNumber *kind=entry[@"type"];
            if ([identifier isKindOfClass:NSNumber.class] && [kind isKindOfClass:NSNumber.class] && identifier.unsignedLongLongValue==space && kind.intValue==0) count++;
        }
    }
    return count==1;
}
int SPDispatchVerifiedWindow(AXUIElementRef element,int32_t expectedPID,uint32_t windowID,
    double expectedLaunchTime,const char *expectedBundleID,const char *expectedDocument,const char *expectedTitle,
    uint64_t sourceSpace,uint64_t targetSpace,const char *sourceDisplay,const char *targetDisplay,char *detail,size_t capacity) {
    // A null pointer is rejected before any permission, WindowServer or private-framework call.
    if (!element) return fail(detail,capacity,"Missing AX element");
    if (![NSThread isMainThread]) return fail(detail,capacity,"Must run on the main thread");
    if (!SPControlledBridgeAvailable()) return fail(detail,capacity,"Cross-Space capability unavailable on this macOS (needs macOS 26+ and the bridged move/readback symbols)");
    if (!AXIsProcessTrusted()) return fail(detail,capacity,"Current GUI AX trust is unavailable");
    if (expectedPID<=0 || !windowID || !sourceSpace || !targetSpace || sourceSpace==targetSpace || !isfinite(expectedLaunchTime) ||
        !expectedBundleID || !expectedDocument || !expectedTitle || !sourceDisplay || !targetDisplay)
        return fail(detail,capacity,"Incomplete confirmed identity or Space route");
    pid_t actualPID=0;
    if (AXUIElementGetPid(element,&actualPID)!=kAXErrorSuccess || actualPID!=expectedPID)
        return fail(detail,capacity,"AX PID differs from confirmed PID");
    NSRunningApplication *app=[NSRunningApplication runningApplicationWithProcessIdentifier:expectedPID];
    NSString *bundle=[NSString stringWithUTF8String:expectedBundleID];
    if (!app || app.terminated || !app.launchDate || !bundle.length || ![app.bundleIdentifier isEqual:bundle] || fabs(app.launchDate.timeIntervalSince1970-expectedLaunchTime)>0.001)
        return fail(detail,capacity,"Process lifetime or bundle identity changed");
    void *local=dlopen(NULL,RTLD_LAZY);
    int (*getWindow)(AXUIElementRef,uint32_t *)=local ? dlsym(local,"_AXUIElementGetWindow") : NULL;
    uint32_t actualWindow=0;int status=getWindow ? getWindow(element,&actualWindow) : -1;
    if (local) dlclose(local);
    if (status!=0 || actualWindow!=windowID) return fail(detail,capacity,"AX window ID changed");
    id role=controlledAttribute(element,kAXRoleAttribute),subrole=controlledAttribute(element,kAXSubroleAttribute);
    id full=controlledAttribute(element,CFSTR("AXFullScreen")),mini=controlledAttribute(element,kAXMinimizedAttribute);
    if (![role isEqual:(__bridge NSString *)kAXWindowRole] || ![subrole isEqual:(__bridge NSString *)kAXStandardWindowSubrole] ||
        ![full isKindOfClass:NSNumber.class] || ![mini isKindOfClass:NSNumber.class] || [full boolValue] || [mini boolValue])
        return fail(detail,capacity,"Window is not a readable ordinary non-minimized window");
    NSString *document=[NSString stringWithUTF8String:expectedDocument],*title=[NSString stringWithUTF8String:expectedTitle];
    id readDocument=controlledAttribute(element,kAXDocumentAttribute);
    NSString *documentValue=[readDocument isKindOfClass:NSURL.class] ? [readDocument absoluteString] : ([readDocument isKindOfClass:NSString.class] ? readDocument : @"");
    id readTitle=controlledAttribute(element,kAXTitleAttribute);
    NSString *titleValue=[readTitle isKindOfClass:NSString.class] ? readTitle : @"";
    if (!document || !title || (!document.length && !title.length) || (document.length && ![documentValue isEqual:document]) || ![titleValue isEqual:title])
        return fail(detail,capacity,"Window selector changed since confirmation");
    NSArray *windowRows=CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionIncludingWindow,windowID));
    int ownedCount=0;
    for (NSDictionary *row in windowRows) {
        if ([row[(id)kCGWindowNumber] unsignedIntValue]==windowID && [row[(id)kCGWindowOwnerPID] intValue]==expectedPID && [row[(id)kCGWindowLayer] intValue]==0) ownedCount++;
    }
    if (ownedCount!=1) return fail(detail,capacity,"CG owner or window identity cannot be verified");
    void *library=dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",RTLD_LAZY|RTLD_LOCAL);
    if (!library) return fail(detail,capacity,"SkyLight unavailable");
    int32_t (*connection)(void)=dlsym(library,"SLSMainConnectionID");
    CFArrayRef (*copyMembership)(int32_t,int32_t,CFArrayRef)=dlsym(library,"SLSCopySpacesForWindows");
    CFArrayRef (*copyDisplays)(int32_t)=dlsym(library,"SLSCopyManagedDisplaySpaces");
    if (!connection || !copyMembership || !copyDisplays) { dlclose(library);return fail(detail,capacity,"Read-only Space validation unavailable"); }
    int32_t cid=connection();
    NSArray *members=CFBridgingRelease(copyMembership(cid,7,(__bridge CFArrayRef)@[@(windowID)]));
    NSArray *rows=CFBridgingRelease(copyDisplays(cid));
    NSString *sourceToken=[NSString stringWithUTF8String:sourceDisplay],*targetToken=[NSString stringWithUTF8String:targetDisplay];
    if (members.count!=1 || [members[0] unsignedLongLongValue]!=sourceSpace || ![rows isKindOfClass:NSArray.class] || !sourceToken.length || !targetToken.length ||
        !ordinarySpaceOnDisplay(rows,sourceSpace,sourceToken) || !ordinarySpaceOnDisplay(rows,targetSpace,targetToken)) {
        dlclose(library);return fail(detail,capacity,"Source membership, target Space or display changed");
    }
    Class cls=NSClassFromString(@"SLSBridgedMoveWindowsToManagedSpaceOperation");
    NSMethodSignature *init=[cls instanceMethodSignatureForSelector:@selector(initWithWindows:spaceID:)];
    NSMethodSignature *perform=[cls instanceMethodSignatureForSelector:@selector(performWithWMBridgeDelegate)];
    BOOL valid=init && init.numberOfArguments==4 && !strcmp(init.methodReturnType,"@") && !strcmp([init getArgumentTypeAtIndex:2],"@") && !strcmp([init getArgumentTypeAtIndex:3],"Q") && perform && perform.numberOfArguments==2 && !strcmp(perform.methodReturnType,"v");
    if (!valid) { dlclose(library);return fail(detail,capacity,"Private ABI does not match the expected signatures"); }
    @try {
        id operation=[[cls alloc] initWithWindows:@[@(windowID)] spaceID:targetSpace];
        if (!operation) { dlclose(library);return fail(detail,capacity,"Initializer returned nil"); }
        [operation performWithWMBridgeDelegate];
    } @catch (NSException *exception) {
        if (capacity) snprintf(detail,capacity,"Exception: %s",exception.name.UTF8String);dlclose(library);return -1;
    }
    dlclose(library);
    if (capacity) snprintf(detail,capacity,"Dispatched; target membership must be verified before geometry");
    return 0;
}
