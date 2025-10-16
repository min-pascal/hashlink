// metal_lighting.m - Lighting implementation for 10x10x10 cubes with normals
#include "metal.h"
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <simd/simd.h>

// Constants for lighting
#define LIGHTING_INSTANCE_ROWS 10
#define LIGHTING_INSTANCE_COLUMNS 10
#define LIGHTING_INSTANCE_DEPTH 10
#define LIGHTING_NUM_INSTANCES (LIGHTING_INSTANCE_ROWS * LIGHTING_INSTANCE_COLUMNS * LIGHTING_INSTANCE_DEPTH)

// Lighting shader source
NSString *lightingShaderSource = @"#include <metal_stdlib>\n"
"using namespace metal;\n"
"\n"
"struct v2f\n"
"{\n"
"    float4 position [[position]];\n"
"    float3 normal;\n"
"    half3 color;\n"
"};\n"
"\n"
"struct VertexData\n"
"{\n"
"    float position[3];\n"
"    float normal[3];\n"
"};\n"
"\n"
"struct InstanceData\n"
"{\n"
"    float4x4 instanceTransform;\n"
"    float3x3 instanceNormalTransform;\n"
"    float4 instanceColor;\n"
"};\n"
"\n"
"struct CameraData\n"
"{\n"
"    float4x4 perspectiveTransform;\n"
"    float4x4 worldTransform;\n"
"    float3x3 worldNormalTransform;\n"
"};\n"
"\n"
"v2f vertex vertexMain( device const VertexData* vertexData [[buffer(0)]],\n"
"                       device const InstanceData* instanceData [[buffer(1)]],\n"
"                       device const CameraData& cameraData [[buffer(2)]],\n"
"                       uint vertexId [[vertex_id]],\n"
"                       uint instanceId [[instance_id]] )\n"
"{\n"
"    v2f o;\n"
"\n"
"    const device VertexData& vd = vertexData[ vertexId ];\n"
"    float4 pos = float4( vd.position[0], vd.position[1], vd.position[2], 1.0 );\n"
"    pos = instanceData[ instanceId ].instanceTransform * pos;\n"
"    pos = cameraData.perspectiveTransform * cameraData.worldTransform * pos;\n"
"    o.position = pos;\n"
"\n"
"    float3 normal = float3( vd.normal[0], vd.normal[1], vd.normal[2] );\n"
"    normal = instanceData[ instanceId ].instanceNormalTransform * normal;\n"
"    normal = cameraData.worldNormalTransform * normal;\n"
"    o.normal = normal;\n"
"\n"
"    o.color = half3( instanceData[ instanceId ].instanceColor.rgb );\n"
"    return o;\n"
"}\n"
"\n"
"half4 fragment fragmentMain( v2f in [[stage_in]] )\n"
"{\n"
"    // assume light coming from (front-top-right)\n"
"    float3 l = normalize(float3( 1.0, 1.0, 0.8 ));\n"
"    float3 n = normalize( in.normal );\n"
"\n"
"    float ndotl = saturate( dot( n, l ) );\n"
"    return half4( in.color * 0.1 + in.color * ndotl, 1.0 );\n"
"}\n";

// Math utility functions
static simd_float4x4 makePerspectiveLighting(float fovRadians, float aspect, float znear, float zfar) {
    float ys = 1.0f / tanf(fovRadians * 0.5f);
    float xs = ys / aspect;
    float zs = zfar / (znear - zfar);
    return simd_matrix_from_rows(
        (simd_float4){xs, 0.0f, 0.0f, 0.0f},
        (simd_float4){0.0f, ys, 0.0f, 0.0f},
        (simd_float4){0.0f, 0.0f, zs, znear * zs},
        (simd_float4){0, 0, -1, 0}
    );
}

static simd_float4x4 makeIdentityLighting() {
    // Use column-major construction like the working perspective implementation
    return simd_matrix(
        simd_make_float4(1.0f, 0.0f, 0.0f, 0.0f),
        simd_make_float4(0.0f, 1.0f, 0.0f, 0.0f),
        simd_make_float4(0.0f, 0.0f, 1.0f, 0.0f),
        simd_make_float4(0.0f, 0.0f, 0.0f, 1.0f)
    );
}

