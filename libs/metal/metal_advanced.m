#include "metal.h"


bool metal_create_triangle_with_argbuffers_impl(float* positions, float* colors, int vertexCount) {
    if (ctx == NULL || vertexCount <= 0) {
        metal_debug_log("Cannot create triangle with argbuffers: ctx is NULL or invalid vertex count");
        return false;
    }

    metal_debug_log("Creating triangle with argument buffers (%d vertices)", vertexCount);

    @autoreleasepool {
        id<MTLDevice> device = (__bridge id<MTLDevice>)ctx->device;

        // Calculate sizes for the position and color buffers
        const size_t positionsDataSize = vertexCount * 3 * sizeof(float); // 3 floats per position
        const size_t colorsDataSize = vertexCount * 3 * sizeof(float);    // 3 floats per color (RGB)

        // Create separate buffers for positions and colors
        id<MTLBuffer> positionBuffer = [device newBufferWithBytes:positions
                                                           length:positionsDataSize
                                                          options:MTLResourceStorageModeShared];

        id<MTLBuffer> colorBuffer = [device newBufferWithBytes:colors
                                                        length:colorsDataSize
                                                       options:MTLResourceStorageModeShared];

        if (!positionBuffer || !colorBuffer) {
            metal_debug_log("Failed to create position or color buffer");
            return false;
        }

        ctx->positionBuffer = (__bridge_retained void*)positionBuffer;
        ctx->colorBuffer = (__bridge_retained void*)colorBuffer;

        // Update render pipeline if needed
        if (!ctx->pipelineState) {
            if (!metal_setup_pipeline()) {
                metal_debug_log("Failed to set up render pipeline");
                return false;
            }
        }

        // Get the vertex function to create the argument encoder
        NSError *error = nil;
        id<MTLLibrary> library = [device newLibraryWithSource:shaderSource
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
        id<MTLBuffer> argBuffer = [device newBufferWithLength:argEncoder.encodedLength
                                                       options:MTLResourceStorageModeShared];
        if (!argBuffer) {
            metal_debug_log("Failed to create argument buffer");
            return false;
        }

        ctx->argBuffer = (__bridge_retained void*)argBuffer;

        // Encode the argument buffer
        [argEncoder setArgumentBuffer:argBuffer offset:0];
        [argEncoder setBuffer:positionBuffer offset:0 atIndex:0]; // positions at index 0
        [argEncoder setBuffer:colorBuffer offset:0 atIndex:1];    // colors at index 1

        // Store vertex count for rendering
        ctx->vertexCount = vertexCount;

        metal_debug_log("Triangle with argument buffers created successfully");
        return true;
    }
}

bool metal_render_triangle_with_argbuffers_impl(int r, int g, int b, int a) {
    if (ctx == NULL || !ctx->windowSetup) {
        metal_debug_log("Cannot render with argument buffers: ctx is NULL or window not set up");
        return false;
    }

    if (!ctx->argBuffer || !ctx->positionBuffer || !ctx->colorBuffer) {
        metal_debug_log("Cannot render with argument buffers: buffers not initialized");
        return false;
    }

    @autoreleasepool {
        dispatch_semaphore_t semaphore = (__bridge dispatch_semaphore_t)ctx->frameSemaphore;
        CAMetalLayer* layer = (__bridge CAMetalLayer*)ctx->layer;
        id<MTLCommandQueue> commandQueue = (__bridge id<MTLCommandQueue>)ctx->commandQueue;

        // Wait for available frame buffer
        dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);

        // Update frame index
        ctx->frameIndex = (ctx->frameIndex + 1) % MAX_FRAMES_IN_FLIGHT;
        id<MTLBuffer> currentFrameDataBuffer = (__bridge id<MTLBuffer>)ctx->frameDataBuffers[ctx->frameIndex];

        // Update animation angle
        ctx->angle += 0.01f;

        // Update frame data buffer with new angle
        frame_data* frameData = (frame_data*)currentFrameDataBuffer.contents;
        frameData->angle = ctx->angle;

        // Get the next drawable from the layer
        id<CAMetalDrawable> drawable = [layer nextDrawable];
        if (!drawable) {
            dispatch_semaphore_signal(semaphore);
            return false;
        }

        // Create command buffer
        id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];

        // Add completion handler to signal semaphore when command buffer completes
        [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> buffer) {
            dispatch_semaphore_signal(semaphore);
        }];

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
            id<MTLRenderPipelineState> pipelineState = (__bridge id<MTLRenderPipelineState>)ctx->pipelineState;
            id<MTLBuffer> argBuffer = (__bridge id<MTLBuffer>)ctx->argBuffer;
            id<MTLBuffer> positionBuffer = (__bridge id<MTLBuffer>)ctx->positionBuffer;
            id<MTLBuffer> colorBuffer = (__bridge id<MTLBuffer>)ctx->colorBuffer;

            // Set the render pipeline state
            [renderEncoder setRenderPipelineState:pipelineState];

            // Set the argument buffer (VertexData)
            [renderEncoder setVertexBuffer:argBuffer offset:0 atIndex:0];

            // Set the frame data buffer
            [renderEncoder setVertexBuffer:currentFrameDataBuffer offset:0 atIndex:1];

            // Use the resources that the argument buffer refers to
            [renderEncoder useResource:positionBuffer usage:MTLResourceUsageRead stages:MTLRenderStageVertex];
            [renderEncoder useResource:colorBuffer usage:MTLResourceUsageRead stages:MTLRenderStageVertex];

            // Draw the triangle
            [renderEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:ctx->vertexCount];

            metal_debug_log("Animated triangle rendered with argument buffers (angle: %f)", ctx->angle);
        }

        [renderEncoder endEncoding];
        [commandBuffer presentDrawable:drawable];
        [commandBuffer commit];
    }

    return true;
}

