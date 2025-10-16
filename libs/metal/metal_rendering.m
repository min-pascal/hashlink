#include "metal.h"

bool metal_begin_render_impl(int r, int g, int b, int a) {
    if (ctx == NULL || !ctx->windowSetup) {
        metal_debug_log("Cannot begin_render: ctx is NULL or window not set up");
        return false;
    }

    metal_debug_log("begin_render called with color RGBA(%d, %d, %d, %d)", r, g, b, a);

    @autoreleasepool {
        CAMetalLayer* layer = (__bridge CAMetalLayer*)ctx->layer;
        id<MTLCommandQueue> commandQueue = (__bridge id<MTLCommandQueue>)ctx->commandQueue;
        
        // Get the next drawable
        id<CAMetalDrawable> drawable = [layer nextDrawable];
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
        id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];
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

bool metal_create_triangle_impl(float* positions, float* colors, int vertexCount) {
    if (ctx == NULL || vertexCount <= 0) {
        metal_debug_log("Cannot create triangle: ctx is NULL or invalid vertex count");
        return false;
    }

    metal_debug_log("Creating triangle with %d vertices", vertexCount);

    @autoreleasepool {
        id<MTLDevice> device = (__bridge id<MTLDevice>)ctx->device;
        
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
        id<MTLBuffer> vertexBuffer = [device newBufferWithBytes:vertices
                                                         length:vertexCount * sizeof(metal_vertex)
                                                        options:MTLResourceStorageModeShared];
        free(vertices);

        if (!vertexBuffer) {
            metal_debug_log("Failed to create vertex buffer");
            return false;
        }

        ctx->vertexBuffer = (__bridge_retained void*)vertexBuffer;

        // Store vertex count for rendering
        ctx->vertexCount = vertexCount;

        // Create render pipeline if it doesn't exist yet
        if (!ctx->pipelineState) {
            if (!metal_setup_pipeline()) {
                metal_debug_log("Failed to set up render pipeline");
                if (ctx->vertexBuffer) {
                    id<MTLBuffer> vertexBuffer = (__bridge_transfer id<MTLBuffer>)ctx->vertexBuffer;
                    (void)vertexBuffer; // ARC will handle release
                    ctx->vertexBuffer = NULL;
                }
                return false;
            }
        }

        metal_debug_log("Triangle created successfully with %d vertices", vertexCount);
    }

    return true;
}

bool metal_render_triangle_impl(int r, int g, int b, int a) {
    if (ctx == NULL || !ctx->windowSetup) return false;

    @autoreleasepool {
        CAMetalLayer* layer = (__bridge CAMetalLayer*)ctx->layer;
        id<MTLCommandQueue> commandQueue = (__bridge id<MTLCommandQueue>)ctx->commandQueue;
        
        // Get the next drawable from the layer
        id<CAMetalDrawable> drawable = [layer nextDrawable];
        if (!drawable) return false;

        // Create command buffer
        id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];

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
            id<MTLRenderPipelineState> pipelineState = (__bridge id<MTLRenderPipelineState>)ctx->pipelineState;
            id<MTLBuffer> vertexBuffer = (__bridge id<MTLBuffer>)ctx->vertexBuffer;
            
            [renderEncoder setRenderPipelineState:pipelineState];
            [renderEncoder setVertexBuffer:vertexBuffer offset:0 atIndex:0];
            [renderEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:ctx->vertexCount];
        }

        [renderEncoder endEncoding];
        [commandBuffer presentDrawable:drawable];
        [commandBuffer commit];
        [commandBuffer waitUntilCompleted];
    }

    return true;
}

// Hashlink exports for basic rendering
HL_PRIM bool HL_NAME(begin_render)(int r, int g, int b, int a) {
    return metal_begin_render_impl(r, g, b, a);
}

HL_PRIM bool HL_NAME(create_triangle)(float* positions, float* colors, int vertexCount) {
    return metal_create_triangle_impl(positions, colors, vertexCount);
}

HL_PRIM bool HL_NAME(render_triangle)(int r, int g, int b, int a) {
    return metal_render_triangle_impl(r, g, b, a);
}

DEFINE_PRIM(_BOOL, begin_render, _I32 _I32 _I32 _I32);
DEFINE_PRIM(_BOOL, create_triangle, _BYTES _BYTES _I32);
DEFINE_PRIM(_BOOL, render_triangle, _I32 _I32 _I32 _I32);