#define HL_NAME(n) metal_##n

#include <hl.h>
#include <SDL2/SDL.h>
#include <SDL2/SDL_metal.h>
#include <Metal/Metal.h>
#include <QuartzCore/CAMetalLayer.h>

#define DEBUG_FILE "/tmp/metal_debug.log"

// Helper function to write debug messages to a file
void metal_debug_log(const char* message, ...) {
    va_list args;
    va_start(args, message);
    FILE *f = fopen(DEBUG_FILE, "a");
    if (f) {
        fprintf(f, "[METAL] ");
        vfprintf(f, message, args);
        fprintf(f, "\n");
        fclose(f);
    }
    va_end(args);
}

// Vertex structure with position and color for triangle rendering
typedef struct {
    float position[3];
    float color[4];
} metal_vertex;

typedef struct {
    id<MTLDevice> device;
    id<MTLCommandQueue> commandQueue;
    CAMetalLayer *layer;
    SDL_MetalView metalView;
    SDL_Window *window;
    bool windowSetup;

    // Pipeline state for triangle rendering
    id<MTLRenderPipelineState> pipelineState;
    id<MTLBuffer> vertexBuffer;
    NSUInteger vertexCount;

    // Support for argument buffers
    id<MTLBuffer> argBuffer;
    id<MTLBuffer> positionBuffer;
    id<MTLBuffer> colorBuffer;
} metal_context;

static metal_context *ctx = NULL;

// Metal shader source code as a string with argument buffer support
// This is the Metal shading language code for the vertex and fragment shaders
static NSString *shaderSource = @"\
#include <metal_stdlib>\n\
using namespace metal;\n\
\n\
// Define the data structure for the argument buffer\n\
struct VertexData {\n\
    device float3* positions [[id(0)]];\n\
    device float3* colors [[id(1)]];\n\
};\n\
\n\
// Define the output of the vertex shader, which is the input to the fragment shader\n\
struct RasterizerData {\n\
    float4 position [[position]];\n\
    float3 color;\n\
};\n\
\n\
// Vertex shader function using argument buffer\n\
vertex RasterizerData vertexShader(uint vertexID [[vertex_id]],\n\
                                  device const VertexData* vertexData [[buffer(0)]]) {\n\
    RasterizerData out;\n\
\n\
    // Get position and color from the argument buffer\n\
    out.position = float4(vertexData->positions[vertexID], 1.0);\n\
    out.color = float3(vertexData->colors[vertexID]);\n\
\n\
    return out;\n\
}\n\
\n\
// Fragment shader function\n\
fragment float4 fragmentShader(RasterizerData in [[stage_in]]) {\n\
    // Simply return the interpolated color with alpha = 1.0\n\
    return float4(in.color, 1.0);\n\
}\n\
";

