#define HL_NAME(n) metal_##n

#include <hl.h>
#include <SDL2/SDL.h>
#include <metal/metal.h>
#include <QuartzCore/CAMetalLayer.h>

typedef struct {
    id<MTLDevice> device;
    id<MTLCommandQueue> commandQueue;
    CAMetalLayer *layer;
    id<MTLRenderPipelineState> pipelineState;
    MTLRenderPassDescriptor *renderPassDescriptor;
    dispatch_semaphore_t frameSemaphore;
    SDL_Window *window;
} metal_context;

static metal_context *ctx = NULL;

// HL abstract types
#define TCTX _ABSTRACT(metal_context)
#define TDEV _ABSTRACT(metal_device)
#define TCMDBUF _ABSTRACT(metal_command_buffer)
#define TCMDENC _ABSTRACT(metal_command_encoder)
#define TTEX _ABSTRACT(metal_texture)
#define TBUF _ABSTRACT(metal_buffer)
#define TPIPST _ABSTRACT(metal_pipeline_state)

HL_PRIM void HL_NAME(init)(void) {
    if (ctx != NULL) return;

    ctx = (metal_context*)malloc(sizeof(metal_context));
    memset(ctx, 0, sizeof(metal_context));

    // Get the default Metal device
    ctx->device = MTLCreateSystemDefaultDevice();
    if (!ctx->device) {
        printf("Metal is not supported on this device\n");
        free(ctx);
        ctx = NULL;
        return;
    }

    // Create a command queue
    ctx->commandQueue = [ctx->device newCommandQueue];
    ctx->frameSemaphore = dispatch_semaphore_create(1);
}

HL_PRIM bool HL_NAME(setup_window)(void* win) {
    if (ctx == NULL) {
        printf("Metal context not initialized\n");
        return false;
    }

    SDL_Window* window = (SDL_Window*)win;
    ctx->window = window;

    // Get the SDL metal view
    SDL_MetalView metalView = SDL_Metal_CreateView(window);
    if (!metalView) {
        printf("Failed to create Metal view: %s\n", SDL_GetError());
        return false;
    }

    // Get the Metal layer from the Metal view
    ctx->layer = (CAMetalLayer *)SDL_Metal_GetLayer(metalView);
    ctx->layer.device = ctx->device;
    ctx->layer.pixelFormat = MTLPixelFormatBGRA8Unorm;

    // Create a render pass descriptor
    ctx->renderPassDescriptor = [MTLRenderPassDescriptor renderPassDescriptor];

    return true;
}

HL_PRIM bool HL_NAME(begin_render)(int r, int g, int b, int a) {
    if (ctx == NULL) return false;

    // Wait for the previous frame to complete
    dispatch_semaphore_wait(ctx->frameSemaphore, DISPATCH_TIME_FOREVER);

    // Get the next drawable
    id<CAMetalDrawable> drawable = [ctx->layer nextDrawable];
    if (!drawable) {
        dispatch_semaphore_signal(ctx->frameSemaphore);
        return false;
    }

    // Update the render pass descriptor for the current drawable
    ctx->renderPassDescriptor.colorAttachments[0].texture = drawable.texture;
    ctx->renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
    ctx->renderPassDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
    ctx->renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(r/255.0, g/255.0, b/255.0, a/255.0);

    // Create a command buffer and render command encoder
    id<MTLCommandBuffer> commandBuffer = [ctx->commandQueue commandBuffer];
    id<MTLRenderCommandEncoder> renderEncoder = [commandBuffer renderCommandEncoderWithDescriptor:ctx->renderPassDescriptor];

    // End encoding and commit the command buffer
    [renderEncoder endEncoding];

    // Present the drawable
    [commandBuffer presentDrawable:drawable];

    // Commit the command buffer and signal the semaphore when done
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull cmdBuf) {
        dispatch_semaphore_signal(ctx->frameSemaphore);
    }];

    [commandBuffer commit];

    return true;
}

HL_PRIM void HL_NAME(shutdown)(void) {
    if (ctx != NULL) {
        // Wait for any pending commands to complete
        dispatch_semaphore_wait(ctx->frameSemaphore, DISPATCH_TIME_FOREVER);
        dispatch_release(ctx->frameSemaphore);

        // Release Metal resources
        ctx->device = nil;
        ctx->commandQueue = nil;
        ctx->layer = nil;
        ctx->pipelineState = nil;
        ctx->renderPassDescriptor = nil;

        free(ctx);
        ctx = NULL;
    }
}

HL_PRIM const char* HL_NAME(get_driver_name)(void) {
    return "Metal";
}

// Export Hashlink functions
DEFINE_PRIM(_VOID, init, _NO_ARG);
DEFINE_PRIM(_BOOL, setup_window, _ABSTRACT(sdl_window));
DEFINE_PRIM(_BOOL, begin_render, _I32 _I32 _I32 _I32);
DEFINE_PRIM(_VOID, shutdown, _NO_ARG);
DEFINE_PRIM(_BYTES, get_driver_name, _NO_ARG);
