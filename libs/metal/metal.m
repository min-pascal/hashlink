#define HL_NAME(n) metal_##n

#include <hl.h>
#include <SDL2/SDL.h>
#include <SDL2/SDL_metal.h>
#include <Metal/Metal.h>
#include <QuartzCore/CAMetalLayer.h>

typedef struct {
    id<MTLDevice> device;
    id<MTLCommandQueue> commandQueue;
    CAMetalLayer *layer;
    SDL_MetalView metalView;
    SDL_Window *window;
    MTLRenderPassDescriptor *renderPassDescriptor;
    bool windowSetup;
} metal_context;

static metal_context *ctx = NULL;

// Standalone test function - independent of Heaps
HL_PRIM void HL_NAME(test_window)(int r, int g, int b) {
    printf("Starting Metal standalone test...\n");
    
    // Initialize SDL
    if (SDL_Init(SDL_INIT_VIDEO) < 0) {
        printf("SDL_Init failed: %s\n", SDL_GetError());
        return;
    }

    // Create SDL window
    SDL_Window* window = SDL_CreateWindow(
        "Metal Standalone Test",
        SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
        400, 400,
        SDL_WINDOW_SHOWN | SDL_WINDOW_RESIZABLE
    );
    if (!window) {
        printf("SDL_CreateWindow failed: %s\n", SDL_GetError());
        SDL_Quit();
        return;
    }

    @autoreleasepool {
        // Create Metal device
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) {
            printf("Failed to create Metal device\n");
            SDL_DestroyWindow(window);
            SDL_Quit();
            return;
        }
        
        printf("Metal device created: %s\n", [[device name] UTF8String]);

        // Create SDL Metal view
        SDL_MetalView metalView = SDL_Metal_CreateView(window);
        if (!metalView) {
            printf("Failed to create Metal view: %s\n", SDL_GetError());
            SDL_DestroyWindow(window);
            SDL_Quit();
            return;
        }

        // Get the Metal layer
        CAMetalLayer* layer = (CAMetalLayer *)SDL_Metal_GetLayer(metalView);
        if (!layer) {
            printf("Failed to get Metal layer\n");
            SDL_Metal_DestroyView(metalView);
            SDL_DestroyWindow(window);
            SDL_Quit();
            return;
        }

        // Configure the Metal layer
        layer.device = device;
        layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        layer.framebufferOnly = YES;
        layer.opaque = YES;

        // Get window size and set layer drawable size
        int width, height;
        SDL_GetWindowSize(window, &width, &height);
        layer.drawableSize = CGSizeMake(width, height);

        // Create command queue
        id<MTLCommandQueue> commandQueue = [device newCommandQueue];
        if (!commandQueue) {
            printf("Failed to create command queue\n");
            SDL_Metal_DestroyView(metalView);
            SDL_DestroyWindow(window);
            SDL_Quit();
            return;
        }

        printf("Metal setup complete. Showing window with color RGB(%d, %d, %d)...\n", r, g, b);

        // Main render loop
        bool running = true;
        SDL_Event event;
        
        while (running) {
            // Handle SDL events
            while (SDL_PollEvent(&event)) {
                if (event.type == SDL_QUIT) {
                    running = false;
                }
                if (event.type == SDL_KEYDOWN) {
                    if (event.key.keysym.sym == SDLK_ESCAPE) {
                        running = false;
                    }
                }
            }

            @autoreleasepool {
                // Get next drawable
                id<CAMetalDrawable> drawable = [layer nextDrawable];
                if (!drawable) continue;

                // Create render pass descriptor
                MTLRenderPassDescriptor* renderPassDescriptor = [MTLRenderPassDescriptor renderPassDescriptor];
                renderPassDescriptor.colorAttachments[0].texture = drawable.texture;
                renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
                renderPassDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
                renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(
                    r/255.0, g/255.0, b/255.0, 1.0
                );

                // Create command buffer
                id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];
                if (!commandBuffer) continue;

                // Create render encoder
                id<MTLRenderCommandEncoder> renderEncoder = 
                    [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
                if (!renderEncoder) continue;

                // End encoding (just clearing)
                [renderEncoder endEncoding];

                // Present the drawable
                [commandBuffer presentDrawable:drawable];
                
                // Commit the command buffer
                [commandBuffer commit];
            }

            // Cap frame rate to ~60 FPS
            SDL_Delay(16);
        }

        // Cleanup
        SDL_Metal_DestroyView(metalView);
    }

    SDL_DestroyWindow(window);
    SDL_Quit();
    
    printf("Metal standalone test completed.\n");
}

// Heaps integration functions
HL_PRIM void HL_NAME(init)(void) {
    if (ctx != NULL) return;

    @autoreleasepool {
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
        if (!ctx->commandQueue) {
            printf("Failed to create Metal command queue\n");
            free(ctx);
            ctx = NULL;
            return;
        }

        // Create render pass descriptor
        ctx->renderPassDescriptor = [MTLRenderPassDescriptor renderPassDescriptor];
        ctx->windowSetup = false;
    }
}