// Function to create the render pipeline for triangle rendering
bool metal_setup_pipeline(void) {
    if (ctx == NULL || !ctx->windowSetup) return false;

    metal_debug_log("Setting up Metal render pipeline for triangles");

    @autoreleasepool {
        // Create a library from the shader source
        NSError *error = nil;
        id<MTLLibrary> library = [ctx->device newLibraryWithSource:shaderSource
                                                          options:nil
                                                            error:&error];
        if (!library) {
            metal_debug_log("Failed to create shader library: %s",
                           error ? [[error localizedDescription] UTF8String] : "Unknown error");
            return false;
        }

        // Get the vertex and fragment shader functions
        id<MTLFunction> vertexFunction = [library newFunctionWithName:@"vertexShader"];
        id<MTLFunction> fragmentFunction = [library newFunctionWithName:@"fragmentShader"];

        if (!vertexFunction || !fragmentFunction) {
            metal_debug_log("Failed to get shader functions");
            return false;
        }

        // Create a vertex descriptor to describe the vertex layout
        MTLVertexDescriptor *vertexDescriptor = [MTLVertexDescriptor vertexDescriptor];

        // Position attribute
        vertexDescriptor.attributes[0].format = MTLVertexFormatFloat3;
        vertexDescriptor.attributes[0].offset = offsetof(metal_vertex, position);
        vertexDescriptor.attributes[0].bufferIndex = 0;

        // Color attribute
        vertexDescriptor.attributes[1].format = MTLVertexFormatFloat4;
        vertexDescriptor.attributes[1].offset = offsetof(metal_vertex, color);
        vertexDescriptor.attributes[1].bufferIndex = 0;

        // Single buffer layout
        vertexDescriptor.layouts[0].stride = sizeof(metal_vertex);
        vertexDescriptor.layouts[0].stepRate = 1;
        vertexDescriptor.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;

        // Create the render pipeline state descriptor
        MTLRenderPipelineDescriptor *pipelineDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
        pipelineDescriptor.vertexFunction = vertexFunction;
        pipelineDescriptor.fragmentFunction = fragmentFunction;
        pipelineDescriptor.vertexDescriptor = vertexDescriptor;
        pipelineDescriptor.colorAttachments[0].pixelFormat = ctx->layer.pixelFormat;
        pipelineDescriptor.colorAttachments[0].blendingEnabled = YES;
        pipelineDescriptor.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
        pipelineDescriptor.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
        pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;

        // Create the pipeline state
        error = nil;
        ctx->pipelineState = [ctx->device newRenderPipelineStateWithDescriptor:pipelineDescriptor
                                                                        error:&error];
        if (!ctx->pipelineState) {
            metal_debug_log("Failed to create render pipeline state: %s",
                           error ? [[error localizedDescription] UTF8String] : "Unknown error");
            return false;
        }

        metal_debug_log("Render pipeline created successfully");
    }

    return true;
}

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

    // Clear the debug log file at the start
    FILE *f = fopen(DEBUG_FILE, "w");
    if (f) fclose(f);

    metal_debug_log("Metal init() called");

    @autoreleasepool {
        ctx = (metal_context*)malloc(sizeof(metal_context));
        memset(ctx, 0, sizeof(metal_context));

        // Get the default Metal device
        ctx->device = MTLCreateSystemDefaultDevice();
        if (!ctx->device) {
            metal_debug_log("Metal is not supported on this device");
            free(ctx);
            ctx = NULL;
            return;
        }
        metal_debug_log("Metal device created: %s", [[ctx->device name] UTF8String]);

        // Create a command queue
        ctx->commandQueue = [ctx->device newCommandQueue];
        if (!ctx->commandQueue) {
            metal_debug_log("Failed to create Metal command queue");
            free(ctx);
            ctx = NULL;
            return;
        }
        metal_debug_log("Metal command queue created");

        // Don't create render pass descriptor here - create it fresh each frame
        ctx->windowSetup = false;
        metal_debug_log("Metal init complete");
    }
}

// Use _DYN instead of specific SDL window type to match what Heaps expects
HL_PRIM bool HL_NAME(setup_window)(vdynamic *win) {
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

        // Get the Metal layer from the Metal view
        ctx->layer = (CAMetalLayer *)SDL_Metal_GetLayer(ctx->metalView);
        if (!ctx->layer) {
            metal_debug_log("Failed to get Metal layer");
            SDL_Metal_DestroyView(ctx->metalView);
            return false;
        }
        metal_debug_log("Metal layer obtained");

        // Configure the Metal layer using the same settings as the working test
        ctx->layer.device = ctx->device;
        ctx->layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        ctx->layer.framebufferOnly = YES;
        ctx->layer.opaque = YES;

        // Get window size and set layer drawable size
        int width, height;
        SDL_GetWindowSize(window, &width, &height);
        ctx->layer.drawableSize = CGSizeMake(width, height);
        metal_debug_log("Metal layer configured with size %d x %d", width, height);

        ctx->windowSetup = true;
        metal_debug_log("Window setup complete");
    }

    return true;
}

