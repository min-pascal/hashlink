#include "metal.h"

metal_context *ctx = NULL;

// ============================================================================
// Error logging - ALWAYS compiled in (errors indicate real problems)
// ============================================================================
void metal_log_error_impl(const char* message, ...) {
    va_list args;
    va_start(args, message);
    fprintf(stderr, "[METAL ERROR] ");
    vfprintf(stderr, message, args);
    fprintf(stderr, "\n");
    fflush(stderr);
    va_end(args);
}

// ============================================================================
// Debug logging - Only compiled when METAL_DEBUG is defined
// ============================================================================
#ifdef METAL_DEBUG

static int metal_log_level = 0;  // Default: errors only

void metal_set_log_level(int level) {
    metal_log_level = level;
    if (level > 0) {
        fprintf(stderr, "[METAL] Log level set to %d\n", level);
    }
}

int metal_get_log_level(void) {
    return metal_log_level;
}

void metal_debug_log_impl(const char* message, ...) {
    if (metal_log_level < 3) return;
    
    va_list args;
    va_start(args, message);
    fprintf(stderr, "[METAL] ");
    vfprintf(stderr, message, args);
    fprintf(stderr, "\n");
    fflush(stderr);
    va_end(args);
}

void metal_log_warning_impl(const char* message, ...) {
    if (metal_log_level < 1) return;
    
    va_list args;
    va_start(args, message);
    fprintf(stderr, "[METAL WARNING] ");
    vfprintf(stderr, message, args);
    fprintf(stderr, "\n");
    fflush(stderr);
    va_end(args);
}

void metal_log_info_impl(const char* message, ...) {
    if (metal_log_level < 2) return;
    
    va_list args;
    va_start(args, message);
    fprintf(stderr, "[METAL INFO] ");
    vfprintf(stderr, message, args);
    fprintf(stderr, "\n");
    fflush(stderr);
    va_end(args);
}

#endif // METAL_DEBUG

void metal_init_context(void) {
    if (ctx != NULL) return;

    // Clear the debug log file at the start
    FILE *f = fopen(DEBUG_FILE, "w");
    if (f) fclose(f);

    metal_debug_log("Metal init() called");

    @autoreleasepool {
        ctx = (metal_context*)calloc(1, sizeof(metal_context)); // Use calloc to zero-initialize

        // Get the default Metal device
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) {
            metal_debug_log("Metal is not supported on this device");
            free(ctx);
            ctx = NULL;
            return;
        }

        ctx->device = (__bridge_retained void*)device; // Bridge with retain
        metal_debug_log("Metal device created: %s", [[device name] UTF8String]);

        // Create a command queue
        id<MTLCommandQueue> commandQueue = [device newCommandQueue];
        if (!commandQueue) {
            metal_debug_log("Failed to create Metal command queue");
            // Release device before freeing context
            id<MTLDevice> deviceToRelease = (__bridge_transfer id<MTLDevice>)ctx->device;
            (void)deviceToRelease; // Suppress unused variable warning - ARC will handle release
            free(ctx);
            ctx = NULL;
            return;
        }

        ctx->commandQueue = (__bridge_retained void*)commandQueue; // Bridge with retain
        metal_debug_log("Metal command queue created");

        // Initialize animation state
        ctx->angle = 0.0f;
        ctx->frameIndex = 0;

        ctx->windowSetup = false;
        metal_debug_log("Metal init complete");
    }
}