bool metal_create_instanced_rectangles_impl(void) {
    if (ctx == NULL) return false;

    metal_debug_log("Creating instanced rectangles");

    @autoreleasepool {
        id<MTLDevice> device = (__bridge id<MTLDevice>)ctx->device;

        // Create rectangle vertices (4 vertices for a quad) - FIXED positioning
        const float s = 0.5f;
        typedef struct {
            float position[3];
        } vertex_data;

        // Rectangle vertices that form a proper square
        vertex_data vertices[] = {
            {{ -s, -s, 0.0f }},  // Bottom left
            {{ +s, -s, 0.0f }},  // Bottom right
            {{ +s, +s, 0.0f }},  // Top right
            {{ -s, +s, 0.0f }}   // Top left
        };

        uint16_t indices[] = {
            0, 1, 2,  // First triangle
            2, 3, 1   // Second triangle
        };

        metal_debug_log("Creating rectangle with 4 vertices and 6 indices (2 triangles)");

        // Create vertex buffer for instancing (separate from triangle buffer)
        id<MTLBuffer> instanceVertexBuffer = [device newBufferWithBytes:vertices
                                                                 length:sizeof(vertices)
                                                                options:MTLResourceStorageModeShared];

        // Create index buffer for instancing
        id<MTLBuffer> instanceIndexBuffer = [device newBufferWithBytes:indices
                                                                length:sizeof(indices)
                                                               options:MTLResourceStorageModeShared];

        if (!instanceVertexBuffer || !instanceIndexBuffer) {
            metal_debug_log("Failed to create instance vertex or index buffers");
            return false;
        }

        ctx->instanceVertexBuffer = (__bridge_retained void*)instanceVertexBuffer;
        ctx->instanceIndexBuffer = (__bridge_retained void*)instanceIndexBuffer;

        ctx->instanceVertexCount = 4;
        ctx->instanceIndexCount = 6;  // Make sure this is 6, not 3!

        metal_debug_log("Created rectangle geometry: %lu vertices, %lu indices",
                       ctx->instanceVertexCount, ctx->instanceIndexCount);

        // Create instance data buffers for triple buffering
        for (int i = 0; i < MAX_FRAMES_IN_FLIGHT; i++) {
            id<MTLBuffer> buffer = [device newBufferWithLength:NUM_INSTANCES * sizeof(metal_instance_data)
                                                       options:MTLResourceStorageModeShared];
            if (!buffer) {
                metal_debug_log("Failed to create instance data buffer %d", i);
                return false;
            }
            ctx->instanceDataBuffers[i] = (__bridge_retained void*)buffer;
        }

        // Setup instancing pipeline if needed
        if (!ctx->instancingPipelineState) {
            if (!metal_setup_instancing_pipeline()) {
                metal_debug_log("Failed to setup instancing pipeline");
                return false;
            }
        }

        metal_debug_log("Instanced rectangles created successfully - each instance will draw 2 triangles forming a rectangle");
    }

    return true;
}