static simd_float4x4 makeTranslateLighting(simd_float3 v) {
    // Use column-major construction like the working perspective implementation
    simd_float4 col0 = simd_make_float4(1.0f, 0.0f, 0.0f, 0.0f);
    simd_float4 col1 = simd_make_float4(0.0f, 1.0f, 0.0f, 0.0f);
    simd_float4 col2 = simd_make_float4(0.0f, 0.0f, 1.0f, 0.0f);
    simd_float4 col3 = simd_make_float4(v.x, v.y, v.z, 1.0f);
    return simd_matrix(col0, col1, col2, col3);
}

static simd_float4x4 makeScaleLighting(simd_float3 v) {
    // Use column-major construction
    return simd_matrix(
        simd_make_float4(v.x, 0.0f, 0.0f, 0.0f),
        simd_make_float4(0.0f, v.y, 0.0f, 0.0f),
        simd_make_float4(0.0f, 0.0f, v.z, 0.0f),
        simd_make_float4(0.0f, 0.0f, 0.0f, 1.0f)
    );
}

static simd_float4x4 makeYRotateLighting(float angleRadians) {
    float a = angleRadians;
    return simd_matrix_from_rows(
        simd_make_float4(cosf(a), 0.0f, sinf(a), 0.0f),
        simd_make_float4(0.0f, 1.0f, 0.0f, 0.0f),
        simd_make_float4(-sinf(a), 0.0f, cosf(a), 0.0f),
        simd_make_float4(0.0f, 0.0f, 0.0f, 1.0f)
    );
}

static simd_float4x4 makeXRotateLighting(float angleRadians) {
    float a = angleRadians;
    return simd_matrix_from_rows(
        simd_make_float4(1.0f, 0.0f, 0.0f, 0.0f),
        simd_make_float4(0.0f, cosf(a), sinf(a), 0.0f),
        simd_make_float4(0.0f, -sinf(a), cosf(a), 0.0f),
        simd_make_float4(0.0f, 0.0f, 0.0f, 1.0f)
    );
}

static simd_float4x4 makeZRotateLighting(float angleRadians) {
    float a = angleRadians;
    return simd_matrix_from_rows(
        simd_make_float4(cosf(a), sinf(a), 0.0f, 0.0f),
        simd_make_float4(-sinf(a), cosf(a), 0.0f, 0.0f),
        simd_make_float4(0.0f, 0.0f, 1.0f, 0.0f),
        simd_make_float4(0.0f, 0.0f, 0.0f, 1.0f)
    );
}

static simd_float3x3 discardTranslationLighting(simd_float4x4 m) {
    return simd_matrix(m.columns[0].xyz, m.columns[1].xyz, m.columns[2].xyz);
}

bool metal_setup_lighting_pipeline(void) {
    if (!ctx || !ctx->device) {
        return false;
    }

    id<MTLDevice> device = (__bridge id<MTLDevice>)ctx->device;

    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:lightingShaderSource options:nil error:&error];
    if (!library) {
        return false;
    }

    id<MTLFunction> vertexFunction = [library newFunctionWithName:@"vertexMain"];
    id<MTLFunction> fragmentFunction = [library newFunctionWithName:@"fragmentMain"];

    if (!vertexFunction || !fragmentFunction) {
        return false;
    }

    MTLRenderPipelineDescriptor *pipelineDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
    pipelineDescriptor.vertexFunction = vertexFunction;
    pipelineDescriptor.fragmentFunction = fragmentFunction;
    // Match the actual layer and depth texture formats used by the Metal context
    pipelineDescriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    pipelineDescriptor.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;

    id<MTLRenderPipelineState> pipelineState = [device newRenderPipelineStateWithDescriptor:pipelineDescriptor error:&error];
    if (!pipelineState) {
        return false;
    }

    ctx->lightingPipelineState = (__bridge_retained void*)pipelineState;

    // Create depth stencil state
    MTLDepthStencilDescriptor *depthDescriptor = [[MTLDepthStencilDescriptor alloc] init];
    depthDescriptor.depthCompareFunction = MTLCompareFunctionLess;
    depthDescriptor.depthWriteEnabled = YES;

    id<MTLDepthStencilState> depthState = [device newDepthStencilStateWithDescriptor:depthDescriptor];
    ctx->lightingDepthStencilState = (__bridge_retained void*)depthState;

    return true;
}