HL_PRIM bool HL_NAME(begin_render)(int r, int g, int b, int a) {
    if (ctx == NULL || !ctx->windowSetup) {
        metal_debug_log("Cannot begin_render: ctx is NULL or window not set up");
        return false;
    }

    metal_debug_log("begin_render called with color RGBA(%d, %d, %d, %d)", r, g, b, a);

    @autoreleasepool {
        // Get the next drawable
        id<CAMetalDrawable> drawable = [ctx->layer nextDrawable];
        if (!drawable) {
            metal_debug_log("Failed to get next drawable");
            return false;
        }
        metal_debug_log("Got Metal drawable");

        // Create a fresh render pass descriptor each time - this is the key fix
        MTLRenderPassDescriptor* renderPassDescriptor = [MTLRenderPassDescriptor renderPassDescriptor];
        if (!renderPassDescriptor) {
            metal_debug_log("Failed to create render pass descriptor");
            return false;
        }

        // Configure the render pass descriptor
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture;
        renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
        renderPassDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(
            r/255.0, g/255.0, b/255.0, a/255.0
        );
        metal_debug_log("Render pass descriptor configured with clear color");

        // Create command buffer
        id<MTLCommandBuffer> commandBuffer = [ctx->commandQueue commandBuffer];
        if (!commandBuffer) {
            metal_debug_log("Failed to create command buffer");
            return false;
        }

        // Create render encoder
        id<MTLRenderCommandEncoder> renderEncoder =
            [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
        if (!renderEncoder) {
            metal_debug_log("Failed to create render encoder");
            return false;
        }

        // End encoding immediately (just clearing)
        [renderEncoder endEncoding];
        metal_debug_log("Render encoding complete");

        // Present the drawable
        [commandBuffer presentDrawable:drawable];

        // Commit the command buffer
        [commandBuffer commit];
        metal_debug_log("Command buffer committed");
    }

    return true;
}

// Create a triangle with the specified vertices and colors
HL_PRIM bool HL_NAME(create_triangle)(float* positions, float* colors, int vertexCount) {
    if (ctx == NULL || vertexCount <= 0) {
        metal_debug_log("Cannot create triangle: ctx is NULL or invalid vertex count");
        return false;
    }

    metal_debug_log("Creating triangle with %d vertices", vertexCount);

    @autoreleasepool {
        // Create a temporary array to store vertices
        metal_vertex* vertices = (metal_vertex*)malloc(vertexCount * sizeof(metal_vertex));
        if (!vertices) {
            metal_debug_log("Failed to allocate memory for vertices");
            return false;
        }

        // Fill the vertex data
        for (int i = 0; i < vertexCount; i++) {
            // Copy position data (3 floats per vertex)
            vertices[i].position[0] = positions[i * 3];
            vertices[i].position[1] = positions[i * 3 + 1];
            vertices[i].position[2] = positions[i * 3 + 2];

            // Copy color data (4 floats per vertex)
            vertices[i].color[0] = colors[i * 4];
            vertices[i].color[1] = colors[i * 4 + 1];
            vertices[i].color[2] = colors[i * 4 + 2];
            vertices[i].color[3] = colors[i * 4 + 3];

            metal_debug_log("Vertex %d: pos(%f, %f, %f) color(%f, %f, %f, %f)", i,
                           vertices[i].position[0], vertices[i].position[1], vertices[i].position[2],
                           vertices[i].color[0], vertices[i].color[1], vertices[i].color[2], vertices[i].color[3]);
        }

        // Create Metal buffer with the vertex data
        ctx->vertexBuffer = [ctx->device newBufferWithBytes:vertices
                                                    length:vertexCount * sizeof(metal_vertex)
                                                   options:MTLResourceStorageModeShared];
        free(vertices);

        if (!ctx->vertexBuffer) {
            metal_debug_log("Failed to create vertex buffer");
            return false;
        }

        // Store vertex count for rendering
        ctx->vertexCount = vertexCount;

        // Create render pipeline if it doesn't exist yet
        if (!ctx->pipelineState) {
            if (!metal_setup_pipeline()) {
                metal_debug_log("Failed to set up render pipeline");
                ctx->vertexBuffer = nil;
                return false;
            }
        }

        metal_debug_log("Triangle created successfully with %d vertices", vertexCount);
    }

    return true;
}

// Create a triangle with argument buffers approach
HL_PRIM bool HL_NAME(create_triangle_with_argbuffers)(float* positions, float* colors, int vertexCount) {
    if (ctx == NULL || vertexCount <= 0) {
        metal_debug_log("Cannot create triangle with argbuffers: ctx is NULL or invalid vertex count");
        return false;
    }

    metal_debug_log("Creating triangle with argument buffers (%d vertices)", vertexCount);

    @autoreleasepool {
        // Calculate sizes for the position and color buffers
        const size_t positionsDataSize = vertexCount * 3 * sizeof(float); // 3 floats per position
        const size_t colorsDataSize = vertexCount * 3 * sizeof(float);    // 3 floats per color (RGB)

        // Create separate buffers for positions and colors
        ctx->positionBuffer = [ctx->device newBufferWithBytes:positions
                                                      length:positionsDataSize
                                                     options:MTLResourceStorageModeShared];

        ctx->colorBuffer = [ctx->device newBufferWithBytes:colors
                                                   length:colorsDataSize
                                                  options:MTLResourceStorageModeShared];

        if (!ctx->positionBuffer || !ctx->colorBuffer) {
            metal_debug_log("Failed to create position or color buffer");
            return false;
        }

        // Update render pipeline if needed
        if (!ctx->pipelineState) {
            if (!metal_setup_pipeline()) {
                metal_debug_log("Failed to set up render pipeline");
                return false;
            }
        }

        // Get the vertex function to create the argument encoder
        NSError *error = nil;
        id<MTLLibrary> library = [ctx->device newLibraryWithSource:shaderSource
                                                          options:nil
                                                            error:&error];
        if (!library) {
            metal_debug_log("Failed to create shader library for argument encoder: %s", 
                           error ? [[error localizedDescription] UTF8String] : "Unknown error");
            return false;
        }

        id<MTLFunction> vertexFunction = [library newFunctionWithName:@"vertexShader"];
        if (!vertexFunction) {
            metal_debug_log("Failed to get vertex function for argument encoder");
            return false;
        }

        // Check if the function supports argument encoders
        if (![vertexFunction respondsToSelector:@selector(newArgumentEncoderWithBufferIndex:)]) {
            metal_debug_log("Function does not support argument encoders - using fallback");
            // Fallback: just store the buffers without argument encoder
            ctx->vertexCount = vertexCount;
            return true;
        }

        // Create the argument encoder for buffer 0 (our VertexData struct)
        id<MTLArgumentEncoder> argEncoder = [vertexFunction newArgumentEncoderWithBufferIndex:0];
        if (!argEncoder) {
            metal_debug_log("Failed to create argument encoder");
            return false;
        }

        // Create the argument buffer
        ctx->argBuffer = [ctx->device newBufferWithLength:argEncoder.encodedLength
                                                options:MTLResourceStorageModeShared];
        if (!ctx->argBuffer) {
            metal_debug_log("Failed to create argument buffer");
            return false;
        }

        // Encode the argument buffer
        [argEncoder setArgumentBuffer:ctx->argBuffer offset:0];
        [argEncoder setBuffer:ctx->positionBuffer offset:0 atIndex:0]; // positions at index 0
        [argEncoder setBuffer:ctx->colorBuffer offset:0 atIndex:1];    // colors at index 1

        // Store vertex count for rendering
        ctx->vertexCount = vertexCount;

        metal_debug_log("Triangle with argument buffers created successfully");
        return true;
    }
}

// Render the triangle - updated version of begin_render that includes triangle rendering
HL_PRIM bool HL_NAME(render_triangle)(int r, int g, int b, int a) {
    if (ctx == NULL || !ctx->windowSetup) return false;

    @autoreleasepool {
        // Get the next drawable from the layer
        id<CAMetalDrawable> drawable = [ctx->layer nextDrawable];
        if (!drawable) return false;

        // Create command buffer
        id<MTLCommandBuffer> commandBuffer = [ctx->commandQueue commandBuffer];

        // Set up render pass descriptor with clear color
        MTLRenderPassDescriptor *renderPassDescriptor = [MTLRenderPassDescriptor renderPassDescriptor];
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture;
        renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
        renderPassDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;

        // Set clear color (convert from 0-255 int to 0.0-1.0 float)
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(
            r / 255.0, g / 255.0, b / 255.0, a / 255.0
        );

        // Create render command encoder
        id<MTLRenderCommandEncoder> renderEncoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];

        // Render triangle if we have vertex data
        if (ctx->pipelineState && ctx->vertexBuffer && ctx->vertexCount > 0) {
            [renderEncoder setRenderPipelineState:ctx->pipelineState];
            [renderEncoder setVertexBuffer:ctx->vertexBuffer offset:0 atIndex:0];
            [renderEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:ctx->vertexCount];
        }

        [renderEncoder endEncoding];
        [commandBuffer presentDrawable:drawable];
        [commandBuffer commit];
        [commandBuffer waitUntilCompleted];
    }

    return true;
}