bool metal_render_instanced_rectangles_impl(int r, int g, int b, int a) {
    if (ctx == NULL || !ctx->windowSetup) return false;

    @autoreleasepool {
        dispatch_semaphore_t semaphore = (__bridge dispatch_semaphore_t)ctx->frameSemaphore;
        CAMetalLayer* layer = (__bridge CAMetalLayer*)ctx->layer;
        id<MTLCommandQueue> commandQueue = (__bridge id<MTLCommandQueue>)ctx->commandQueue;

        // Wait for available frame buffer
        dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);

        // Update frame index
        ctx->frameIndex = (ctx->frameIndex + 1) % MAX_FRAMES_IN_FLIGHT;
        id<MTLBuffer> currentInstanceBuffer = (__bridge id<MTLBuffer>)ctx->instanceDataBuffers[ctx->frameIndex];

        // Update animation angle
        ctx->angle += 0.01f;

        // Update instance data
        metal_instance_data* instanceData = (metal_instance_data*)currentInstanceBuffer.contents;
        const float scl = 0.1f;

        for (size_t i = 0; i < NUM_INSTANCES; ++i) {
            float iDivNumInstances = i / (float)NUM_INSTANCES;
            float xoff = (iDivNumInstances * 2.0f - 1.0f) + (1.f/NUM_INSTANCES);
            float yoff = sin((iDivNumInstances + ctx->angle) * 2.0f * M_PI);

            // Create rotation and translation matrix
            simd_float4x4 transform = simd_matrix(
                simd_make_float4(scl * sin(ctx->angle), scl * cos(ctx->angle), 0.f, 0.f),
                simd_make_float4(scl * cos(ctx->angle), scl * -sin(ctx->angle), 0.f, 0.f),
                simd_make_float4(0.f, 0.f, scl, 0.f),
                simd_make_float4(xoff, yoff, 0.f, 1.f)
            );

            instanceData[i].instanceTransform = transform;

            // Create instance color
            float red = iDivNumInstances;
            float green = 1.0f - red;
            float blue = sin(M_PI * 2.0f * iDivNumInstances);
            instanceData[i].instanceColor = simd_make_float4(red, green, blue, 1.0f);
        }

        // Get next drawable
        id<CAMetalDrawable> drawable = [layer nextDrawable];
        if (!drawable) {
            dispatch_semaphore_signal(semaphore);
            return false;
        }

        // Create command buffer
        id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];

        // Add completion handler
        [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> buffer) {
            dispatch_semaphore_signal(semaphore);
        }];

        // Create render pass descriptor
        MTLRenderPassDescriptor *renderPassDescriptor = [MTLRenderPassDescriptor renderPassDescriptor];
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture;
        renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
        renderPassDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(
            r / 255.0, g / 255.0, b / 255.0, a / 255.0
        );

        // Create render encoder
        id<MTLRenderCommandEncoder> renderEncoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];

        // Render instanced rectangles
        if (ctx->instancingPipelineState && ctx->instanceVertexBuffer && ctx->instanceIndexBuffer) {
            id<MTLRenderPipelineState> instancingPipelineState = (__bridge id<MTLRenderPipelineState>)ctx->instancingPipelineState;
            id<MTLBuffer> instanceVertexBuffer = (__bridge id<MTLBuffer>)ctx->instanceVertexBuffer;
            id<MTLBuffer> instanceIndexBuffer = (__bridge id<MTLBuffer>)ctx->instanceIndexBuffer;

            [renderEncoder setRenderPipelineState:instancingPipelineState];
            [renderEncoder setVertexBuffer:instanceVertexBuffer offset:0 atIndex:0];
            [renderEncoder setVertexBuffer:currentInstanceBuffer offset:0 atIndex:1];

            [renderEncoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                      indexCount:ctx->instanceIndexCount
                                       indexType:MTLIndexTypeUInt16
                                     indexBuffer:instanceIndexBuffer
                               indexBufferOffset:0
                                   instanceCount:NUM_INSTANCES];
        }

        [renderEncoder endEncoding];
        [commandBuffer presentDrawable:drawable];
        [commandBuffer commit];
    }

    return true;
}

// Hashlink exports for advanced rendering
HL_PRIM bool HL_NAME(create_triangle_with_argbuffers)(float* positions, float* colors, int vertexCount) {
    return metal_create_triangle_with_argbuffers_impl(positions, colors, vertexCount);
}

HL_PRIM bool HL_NAME(render_triangle_with_argbuffers)(int r, int g, int b, int a) {
    return metal_render_triangle_with_argbuffers_impl(r, g, b, a);
}

HL_PRIM bool HL_NAME(create_instanced_rectangles)(void) {
    return metal_create_instanced_rectangles_impl();
}

HL_PRIM bool HL_NAME(render_instanced_rectangles)(int r, int g, int b, int a) {
    return metal_render_instanced_rectangles_impl(r, g, b, a);
}

DEFINE_PRIM(_BOOL, create_triangle_with_argbuffers, _BYTES _BYTES _I32);
DEFINE_PRIM(_BOOL, render_triangle_with_argbuffers, _I32 _I32 _I32 _I32);
DEFINE_PRIM(_BOOL, create_instanced_rectangles, _NO_ARG);
DEFINE_PRIM(_BOOL, render_instanced_rectangles, _I32 _I32 _I32 _I32);