bool metal_create_lighting_cubes_impl(void) {
    if (!ctx || !ctx->device) {
        return false;
    }

    id<MTLDevice> device = (__bridge id<MTLDevice>)ctx->device;

    // Setup pipeline if not already done
    if (!ctx->lightingPipelineState) {
        if (!metal_setup_lighting_pipeline()) {
            return false;
        }
    }

    // Define cube vertices with normals (6 faces, 4 vertices each)
    const float s = 0.5f;
    struct metal_lighting_vertex verts[] = {
        // Front face (z = +s)
        {{ -s, -s, +s }, { 0.0f,  0.0f,  1.0f }},
        {{ +s, -s, +s }, { 0.0f,  0.0f,  1.0f }},
        {{ +s, +s, +s }, { 0.0f,  0.0f,  1.0f }},
        {{ -s, +s, +s }, { 0.0f,  0.0f,  1.0f }},

        // Right face (x = +s)
        {{ +s, -s, +s }, { 1.0f,  0.0f,  0.0f }},
        {{ +s, -s, -s }, { 1.0f,  0.0f,  0.0f }},
        {{ +s, +s, -s }, { 1.0f,  0.0f,  0.0f }},
        {{ +s, +s, +s }, { 1.0f,  0.0f,  0.0f }},

        // Back face (z = -s)
        {{ +s, -s, -s }, { 0.0f,  0.0f, -1.0f }},
        {{ -s, -s, -s }, { 0.0f,  0.0f, -1.0f }},
        {{ -s, +s, -s }, { 0.0f,  0.0f, -1.0f }},
        {{ +s, +s, -s }, { 0.0f,  0.0f, -1.0f }},

        // Left face (x = -s)
        {{ -s, -s, -s }, { -1.0f, 0.0f,  0.0f }},
        {{ -s, -s, +s }, { -1.0f, 0.0f,  0.0f }},
        {{ -s, +s, +s }, { -1.0f, 0.0f,  0.0f }},
        {{ -s, +s, -s }, { -1.0f, 0.0f,  0.0f }},

        // Top face (y = +s)
        {{ -s, +s, +s }, { 0.0f,  1.0f,  0.0f }},
        {{ +s, +s, +s }, { 0.0f,  1.0f,  0.0f }},
        {{ +s, +s, -s }, { 0.0f,  1.0f,  0.0f }},
        {{ -s, +s, -s }, { 0.0f,  1.0f,  0.0f }},

        // Bottom face (y = -s)
        {{ -s, -s, -s }, { 0.0f, -1.0f,  0.0f }},
        {{ +s, -s, -s }, { 0.0f, -1.0f,  0.0f }},
        {{ +s, -s, +s }, { 0.0f, -1.0f,  0.0f }},
        {{ -s, -s, +s }, { 0.0f, -1.0f,  0.0f }},
    };

    // Define indices for cube faces (2 triangles per face)
    uint16_t indices[] = {
         0,  1,  2,  2,  3,  0, // front
         4,  5,  6,  6,  7,  4, // right
         8,  9, 10, 10, 11,  8, // back
        12, 13, 14, 14, 15, 12, // left
        16, 17, 18, 18, 19, 16, // top
        20, 21, 22, 22, 23, 20, // bottom
    };

    // Create vertex buffer
    NSUInteger vertexDataSize = sizeof(verts);
    id<MTLBuffer> vertexBuffer = [device newBufferWithLength:vertexDataSize options:MTLResourceStorageModeManaged];
    if (!vertexBuffer) {
        return false;
    }

    memcpy(vertexBuffer.contents, verts, vertexDataSize);
    [vertexBuffer didModifyRange:NSMakeRange(0, vertexDataSize)];
    ctx->lightingVertexBuffer = (__bridge_retained void*)vertexBuffer;
    ctx->lightingVertexCount = sizeof(verts) / sizeof(verts[0]);

    // Create index buffer
    NSUInteger indexDataSize = sizeof(indices);
    id<MTLBuffer> indexBuffer = [device newBufferWithLength:indexDataSize options:MTLResourceStorageModeManaged];
    if (!indexBuffer) {
        return false;
    }

    memcpy(indexBuffer.contents, indices, indexDataSize);
    [indexBuffer didModifyRange:NSMakeRange(0, indexDataSize)];
    ctx->lightingIndexBuffer = (__bridge_retained void*)indexBuffer;
    ctx->lightingIndexCount = sizeof(indices) / sizeof(indices[0]);

    // Create instance data buffers for triple buffering
    NSUInteger instanceDataSize = LIGHTING_NUM_INSTANCES * sizeof(struct metal_lighting_instance_data);
    for (int i = 0; i < MAX_FRAMES_IN_FLIGHT; ++i) {
        id<MTLBuffer> instanceBuffer = [device newBufferWithLength:instanceDataSize options:MTLResourceStorageModeManaged];
        if (!instanceBuffer) {
            return false;
        }
        ctx->lightingInstanceDataBuffers[i] = (__bridge_retained void*)instanceBuffer;
    }

    // Create camera data buffers for triple buffering
    NSUInteger cameraDataSize = sizeof(struct metal_lighting_camera_data);
    for (int i = 0; i < MAX_FRAMES_IN_FLIGHT; ++i) {
        id<MTLBuffer> cameraBuffer = [device newBufferWithLength:cameraDataSize options:MTLResourceStorageModeManaged];
        if (!cameraBuffer) {
            return false;
        }
        ctx->lightingCameraDataBuffers[i] = (__bridge_retained void*)cameraBuffer;
    }

    return true;
}