bool metal_setup_window_context(vdynamic *win) {
    if (ctx == NULL) {
        metal_debug_log("Metal context not initialized");
        return false;
    }

    metal_debug_log("Setting up Metal window");

    @autoreleasepool {
        // Extract SDL_Window from the dynamic value
        SDL_Window* window = (SDL_Window*)win->v.ptr;
        ctx->window = window;

        // Create SDL Metal view
        ctx->metalView = SDL_Metal_CreateView(window);
        if (!ctx->metalView) {
            metal_debug_log("Failed to create Metal view: %s", SDL_GetError());
            return false;
        }
        metal_debug_log("Metal view created");

        // Get the Metal layer from the Metal view - use __bridge cast
        CAMetalLayer* layer = (__bridge CAMetalLayer*)SDL_Metal_GetLayer(ctx->metalView);
        if (!layer) {
            metal_debug_log("Failed to get Metal layer");
            SDL_Metal_DestroyView(ctx->metalView);
            return false;
        }

        ctx->layer = (__bridge_retained void*)layer; // Bridge with retain
        metal_debug_log("Metal layer obtained");

        // Configure the Metal layer
        id<MTLDevice> device = (__bridge id<MTLDevice>)ctx->device;
        layer.device = device;
        layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        layer.framebufferOnly = NO; // Changed to NO to support depth buffer
        layer.opaque = YES;
        
        // Set magnification filter to nearest for pixel-perfect rendering
        layer.magnificationFilter = kCAFilterNearest;
        layer.minificationFilter = kCAFilterNearest;

        // Get window size and set layer drawable size
        int width, height;
        SDL_GetWindowSize(window, &width, &height);
        layer.drawableSize = CGSizeMake(width, height);
        metal_debug_log("Metal layer configured with size %d x %d", width, height);

        // Create depth-stencil texture for perspective rendering
        // CRITICAL: Must use Depth32Float_Stencil8 (not Depth32Float) to support both depth and stencil
        MTLTextureDescriptor *depthTextureDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float_Stencil8
                                                                                                          width:width
                                                                                                         height:height
                                                                                                      mipmapped:NO];
        depthTextureDescriptor.usage = MTLTextureUsageRenderTarget;
        depthTextureDescriptor.storageMode = MTLStorageModePrivate;

        id<MTLTexture> depthTexture = [device newTextureWithDescriptor:depthTextureDescriptor];
        if (!depthTexture) {
            metal_debug_log("Failed to create depth texture");
            return false;
        }

        ctx->depthTexture = (__bridge_retained void*)depthTexture;
        metal_debug_log("Depth texture created with size %d x %d", width, height);

        // Setup frame data for animation
        if (!metal_setup_frame_data()) {
            metal_debug_log("Failed to setup frame data");
            return false;
        }

        // Initialize frame debugging
        if (!metal_init_frame_debugging_impl()) {
            metal_debug_log("Failed to initialize frame debugging");
            return false;
        }

        ctx->windowSetup = true;
        metal_debug_log("Window setup complete");
    }

    return true;
}

void metal_shutdown_context(void) {
    if (ctx != NULL) {
        @autoreleasepool {
            // Destroy SDL Metal view
            if (ctx->metalView) {
                SDL_Metal_DestroyView(ctx->metalView);
                ctx->metalView = NULL;
            }

            // Release Metal resources with proper ARC handling
            if (ctx->pipelineState) {
                id<MTLRenderPipelineState> pipelineState = (__bridge_transfer id<MTLRenderPipelineState>)ctx->pipelineState;
                (void)pipelineState; // Suppress unused variable warning - ARC will handle release
                ctx->pipelineState = NULL;
            }

            if (ctx->vertexBuffer) {
                id<MTLBuffer> vertexBuffer = (__bridge_transfer id<MTLBuffer>)ctx->vertexBuffer;
                (void)vertexBuffer; // Suppress unused variable warning - ARC will handle release
                ctx->vertexBuffer = NULL;
            }

            if (ctx->commandQueue) {
                id<MTLCommandQueue> commandQueue = (__bridge_transfer id<MTLCommandQueue>)ctx->commandQueue;
                (void)commandQueue; // Suppress unused variable warning - ARC will handle release
                ctx->commandQueue = NULL;
            }

            if (ctx->layer) {
                CAMetalLayer* layer = (__bridge_transfer CAMetalLayer*)ctx->layer;
                (void)layer; // Suppress unused variable warning - ARC will handle release
                ctx->layer = NULL;
            }

            if (ctx->device) {
                id<MTLDevice> device = (__bridge_transfer id<MTLDevice>)ctx->device;
                (void)device; // Suppress unused variable warning - ARC will handle release
                ctx->device = NULL;
            }
        }

        free(ctx);
        ctx = NULL;
    }
}

// Hashlink exports for context management
HL_PRIM void HL_NAME(init)(void) {
    metal_init_context();
}

HL_PRIM bool HL_NAME(setup_window)(vdynamic *win) {
    return metal_setup_window_context(win);
}

HL_PRIM void HL_NAME(shutdown)(void) {
    metal_shutdown_context();
}

DEFINE_PRIM(_VOID, init, _NO_ARG);
DEFINE_PRIM(_BOOL, setup_window, _DYN);
DEFINE_PRIM(_VOID, shutdown, _NO_ARG);