// Use _DYN instead of specific SDL window type to match what Heaps expects
HL_PRIM bool HL_NAME(setup_window)(vdynamic *win) {
    if (ctx == NULL) {
        printf("Metal context not initialized\n");
        return false;
    }

    @autoreleasepool {
        // Extract SDL_Window from the dynamic value
        SDL_Window* window = (SDL_Window*)win->v.ptr;
        ctx->window = window;

        // Create SDL Metal view
        ctx->metalView = SDL_Metal_CreateView(window);
        if (!ctx->metalView) {
            printf("Failed to create Metal view: %s\n", SDL_GetError());
            return false;
        }

        // Get the Metal layer from the Metal view
        ctx->layer = (CAMetalLayer *)SDL_Metal_GetLayer(ctx->metalView);
        if (!ctx->layer) {
            printf("Failed to get Metal layer\n");
            SDL_Metal_DestroyView(ctx->metalView);
            return false;
        }

        // Configure the Metal layer using the same settings as the working test
        ctx->layer.device = ctx->device;
        ctx->layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        ctx->layer.framebufferOnly = YES;
        ctx->layer.opaque = YES;

        // Get window size and set layer drawable size
        int width, height;
        SDL_GetWindowSize(window, &width, &height);
        ctx->layer.drawableSize = CGSizeMake(width, height);

        ctx->windowSetup = true;
    }

    return true;
}

HL_PRIM bool HL_NAME(begin_render)(int r, int g, int b, int a) {
    if (ctx == NULL || !ctx->windowSetup) return false;

    @autoreleasepool {
        // Get the next drawable
        id<CAMetalDrawable> drawable = [ctx->layer nextDrawable];
        if (!drawable) {
            return false;
        }

        // Configure render pass descriptor exactly like the working test
        ctx->renderPassDescriptor.colorAttachments[0].texture = drawable.texture;
        ctx->renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
        ctx->renderPassDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
        ctx->renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(
            r/255.0, g/255.0, b/255.0, a/255.0
        );

        // Create command buffer
        id<MTLCommandBuffer> commandBuffer = [ctx->commandQueue commandBuffer];
        if (!commandBuffer) return false;

        // Create render encoder
        id<MTLRenderCommandEncoder> renderEncoder = 
            [commandBuffer renderCommandEncoderWithDescriptor:ctx->renderPassDescriptor];
        if (!renderEncoder) return false;

        // End encoding immediately (just clearing)
        [renderEncoder endEncoding];

        // Present the drawable
        [commandBuffer presentDrawable:drawable];
        
        // Commit the command buffer
        [commandBuffer commit];
    }

    return true;
}

// Add proper buffer allocation for Metal
HL_PRIM vdynamic* HL_NAME(alloc_buffer)(int size, int flags) {
    if (ctx == NULL) return NULL;

    @autoreleasepool {
        // Create a Metal buffer with the specified size
        id<MTLBuffer> metalBuffer = [ctx->device newBufferWithLength:size 
                                                             options:MTLResourceStorageModeShared];
        
        if (!metalBuffer) {
            return NULL;
        }

        // Create a dynamic integer value to return
        // Using an integer handle is more compatible with how Heaps expects GPU buffers
        // This avoids the segmentation fault by not returning a complex object
        vdynamic *result = (vdynamic*)hl_gc_alloc_noptr(sizeof(vdynamic));
        result->t = &hlt_i32;
        result->v.i = (int)(uintptr_t)metalBuffer; // Cast pointer to integer
        return result;
    }
}

HL_PRIM void HL_NAME(dispose_buffer)(vdynamic *buffer) {
    if (!buffer || buffer->t != &hlt_i32) return;

    @autoreleasepool {
        // Get the Metal buffer by casting integer back to pointer
        id<MTLBuffer> metalBuffer = (id<MTLBuffer>)(uintptr_t)buffer->v.i;

        // Release the buffer (ARC will handle this automatically)
        // But we can set it to nil to make sure it's released
        metalBuffer = nil;
    }
}

HL_PRIM void HL_NAME(shutdown)(void) {
    if (ctx != NULL) {
        @autoreleasepool {
            // Destroy SDL Metal view
            if (ctx->metalView) {
                SDL_Metal_DestroyView(ctx->metalView);
                ctx->metalView = NULL;
            }

            // Release Metal resources
            if (ctx->renderPassDescriptor) {
                ctx->renderPassDescriptor = nil;
            }
            if (ctx->commandQueue) {
                ctx->commandQueue = nil;
            }
            if (ctx->device) {
                ctx->device = nil;
            }
            
            ctx->layer = nil;
        }

        free(ctx);
        ctx = NULL;
    }
}

// Export Hashlink functions
DEFINE_PRIM(_VOID, init, _NO_ARG);
DEFINE_PRIM(_BOOL, setup_window, _DYN);
DEFINE_PRIM(_BOOL, begin_render, _I32 _I32 _I32 _I32);
DEFINE_PRIM(_DYN, alloc_buffer, _I32 _I32);
DEFINE_PRIM(_VOID, dispose_buffer, _DYN);
DEFINE_PRIM(_VOID, shutdown, _NO_ARG);
DEFINE_PRIM(_VOID, test_window, _I32 _I32 _I32);  // Keep test function