bool metal_render_lighting_cubes_impl(int r, int g, int b, int a) {
    if (!ctx || !ctx->device || !ctx->lightingPipelineState) {
        return false;
    }

    @autoreleasepool {
        dispatch_semaphore_t semaphore = (__bridge dispatch_semaphore_t)ctx->frameSemaphore;
        id<MTLCommandQueue> commandQueue = (__bridge id<MTLCommandQueue>)ctx->commandQueue;
        CAMetalLayer *layer = (__bridge CAMetalLayer*)ctx->layer;

        // Wait for available frame buffer
        dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);

        // Get current frame index
        int frameIndex = ctx->frameIndex % MAX_FRAMES_IN_FLIGHT;

        // Get drawable
        id<CAMetalDrawable> drawable = [layer nextDrawable];
        if (!drawable) {
            dispatch_semaphore_signal(semaphore);
            return false;
        }

        // Create render pass descriptor with proper depth buffer setup
        MTLRenderPassDescriptor *renderPassDescriptor = [MTLRenderPassDescriptor renderPassDescriptor];
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture;
        renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(r/255.0, g/255.0, b/255.0, a/255.0);
        renderPassDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;

        // Configure depth attachment for proper 3D rendering
        id<MTLTexture> depthTexture = (__bridge id<MTLTexture>)ctx->depthTexture;
        renderPassDescriptor.depthAttachment.texture = depthTexture;
        renderPassDescriptor.depthAttachment.loadAction = MTLLoadActionClear;
        renderPassDescriptor.depthAttachment.storeAction = MTLStoreActionDontCare;
        renderPassDescriptor.depthAttachment.clearDepth = 1.0;

        // Update animation
        ctx->angle += 0.002f;

        // Update instance data
        id<MTLBuffer> instanceBuffer = (__bridge id<MTLBuffer>)ctx->lightingInstanceDataBuffers[frameIndex];
        struct metal_lighting_instance_data *instanceData = (struct metal_lighting_instance_data*)instanceBuffer.contents;

        const float scl = 0.2f;
        simd_float3 objectPosition = {0.0f, 0.0f, -10.0f};

        simd_float4x4 rt = makeTranslateLighting(objectPosition);
        simd_float4x4 rr1 = makeYRotateLighting(-ctx->angle);
        simd_float4x4 rr0 = makeXRotateLighting(ctx->angle * 0.5f);
        simd_float3 negObjectPos = {-objectPosition.x, -objectPosition.y, -objectPosition.z};
        simd_float4x4 rtInv = makeTranslateLighting(negObjectPos);
        simd_float4x4 fullObjectRot = simd_mul(simd_mul(simd_mul(rt, rr1), rr0), rtInv);

        size_t ix = 0, iy = 0, iz = 0;
        for (size_t i = 0; i < LIGHTING_NUM_INSTANCES; ++i) {
            if (ix == LIGHTING_INSTANCE_ROWS) {
                ix = 0;
                iy += 1;
            }
            if (iy == LIGHTING_INSTANCE_ROWS) {
                iy = 0;
                iz += 1;
            }

            simd_float4x4 scale = makeScaleLighting((simd_float3){scl, scl, scl});
            simd_float4x4 zrot = makeZRotateLighting(ctx->angle * sinf((float)ix));
            simd_float4x4 yrot = makeYRotateLighting(ctx->angle * cosf((float)iy));

            float x = ((float)ix - (float)LIGHTING_INSTANCE_ROWS/2.0f) * (2.0f * scl) + scl;
            float y = ((float)iy - (float)LIGHTING_INSTANCE_COLUMNS/2.0f) * (2.0f * scl) + scl;
            float z = ((float)iz - (float)LIGHTING_INSTANCE_DEPTH/2.0f) * (2.0f * scl);
            simd_float3 translateVec = addFloat3(objectPosition, (simd_float3){x, y, z});
            simd_float4x4 translate = makeTranslateLighting(translateVec);

            instanceData[i].instanceTransform = simd_mul(simd_mul(simd_mul(simd_mul(fullObjectRot, translate), yrot), zrot), scale);
            instanceData[i].instanceNormalTransform = discardTranslationLighting(instanceData[i].instanceTransform);

            float iDivNumInstances = i / (float)LIGHTING_NUM_INSTANCES;
            float red = iDivNumInstances;
            float green = 1.0f - red;
            float blue = sinf(M_PI * 2.0f * iDivNumInstances);
            instanceData[i].instanceColor = (simd_float4){red, green, blue, 1.0f};

            ix += 1;
        }
        [instanceBuffer didModifyRange:NSMakeRange(0, instanceBuffer.length)];

        // Update camera data
        id<MTLBuffer> cameraBuffer = (__bridge id<MTLBuffer>)ctx->lightingCameraDataBuffers[frameIndex];
        struct metal_lighting_camera_data *cameraData = (struct metal_lighting_camera_data*)cameraBuffer.contents;
        cameraData->perspectiveTransform = makePerspectiveLighting(45.0f * M_PI / 180.0f, 1.0f, 0.03f, 500.0f);
        cameraData->worldTransform = makeIdentityLighting();
        cameraData->worldNormalTransform = discardTranslationLighting(cameraData->worldTransform);
        [cameraBuffer didModifyRange:NSMakeRange(0, sizeof(struct metal_lighting_camera_data))];

        // Create command buffer and encoder
        id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];

        // Add completion handler
        [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> buffer) {
            dispatch_semaphore_signal(semaphore);
        }];

        id<MTLRenderCommandEncoder> renderEncoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];

        // Set pipeline state and depth stencil state
        [renderEncoder setRenderPipelineState:(__bridge id<MTLRenderPipelineState>)ctx->lightingPipelineState];
        [renderEncoder setDepthStencilState:(__bridge id<MTLDepthStencilState>)ctx->lightingDepthStencilState];

        // Set vertex buffers
        [renderEncoder setVertexBuffer:(__bridge id<MTLBuffer>)ctx->lightingVertexBuffer offset:0 atIndex:0];
        [renderEncoder setVertexBuffer:instanceBuffer offset:0 atIndex:1];
        [renderEncoder setVertexBuffer:cameraBuffer offset:0 atIndex:2];

        // Set culling mode
        [renderEncoder setCullMode:MTLCullModeBack];
        [renderEncoder setFrontFacingWinding:MTLWindingCounterClockwise];

        // Draw indexed primitives with instancing
        [renderEncoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                  indexCount:ctx->lightingIndexCount
                                   indexType:MTLIndexTypeUInt16
                                 indexBuffer:(__bridge id<MTLBuffer>)ctx->lightingIndexBuffer
                           indexBufferOffset:0
                               instanceCount:LIGHTING_NUM_INSTANCES];

        [renderEncoder endEncoding];
        [commandBuffer presentDrawable:drawable];
        [commandBuffer commit];

        // Update frame index
        ctx->frameIndex = (ctx->frameIndex + 1) % MAX_FRAMES_IN_FLIGHT;
    }

    return true;
}

// Haxe native function bindings
HL_PRIM bool HL_NAME(create_lighting_cubes)(void) {
    return metal_create_lighting_cubes_impl();
}

HL_PRIM bool HL_NAME(render_lighting_cubes)(int r, int g, int b, int a) {
    return metal_render_lighting_cubes_impl(r, g, b, a);
}

DEFINE_PRIM(_BOOL, create_lighting_cubes, _NO_ARG);
DEFINE_PRIM(_BOOL, render_lighting_cubes, _I32 _I32 _I32 _I32);
