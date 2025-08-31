#include "metal.h"

bool metal_init_frame_debugging_impl(void) {
    if (!ctx || !ctx->device) {
        return false;
    }

    // Initialize frame debugging state
    ctx->frameCaptureTrigger = false;
    ctx->frameCaptureInProgress = false;
    ctx->hasFrameCaptured = false;
    ctx->autoCaptureTimeoutSecs = 3.0; // 3 seconds timeout like the reference

    // Store the current time for auto-capture timeout
    NSDate *startTime = [NSDate date];
    ctx->captureStartTime = (__bridge_retained void*)startTime;

    return true;
}

bool metal_trigger_frame_capture_impl(void) {
    if (!ctx || !ctx->device) {
        return false;
    }

    id<MTLDevice> device = (__bridge id<MTLDevice>)ctx->device;
    MTLCaptureManager *captureManager = [MTLCaptureManager sharedCaptureManager];

    // Check what capture destinations are supported
    BOOL supportsGPUTrace = [captureManager supportsDestination:MTLCaptureDestinationGPUTraceDocument];
    BOOL supportsDeveloperTools = [captureManager supportsDestination:MTLCaptureDestinationDeveloperTools];

    metal_debug_log("GPU Trace Document support: %s", supportsGPUTrace ? "YES" : "NO");
    metal_debug_log("Developer Tools support: %s", supportsDeveloperTools ? "YES" : "NO");

    // Try GPU trace document first (preferred)
    if (supportsGPUTrace) {
        // Generate timestamped filename
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        [formatter setDateFormat:@"capture-HH-mm-ss_MM-dd-yy"];
        NSString *timestamp = [formatter stringFromDate:[NSDate date]];
        NSString *filename = [NSString stringWithFormat:@"%@.gputrace", timestamp];

        // Create file path in temporary directory
        NSString *tempDir = NSTemporaryDirectory();
        NSString *tracePath = [tempDir stringByAppendingPathComponent:filename];
        NSURL *traceURL = [NSURL fileURLWithPath:tracePath];

        // Create capture descriptor
        MTLCaptureDescriptor *captureDescriptor = [[MTLCaptureDescriptor alloc] init];
        captureDescriptor.destination = MTLCaptureDestinationGPUTraceDocument;
        captureDescriptor.outputURL = traceURL;
        captureDescriptor.captureObject = device;

        // Start capture
        NSError *error = nil;
        BOOL success = [captureManager startCaptureWithDescriptor:captureDescriptor error:&error];

        if (success) {
            ctx->frameCaptureInProgress = true;
            metal_debug_log("GPU frame capture started. Trace will be saved to: %s", [tracePath UTF8String]);
            return true;
        } else {
            if (error) {
                metal_debug_log("Failed to start GPU trace capture: %s", [error.localizedDescription UTF8String]);
            }
        }
    }

    // Fall back to developer tools destination
    if (supportsDeveloperTools) {
        MTLCaptureDescriptor *captureDescriptor = [[MTLCaptureDescriptor alloc] init];
        captureDescriptor.destination = MTLCaptureDestinationDeveloperTools;
        captureDescriptor.captureObject = device;

        NSError *error = nil;
        BOOL success = [captureManager startCaptureWithDescriptor:captureDescriptor error:&error];

        if (success) {
            ctx->frameCaptureInProgress = true;
            metal_debug_log("GPU frame capture started to Developer Tools (Xcode GPU debugger)");
            return true;
        } else {
            if (error) {
                metal_debug_log("Failed to start Developer Tools capture: %s", [error.localizedDescription UTF8String]);
            }
        }
    }

    metal_debug_log("No supported GPU capture destinations available");
    metal_debug_log("To enable GPU debugging:");
    metal_debug_log("1. Install Xcode with developer tools");
    metal_debug_log("2. Enable Developer Mode in System Preferences");
    metal_debug_log("3. Run from Xcode or with proper entitlements");

    return false;
}

bool metal_stop_frame_capture_and_open_impl(void) {
    if (!ctx || !ctx->frameCaptureInProgress) {
        return false;
    }

    MTLCaptureManager *captureManager = [MTLCaptureManager sharedCaptureManager];
    [captureManager stopCapture];

    ctx->frameCaptureInProgress = false;
    ctx->hasFrameCaptured = true;
    ctx->frameCaptureTrigger = false;

    // Get the trace file path and open it
    NSDate *startTime = (__bridge NSDate*)ctx->captureStartTime;
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    [formatter setDateFormat:@"capture-HH-mm-ss_MM-dd-yy"];
    NSString *timestamp = [formatter stringFromDate:startTime];
    NSString *filename = [NSString stringWithFormat:@"%@.gputrace", timestamp];
    NSString *tempDir = NSTemporaryDirectory();
    NSString *tracePath = [tempDir stringByAppendingPathComponent:filename];

    // Open the trace file in Xcode using system command
    NSString *openCommand = [NSString stringWithFormat:@"open \"%@\"", tracePath];
    system([openCommand UTF8String]);

    metal_debug_log("GPU frame capture completed. Opening trace file: %s", [tracePath UTF8String]);

    return true;
}

bool metal_check_auto_capture_impl(void) {
    if (!ctx || ctx->hasFrameCaptured) {
        return false;
    }

    NSDate *startTime = (__bridge NSDate*)ctx->captureStartTime;
    NSTimeInterval elapsed = [[NSDate date] timeIntervalSinceDate:startTime];

    if (elapsed > ctx->autoCaptureTimeoutSecs) {
        metal_debug_log("Auto-triggering GPU frame capture after %.1f seconds", elapsed);
        ctx->frameCaptureTrigger = true;
        return true;
    }

    return false;
}

// HashLink exports for frame debugging
HL_PRIM bool HL_NAME(init_frame_debugging)(void) {
    return metal_init_frame_debugging_impl();
}

HL_PRIM bool HL_NAME(trigger_frame_capture)(void) {
    if (!ctx) return false;
    ctx->frameCaptureTrigger = true;
    return true;
}

HL_PRIM bool HL_NAME(check_auto_capture)(void) {
    return metal_check_auto_capture_impl();
}

DEFINE_PRIM(_BOOL, init_frame_debugging, _NO_ARG);
DEFINE_PRIM(_BOOL, trigger_frame_capture, _NO_ARG);
DEFINE_PRIM(_BOOL, check_auto_capture, _NO_ARG);