// Render the triangle using argument buffers
HL_PRIM bool HL_NAME(render_triangle_with_argbuffers)(int r, int g, int b, int a) {
    if (ctx == NULL || !ctx->windowSetup) {
        metal_debug_log("Cannot render with argument buffers: ctx is NULL or window not set up");
        return false;
    }

    if (!ctx->argBuffer || !ctx->positionBuffer || !ctx->colorBuffer) {
        metal_debug_log("Cannot render with argument buffers: buffers not initialized");
        return false;
    }

    @autoreleasepool {
        // Get the next drawable from the layer
        id<CAMetalDrawable> drawable = [ctx->layer nextDrawable];
        if (!drawable) return false;

        // Create command buffer
        id<MTLCommandBuffer> commandBuffer = [ctx->commandQueue commandBuffer];

        // Set up render pass descriptor with clear color
        MTLRenderPassDescriptor *renderPassDescriptor = [MTLRenderPassDescriptor renderPassDescriptor];
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture;
        renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
        renderPassDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;

        // Set clear color (convert from 0-255 int to 0.0-1.0 float)
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(
            r / 255.0, g / 255.0, b / 255.0, a / 255.0
        );

        // Create render command encoder
        id<MTLRenderCommandEncoder> renderEncoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];

        // Render triangle using argument buffers
        if (ctx->pipelineState && ctx->vertexCount > 0) {
            // Set the render pipeline state
            [renderEncoder setRenderPipelineState:ctx->pipelineState];

            // Set the argument buffer
            [renderEncoder setVertexBuffer:ctx->argBuffer offset:0 atIndex:0];

            // Use the resources that the argument buffer refers to
            [renderEncoder useResource:ctx->positionBuffer usage:MTLResourceUsageRead stages:MTLRenderStageVertex];
            [renderEncoder useResource:ctx->colorBuffer usage:MTLResourceUsageRead stages:MTLRenderStageVertex];

            // Draw the triangle
            [renderEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:ctx->vertexCount];

            metal_debug_log("Triangle rendered with argument buffers");
        }

        [renderEncoder endEncoding];
        [commandBuffer presentDrawable:drawable];
        [commandBuffer commit];
        [commandBuffer waitUntilCompleted];
    }

    return true;
}

