#define HL_NAME(n) metal_##n
#include <hl.h>

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <AppKit/AppKit.h>

// Define a structure to hold the Metal driver state
typedef struct {
    id<MTLDevice> device;
    id<MTLCommandQueue> commandQueue;
    CAMetalLayer *metalLayer;
    id<MTLRenderPipelineState> pipelineState;
} metal_driver;

static metal_driver *driver = NULL;

// Initialize the Metal driver
HL_PRIM metal_driver *HL_NAME(init)(void) {
    if (driver != NULL)
        return driver;

    driver = (metal_driver*)malloc(sizeof(metal_driver));
    if (driver == NULL)
        return NULL;

    // Get default Metal device
    driver->device = MTLCreateSystemDefaultDevice();
    if (!driver->device) {
        free(driver);
        driver = NULL;
        return NULL;
    }

    // Create command queue
    driver->commandQueue = [driver->device newCommandQueue];
    if (!driver->commandQueue) {
        [driver->device release];
        free(driver);
        driver = NULL;
        return NULL;
    }

    driver->metalLayer = NULL;
    driver->pipelineState = NULL;

    return driver;
}

// Create a Metal layer for rendering
HL_PRIM void HL_NAME(set_target)(void *nativeWindow, int width, int height) {
    if (!driver || !driver->device)
        return;

    if (driver->metalLayer == NULL) {
        driver->metalLayer = [CAMetalLayer layer];
        [driver->metalLayer setDevice:driver->device];
        [driver->metalLayer setPixelFormat:MTLPixelFormatBGRA8Unorm];
        [driver->metalLayer setFramebufferOnly:YES];
    }

    // Set the drawable size
    [driver->metalLayer setDrawableSize:CGSizeMake(width, height)];
}

// Clear the render pass with specified color and depth
HL_PRIM void HL_NAME(clear)(void* renderPassPtr, double r, double g, double b, double a, double depth, int stencil) {
    if (!driver || !driver->device || !driver->metalLayer)
        return;

    // Get a drawable from the layer
    id<CAMetalDrawable> drawable = [driver->metalLayer nextDrawable];
    if (!drawable)
        return;

    // Create a render pass descriptor
    MTLRenderPassDescriptor *renderPassDescriptor = [MTLRenderPassDescriptor renderPassDescriptor];
    renderPassDescriptor.colorAttachments[0].texture = drawable.texture;
    renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
    renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(r, g, b, a);
    renderPassDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;

    // Create a command buffer
    id<MTLCommandBuffer> commandBuffer = [driver->commandQueue commandBuffer];

    // Create a render command encoder
    id<MTLRenderCommandEncoder> renderEncoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
    [renderEncoder endEncoding];

    // Present drawable
    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];
}

// Dispatch a compute kernel with specified dimensions
HL_PRIM void HL_NAME(compute_dispatch)(int x, int y, int z) {

    if (!driver || !driver->device)
        return;

    NSLog(@"Metal compute_dispatch called with dimensions: %d x %d x %d", x, y, z);
}

HL_PRIM void HL_NAME(begin_render_pass)() {
    if (!driver || !driver->device || !driver->metalLayer)
        return;

    NSLog(@"Metal begin_render_pass called");
}

// Cleanup function
HL_PRIM void HL_NAME(free)(void) {
    if (driver) {

        // Release the Metal layer if it exists
        if (driver->pipelineState) {
            [driver->pipelineState release];
        }

        // Release the command queue and device
        if (driver->commandQueue) {
            [driver->commandQueue release];
        }

				// Release the Metal device
        if (driver->device) {
            [driver->device release];
        }

        // Note: CAMetalLayer is autoreleased

        free(driver);
        driver = NULL;
    }
}

// Release the Metal device
HL_PRIM void HL_NAME(release_metal_device)(void* device) {
    if (!device)
        return;

    // Cast the device pointer back to Metal device and release it
    id<MTLDevice> metalDevice = (__bridge id<MTLDevice>)device;
    [metalDevice release];
}

// Create a new Metal device
HL_PRIM void* HL_NAME(create_metal_device)(void) {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        return NULL;
    }

    return (__bridge void*)device;
}

// Setup the Metal layer for rendering
HL_PRIM void HL_NAME(setup_metal_layer)(void* nsWindowPtr, int width, int height) {
    if (!nsWindowPtr) {
        return;
    }

    // Cast the window pointer back to NSWindow
    NSWindow* window = (__bridge NSWindow*)nsWindowPtr;

    // Create or update the metal layer
    if (driver && driver->metalLayer == NULL) {
        driver->metalLayer = [CAMetalLayer layer];
        [driver->metalLayer setDevice:driver->device];
        [driver->metalLayer setPixelFormat:MTLPixelFormatBGRA8Unorm];
        [driver->metalLayer setFramebufferOnly:YES];

        // Add the layer to the window's content view
        NSView* contentView = [window contentView];
        [contentView setLayer:driver->metalLayer];
        [contentView setWantsLayer:YES];
    }

    // Set the drawable size
    if (driver && driver->metalLayer) {
        [driver->metalLayer setDrawableSize:CGSizeMake(width, height)];
    }
}

// Present the current frame
HL_PRIM void HL_NAME(present)() {
    if (!driver || !driver->device || !driver->metalLayer)
        return;

    NSLog(@"Metal present called");
}

// Resize the Metal layer when window size changes
HL_PRIM void HL_NAME(resize_metal_layer)(int width, int height) {
    if (!driver || !driver->device || !driver->metalLayer)
        return;

    // Resize the Metal layer to the new dimensions
    [driver->metalLayer setDrawableSize:CGSizeMake(width, height)];
    NSLog(@"Metal layer resized to %d x %d", width, height);
}

#define _DRIVER _ABSTRACT(metal_driver)
DEFINE_PRIM(_DRIVER, init, _NO_ARG);
DEFINE_PRIM(_VOID, set_target, _BYTES _I32 _I32);
DEFINE_PRIM(_VOID, clear, _F64 _F64 _F64 _F64 _F64 _I32);
DEFINE_PRIM(_VOID, compute_dispatch, _I32 _I32 _I32);
DEFINE_PRIM(_VOID, begin_render_pass, _NO_ARG);
DEFINE_PRIM(_VOID, free, _NO_ARG);
DEFINE_PRIM(_VOID, release_metal_device, _DYN);
DEFINE_PRIM(_DYN, create_metal_device, _NO_ARG);
DEFINE_PRIM(_VOID, setup_metal_layer, _DYN _I32 _I32);
DEFINE_PRIM(_VOID, present, _NO_ARG);
DEFINE_PRIM(_VOID, resize_metal_layer, _I32 _I32);
