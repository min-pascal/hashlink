#include "metal.h"

// Math utility functions for perspective rendering - FIXED to match C++ reference
static simd_float4x4 makePerspective(float fovRadians, float aspect, float znear, float zfar) {
    float ys = 1.0f / tanf(fovRadians * 0.5f);
    float xs = ys / aspect;
    float zs = zfar / (znear - zfar);
    // Use simd_matrix_from_rows to match C++ reference exactly
    return simd_matrix_from_rows(
        simd_make_float4(xs, 0.0f, 0.0f, 0.0f),
        simd_make_float4(0.0f, ys, 0.0f, 0.0f),
        simd_make_float4(0.0f, 0.0f, zs, znear * zs),
        simd_make_float4(0.0f, 0.0f, -1.0f, 0.0f)
    );
}

static simd_float4x4 makeIdentity() {
    // Use column-major construction like C++ reference
    return simd_matrix(
        simd_make_float4(1.0f, 0.0f, 0.0f, 0.0f),
        simd_make_float4(0.0f, 1.0f, 0.0f, 0.0f),
        simd_make_float4(0.0f, 0.0f, 1.0f, 0.0f),
        simd_make_float4(0.0f, 0.0f, 0.0f, 1.0f)
    );
}

static simd_float4x4 makeTranslate(simd_float3 v) {
    // Use column-major construction like C++ reference
    simd_float4 col0 = simd_make_float4(1.0f, 0.0f, 0.0f, 0.0f);
    simd_float4 col1 = simd_make_float4(0.0f, 1.0f, 0.0f, 0.0f);
    simd_float4 col2 = simd_make_float4(0.0f, 0.0f, 1.0f, 0.0f);
    simd_float4 col3 = simd_make_float4(v.x, v.y, v.z, 1.0f);
    return simd_matrix(col0, col1, col2, col3);
}

static simd_float4x4 makeYRotate(float angleRadians) {
    float a = angleRadians;
    // Use simd_matrix_from_rows to match C++ reference
    return simd_matrix_from_rows(
        simd_make_float4(cosf(a), 0.0f, sinf(a), 0.0f),
        simd_make_float4(0.0f, 1.0f, 0.0f, 0.0f),
        simd_make_float4(-sinf(a), 0.0f, cosf(a), 0.0f),
        simd_make_float4(0.0f, 0.0f, 0.0f, 1.0f)
    );
}

static simd_float4x4 makeZRotate(float angleRadians) {
    float a = angleRadians;
    // Use simd_matrix_from_rows to match C++ reference
    return simd_matrix_from_rows(
        simd_make_float4(cosf(a), sinf(a), 0.0f, 0.0f),
        simd_make_float4(-sinf(a), cosf(a), 0.0f, 0.0f),
        simd_make_float4(0.0f, 0.0f, 1.0f, 0.0f),
        simd_make_float4(0.0f, 0.0f, 0.0f, 1.0f)
    );
}

static simd_float4x4 makeScale(simd_float3 v) {
    // Use column-major construction like C++ reference
    return simd_matrix(
        simd_make_float4(v.x, 0.0f, 0.0f, 0.0f),
        simd_make_float4(0.0f, v.y, 0.0f, 0.0f),
        simd_make_float4(0.0f, 0.0f, v.z, 0.0f),
        simd_make_float4(0.0f, 0.0f, 0.0f, 1.0f)
    );
}

simd_float3 addFloat3(simd_float3 a, simd_float3 b) {
    return simd_make_float3(a.x + b.x, a.y + b.y, a.z + b.z);
}