// Add function to update buffer data
HL_PRIM bool HL_NAME(update_buffer)(vdynamic *buffer, void *data, int size, int offset) {
    if (ctx == NULL || buffer == NULL || buffer->t != &hlt_i32 || data == NULL || size <= 0) {
        metal_debug_log("Invalid parameters for update_buffer");
        return false;
    }

    @autoreleasepool {
        // Get the Metal buffer by casting integer back to pointer
        id<MTLBuffer> metalBuffer = (id<MTLBuffer>)(uintptr_t)buffer->v.i;

        // Check if the buffer size is sufficient
        if (offset + size > metalBuffer.length) {
            metal_debug_log("Buffer update exceeds buffer size: offset %d + size %d > buffer length %lu",
                           offset, size, metalBuffer.length);
            return false;
        }

        // Copy data to the buffer
        void *bufferPtr = metalBuffer.contents;
        if (bufferPtr) {
            memcpy((char*)bufferPtr + offset, data, size);
            return true;
        } else {
            metal_debug_log("Failed to get buffer contents for update");
            return false;
        }
    }
}

// Add proper buffer allocation for Metal
HL_PRIM vdynamic* HL_NAME(alloc_buffer)(int size, int flags) {
    if (ctx == NULL) return NULL;

    @autoreleasepool {
        // Debug output for allocation
        metal_debug_log("Metal allocating buffer of size: %d bytes", size);

        if (size <= 0) {
            metal_debug_log("Warning: Trying to allocate a buffer of size <= 0");
            size = 1024; // Minimum size
        }

        // Create a Metal buffer with the specified size
        id<MTLBuffer> metalBuffer = [ctx->device newBufferWithLength:size
                                                             options:MTLResourceStorageModeShared];

        if (!metalBuffer) {
            metal_debug_log("Failed to allocate Metal buffer of size %d", size);
            return NULL;
        }

        // Create a dynamic integer value to return
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
            if (ctx->pipelineState) {
                ctx->pipelineState = nil;
            }

            if (ctx->vertexBuffer) {
                ctx->vertexBuffer = nil;
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

// Export Hashlink functions to be exposed MetalDriver.hx ---------------------------------
DEFINE_PRIM(_VOID, init, _NO_ARG);
DEFINE_PRIM(_BOOL, setup_window, _DYN);
DEFINE_PRIM(_BOOL, begin_render, _I32 _I32 _I32 _I32);
DEFINE_PRIM(_DYN, alloc_buffer, _I32 _I32);
DEFINE_PRIM(_VOID, dispose_buffer, _DYN);
DEFINE_PRIM(_VOID, shutdown, _NO_ARG);
DEFINE_PRIM(_VOID, test_window, _I32 _I32 _I32);  // Test function
DEFINE_PRIM(_BOOL, create_triangle, _BYTES _BYTES _I32);  // Triangle creation function
DEFINE_PRIM(_BOOL, render_triangle, _I32 _I32 _I32 _I32); // Triangle rendering function
DEFINE_PRIM(_BOOL, update_buffer, _DYN _BYTES _I32 _I32); // Buffer update function the interest rates don't come down
DEFINE_PRIM(_BOOL, create_triangle_with_argbuffers, _BYTES _BYTES _I32);
DEFINE_PRIM(_BOOL, render_triangle_with_argbuffers, _I32 _I32 _I32 _I32);