bool metal_create_perspective_cubes_impl(void) {
    if (ctx == NULL) return false;

    metal_debug_log("Creating perspective cubes");

    @autoreleasepool {
        id<MTLDevice> device = (__bridge id<MTLDevice>)ctx->device;

        // Create cube vertices - 8 vertices for a cube
        const float s = 0.5f;
        typedef struct {
            float position[3];
        } vertex_data;

        vertex_data vertices[] = {
            {{ -s, -s, +s }}, // 0: front bottom left
            {{ +s, -s, +s }}, // 1: front bottom right
            {{ +s, +s, +s }}, // 2: front top right
            {{ -s, +s, +s }}, // 3: front top left

            {{ -s, -s, -s }}, // 4: back bottom left
            {{ -s, +s, -s }}, // 5: back top left
            {{ +s, +s, -s }}, // 6: back top right
            {{ +s, -s, -s }}  // 7: back bottom right
        };

        // Create cube indices - 12 triangles (2 per face, 6 faces)
        uint16_t indices[] = {
            0, 1, 2,  2, 3, 0, // front face
            1, 7, 6,  6, 2, 1, // right face
            7, 4, 5,  5, 6, 7, // back face
            4, 0, 3,  3, 5, 4, // left face
            3, 2, 6,  6, 5, 3, // top face
            4, 7, 1,  1, 0, 4  // bottom face
        };

        metal_debug_log("Creating cube with 8 vertices and 36 indices (12 triangles)");

        // Create vertex buffer for perspective rendering
        id<MTLBuffer> perspectiveVertexBuffer = [device newBufferWithBytes:vertices
                                                                    length:sizeof(vertices)
                                                                   options:MTLResourceStorageModeShared];

        // Create index buffer for perspective rendering
        id<MTLBuffer> perspectiveIndexBuffer = [device newBufferWithBytes:indices
                                                                   length:sizeof(indices)
                                                                  options:MTLResourceStorageModeShared];

        if (!perspectiveVertexBuffer || !perspectiveIndexBuffer) {
            metal_debug_log("Failed to create perspective vertex or index buffers");
            return false;
        }

        ctx->perspectiveVertexBuffer = (__bridge_retained void*)perspectiveVertexBuffer;
        ctx->perspectiveIndexBuffer = (__bridge_retained void*)perspectiveIndexBuffer;

        ctx->perspectiveVertexCount = 8;
        ctx->perspectiveIndexCount = 36;

        metal_debug_log("Created cube geometry: %lu vertices, %lu indices",
                       ctx->perspectiveVertexCount, ctx->perspectiveIndexCount);

        // Create instance data buffers for triple buffering
        for (int i = 0; i < MAX_FRAMES_IN_FLIGHT; i++) {
            id<MTLBuffer> buffer = [device newBufferWithLength:NUM_INSTANCES * sizeof(metal_instance_data)
                                                       options:MTLResourceStorageModeShared];
            if (!buffer) {
                metal_debug_log("Failed to create perspective instance data buffer %d", i);
                return false;
            }
            // Reuse instance data buffers if they exist, otherwise create new ones
            if (!ctx->instanceDataBuffers[i]) {
                ctx->instanceDataBuffers[i] = (__bridge_retained void*)buffer;
            }
        }

        // Create camera data buffers for triple buffering
        for (int i = 0; i < MAX_FRAMES_IN_FLIGHT; i++) {
            id<MTLBuffer> buffer = [device newBufferWithLength:sizeof(struct metal_camera_data)
                                                       options:MTLResourceStorageModeShared];
            if (!buffer) {
                metal_debug_log("Failed to create camera data buffer %d", i);
                return false;
            }
            ctx->cameraDataBuffers[i] = (__bridge_retained void*)buffer;
        }

        // Create debug vertex buffer for rendering dots at cube vertices
        id<MTLBuffer> debugVertexBuffer = [device newBufferWithBytes:vertices
                                                              length:sizeof(vertices)
                                                             options:MTLResourceStorageModeShared];
        if (!debugVertexBuffer) {
            metal_debug_log("Failed to create debug vertex buffer");
            return false;
        }
        ctx->debugVertexBuffer = (__bridge_retained void*)debugVertexBuffer;
        ctx->debugVertexCount = 8; // 8 vertices per cube
        ctx->debugDotsEnabled = false; // Initially disabled

        // Create debug instance data buffers for triple buffering
        for (int i = 0; i < MAX_FRAMES_IN_FLIGHT; i++) {
            id<MTLBuffer> buffer = [device newBufferWithLength:NUM_INSTANCES * sizeof(metal_instance_data)
                                                       options:MTLResourceStorageModeShared];
            if (!buffer) {
                metal_debug_log("Failed to create debug instance data buffer %d", i);
                return false;
            }
            ctx->debugInstanceDataBuffers[i] = (__bridge_retained void*)buffer;
        }

        // Setup debug point pipeline
        if (!metal_setup_debug_point_pipeline()) {
            metal_debug_log("Failed to setup debug point pipeline");
            return false;
        }

        // Setup perspective pipeline if needed
        if (!ctx->perspectivePipelineState) {
            if (!metal_setup_perspective_pipeline()) {
                metal_debug_log("Failed to setup perspective pipeline");
                return false;
            }
        }

        metal_debug_log("Perspective cubes created successfully");
    }

    return true;
}

bool metal_render_perspective_cubes_impl(int r, int g, int b, int a) {
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
        id<MTLBuffer> currentCameraBuffer = (__bridge id<MTLBuffer>)ctx->cameraDataBuffers[ctx->frameIndex];

        // Update animation angle
        ctx->angle += 0.01f;

        // Update instance data
        metal_instance_data* instanceData = (metal_instance_data*)currentInstanceBuffer.contents;
        const float scl = 0.1f;
        simd_float3 objectPosition = simd_make_float3(0.0f, 0.0f, -5.0f);

        // Create world rotation matrices
        simd_float4x4 rt = makeTranslate(objectPosition);
        simd_float4x4 rr = makeYRotate(-ctx->angle);
        simd_float4x4 rtInv = makeTranslate(simd_make_float3(-objectPosition.x, -objectPosition.y, -objectPosition.z));
        simd_float4x4 fullObjectRot = simd_mul(simd_mul(rt, rr), rtInv);

        for (size_t i = 0; i < NUM_INSTANCES; ++i) {
            float iDivNumInstances = i / (float)NUM_INSTANCES;
            float xoff = (iDivNumInstances * 2.0f - 1.0f) + (1.0f/NUM_INSTANCES);
            float yoff = sin((iDivNumInstances + ctx->angle) * 2.0f * M_PI);

            // Create transformation matrices
            simd_float4x4 scale = makeScale(simd_make_float3(scl, scl, scl));
            simd_float4x4 zrot = makeZRotate(ctx->angle);
            simd_float4x4 yrot = makeYRotate(ctx->angle);
            simd_float4x4 translate = makeTranslate(addFloat3(objectPosition, simd_make_float3(xoff, yoff, 0.0f)));

            instanceData[i].instanceTransform = simd_mul(simd_mul(simd_mul(simd_mul(fullObjectRot, translate), yrot), zrot), scale);

            // Create instance color
            float red = iDivNumInstances;
            float green = 1.0f - red;
            float blue = sin(M_PI * 2.0f * iDivNumInstances);
            instanceData[i].instanceColor = simd_make_float4(red, green, blue, 1.0f);
        }

        // Update camera data
        struct metal_camera_data* cameraData = (struct metal_camera_data*)currentCameraBuffer.contents;
        cameraData->perspectiveTransform = makePerspective(45.0f * M_PI / 180.0f, 1.0f, 0.03f, 500.0f);
        cameraData->worldTransform = makeIdentity();

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

        // Create render pass descriptor with depth buffer
        MTLRenderPassDescriptor *renderPassDescriptor = [MTLRenderPassDescriptor renderPassDescriptor];
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture;
        renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
        renderPassDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(
            r / 255.0, g / 255.0, b / 255.0, a / 255.0
        );

        // Configure depth attachment for 3D rendering
        id<MTLTexture> depthTexture = (__bridge id<MTLTexture>)ctx->depthTexture;
        renderPassDescriptor.depthAttachment.texture = depthTexture;
        renderPassDescriptor.depthAttachment.loadAction = MTLLoadActionClear;
        renderPassDescriptor.depthAttachment.storeAction = MTLStoreActionDontCare;
        renderPassDescriptor.depthAttachment.clearDepth = 1.0;

        // Create render encoder
        id<MTLRenderCommandEncoder> renderEncoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];

        // Render perspective cubes
        if (ctx->perspectivePipelineState && ctx->perspectiveVertexBuffer && ctx->perspectiveIndexBuffer) {
            id<MTLRenderPipelineState> perspectivePipelineState = (__bridge id<MTLRenderPipelineState>)ctx->perspectivePipelineState;
            id<MTLBuffer> perspectiveVertexBuffer = (__bridge id<MTLBuffer>)ctx->perspectiveVertexBuffer;
            id<MTLBuffer> perspectiveIndexBuffer = (__bridge id<MTLBuffer>)ctx->perspectiveIndexBuffer;

            [renderEncoder setRenderPipelineState:perspectivePipelineState];

            // Set depth stencil state if available
            if (ctx->perspectiveDepthStencilState) {
                id<MTLDepthStencilState> depthStencilState = (__bridge id<MTLDepthStencilState>)ctx->perspectiveDepthStencilState;
                [renderEncoder setDepthStencilState:depthStencilState];
            }

            [renderEncoder setVertexBuffer:perspectiveVertexBuffer offset:0 atIndex:0];
            [renderEncoder setVertexBuffer:currentInstanceBuffer offset:0 atIndex:1];
            [renderEncoder setVertexBuffer:currentCameraBuffer offset:0 atIndex:2];

            [renderEncoder setCullMode:MTLCullModeBack];
            [renderEncoder setFrontFacingWinding:MTLWindingCounterClockwise];

            [renderEncoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                      indexCount:ctx->perspectiveIndexCount
                                       indexType:MTLIndexTypeUInt16
                                     indexBuffer:perspectiveIndexBuffer
                               indexBufferOffset:0
                                   instanceCount:NUM_INSTANCES];
        }

        // Render debug dots on vertices if enabled
        if (ctx->debugDotsEnabled && ctx->debugPipelineState && ctx->debugVertexBuffer) {
            // Update debug instance data (same transforms as cubes)
            id<MTLBuffer> currentDebugInstanceBuffer = (__bridge id<MTLBuffer>)ctx->debugInstanceDataBuffers[ctx->frameIndex];
            metal_instance_data* debugInstanceData = (metal_instance_data*)currentDebugInstanceBuffer.contents;

            // Copy the same transform data for debug dots
            for (size_t i = 0; i < NUM_INSTANCES; ++i) {
                debugInstanceData[i].instanceTransform = instanceData[i].instanceTransform;
            }

            id<MTLRenderPipelineState> debugPipelineState = (__bridge id<MTLRenderPipelineState>)ctx->debugPipelineState;
            id<MTLBuffer> debugVertexBuffer = (__bridge id<MTLBuffer>)ctx->debugVertexBuffer;

            [renderEncoder setRenderPipelineState:debugPipelineState];

            // Use the same depth stencil state for proper depth testing
            if (ctx->perspectiveDepthStencilState) {
                id<MTLDepthStencilState> depthStencilState = (__bridge id<MTLDepthStencilState>)ctx->perspectiveDepthStencilState;
                [renderEncoder setDepthStencilState:depthStencilState];
            }

            [renderEncoder setVertexBuffer:debugVertexBuffer offset:0 atIndex:0];
            [renderEncoder setVertexBuffer:currentDebugInstanceBuffer offset:0 atIndex:1];
            [renderEncoder setVertexBuffer:currentCameraBuffer offset:0 atIndex:2];

            // Render as points (one point per vertex per instance)
            [renderEncoder drawPrimitives:MTLPrimitiveTypePoint
                              vertexStart:0
                              vertexCount:ctx->debugVertexCount
                            instanceCount:NUM_INSTANCES];
        }

        [renderEncoder endEncoding];
        [commandBuffer presentDrawable:drawable];
        [commandBuffer commit];
    }

    return true;
}

bool metal_enable_debug_dots_impl(bool enable) {
    if (ctx == NULL) {
        metal_debug_log("Cannot enable debug dots: ctx is NULL");
        return false;
    }

    ctx->debugDotsEnabled = enable;
    metal_debug_log("Debug dots %s", enable ? "ENABLED" : "DISABLED");
    return true;
}

// Hashlink exports for perspective rendering
HL_PRIM bool HL_NAME(create_perspective_cubes)(void) {
    return metal_create_perspective_cubes_impl();
}

HL_PRIM bool HL_NAME(render_perspective_cubes)(int r, int g, int b, int a) {
    return metal_render_perspective_cubes_impl(r, g, b, a);
}

HL_PRIM bool HL_NAME(enable_debug_dots)(bool enable) {
    return metal_enable_debug_dots_impl(enable);
}

DEFINE_PRIM(_BOOL, create_perspective_cubes, _NO_ARG);
DEFINE_PRIM(_BOOL, render_perspective_cubes, _I32 _I32 _I32 _I32);
DEFINE_PRIM(_BOOL, enable_debug_dots, _BOOL);
