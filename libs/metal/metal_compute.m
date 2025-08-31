#include "metal.h"

// Compute shader source for Mandelbrot texture generation with animation
NSString *computeShaderSource = @"\
#include <metal_stdlib>\n\
using namespace metal;\n\
\n\
kernel void mandelbrot_set(texture2d< half, access::write > tex [[texture(0)]],\n\
                           uint2 index [[thread_position_in_grid]],\n\
                           uint2 gridSize [[threads_per_grid]],\n\
                           device const uint* frame [[buffer(0)]])\n\
{\n\
    constexpr float kAnimationFrequency = 0.01;\n\
    constexpr float kAnimationSpeed = 4;\n\
    constexpr float kAnimationScaleLow = 0.62;\n\
    constexpr float kAnimationScale = 0.38;\n\
\n\
    constexpr float2 kMandelbrotPixelOffset = {-0.2, -0.35};\n\
    constexpr float2 kMandelbrotOrigin = {-1.2, -0.32};\n\
    constexpr float2 kMandelbrotScale = {2.2, 2.0};\n\
\n\
    // Map time to zoom value in [kAnimationScaleLow, 1]\n\
    float zoom = kAnimationScaleLow + kAnimationScale * cos(kAnimationFrequency * *frame);\n\
    // Speed up zooming\n\
    zoom = pow(zoom, kAnimationSpeed);\n\
\n\
    //Scale\n\
    float x0 = zoom * kMandelbrotScale.x * ((float)index.x / gridSize.x + kMandelbrotPixelOffset.x) + kMandelbrotOrigin.x;\n\
    float y0 = zoom * kMandelbrotScale.y * ((float)index.y / gridSize.y + kMandelbrotPixelOffset.y) + kMandelbrotOrigin.y;\n\
\n\
    // Implement Mandelbrot set\n\
    float x = 0.0;\n\
    float y = 0.0;\n\
    uint iteration = 0;\n\
    uint max_iteration = 1000;\n\
    float xtmp = 0.0;\n\
    while(x * x + y * y <= 4 && iteration < max_iteration)\n\
    {\n\
        xtmp = x * x - y * y + x0;\n\
        y = 2 * x * y + y0;\n\
        x = xtmp;\n\
        iteration += 1;\n\
    }\n\
\n\
    // Convert iteration result to colors\n\
    half color = (0.5 + 0.5 * cos(3.0 + iteration * 0.15));\n\
    tex.write(half4(color, color, color, 1.0), index, 0);\n\
}";

// Rendering shader source for compute-textured cubes (same as textured cubes)
NSString *computeRenderShaderSource = @"\
#include <metal_stdlib>\n\
using namespace metal;\n\
\n\
struct v2f\n\
{\n\
    float4 position [[position]];\n\
    float3 normal;\n\
    half3 color;\n\
    float2 texcoord;\n\
};\n\
\n\
struct VertexData\n\
{\n\
    float position[3];\n\
    float normal[3];\n\
    float texcoord[2];\n\
};\n\
\n\
struct InstanceData\n\
{\n\
    float4x4 instanceTransform;\n\
    float3x3 instanceNormalTransform;\n\
    float4 instanceColor;\n\
};\n\
\n\
struct CameraData\n\
{\n\
    float4x4 perspectiveTransform;\n\
    float4x4 worldTransform;\n\
    float3x3 worldNormalTransform;\n\
};\n\
\n\
v2f vertex vertexMain( device const VertexData* vertexData [[buffer(0)]],\n\
                       device const InstanceData* instanceData [[buffer(1)]],\n\
                       device const CameraData& cameraData [[buffer(2)]],\n\
                       uint vertexId [[vertex_id]],\n\
                       uint instanceId [[instance_id]] )\n\
{\n\
    v2f o;\n\
\n\
    const device VertexData& vd = vertexData[ vertexId ];\n\
    float4 pos = float4( vd.position[0], vd.position[1], vd.position[2], 1.0 );\n\
    pos = instanceData[ instanceId ].instanceTransform * pos;\n\
    pos = cameraData.perspectiveTransform * cameraData.worldTransform * pos;\n\
    o.position = pos;\n\
\n\
    float3 normal = float3( vd.normal[0], vd.normal[1], vd.normal[2] );\n\
    normal = instanceData[ instanceId ].instanceNormalTransform * normal;\n\
    normal = cameraData.worldNormalTransform * normal;\n\
    o.normal = normal;\n\
\n\
    o.texcoord = float2( vd.texcoord[0], vd.texcoord[1] );\n\
    o.color = half3( instanceData[ instanceId ].instanceColor.rgb );\n\
    return o;\n\
}\n\
\n\
half4 fragment fragmentMain( v2f in [[stage_in]], texture2d< half, access::sample > tex [[texture(0)]] )\n\
{\n\
    constexpr sampler s( address::repeat, filter::linear );\n\
    half3 texel = tex.sample( s, in.texcoord ).rgb;\n\
\n\
    // assume light coming from (front-top-right)\n\
    float3 l = normalize(float3( 1.0, 1.0, 0.8 ));\n\
    float3 n = normalize( in.normal );\n\
\n\
    half ndotl = half( saturate( dot( n, l ) ) );\n\
\n\
    half3 illum = (in.color * texel * 0.1) + (in.color * texel * ndotl);\n\
    return half4( illum, 1.0 );\n\
}";

// Use external math functions defined in metal_perspective.m
extern simd_float4x4 makeIdentity(void);
extern simd_float4x4 makePerspective(float fovRadians, float aspect, float znear, float zfar);
extern simd_float4x4 makeTranslate(simd_float3 v);
extern simd_float4x4 makeScale(simd_float3 v);
extern simd_float4x4 makeXRotate(float angleRadians);
extern simd_float4x4 makeYRotate(float angleRadians);
extern simd_float4x4 makeZRotate(float angleRadians);
extern simd_float3x3 discardTranslation(simd_float4x4 m);
extern simd_float3 addFloat3(simd_float3 a, simd_float3 b);

bool metal_setup_compute_pipeline(void) {
    if (!ctx || !ctx->device) {
        return false;
    }

    id<MTLDevice> device = (__bridge id<MTLDevice>)ctx->device;
    NSError *error = nil;

    // Create compute shader library
    id<MTLLibrary> computeLibrary = [device newLibraryWithSource:computeShaderSource options:nil error:&error];
    if (!computeLibrary) {
        return false;
    }

    id<MTLFunction> mandelbrotFunction = [computeLibrary newFunctionWithName:@"mandelbrot_set"];
    if (!mandelbrotFunction) {
        return false;
    }

    // Create compute pipeline state
    id<MTLComputePipelineState> computePipelineState = [device newComputePipelineStateWithFunction:mandelbrotFunction error:&error];
    if (!computePipelineState) {
        return false;
    }

    ctx->computePipelineState = (__bridge_retained void*)computePipelineState;

    // Create render shader library for displaying compute-generated texture
    id<MTLLibrary> renderLibrary = [device newLibraryWithSource:computeRenderShaderSource options:nil error:&error];
    if (!renderLibrary) {
        return false;
    }

    id<MTLFunction> vertexFunction = [renderLibrary newFunctionWithName:@"vertexMain"];
    id<MTLFunction> fragmentFunction = [renderLibrary newFunctionWithName:@"fragmentMain"];

    // Create render pipeline descriptor
    MTLRenderPipelineDescriptor *descriptor = [[MTLRenderPipelineDescriptor alloc] init];
    descriptor.vertexFunction = vertexFunction;
    descriptor.fragmentFunction = fragmentFunction;
    descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
    descriptor.depthAttachmentPixelFormat = MTLPixelFormatDepth16Unorm;

    // Create render pipeline state
    id<MTLRenderPipelineState> renderPipelineState = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (!renderPipelineState) {
        return false;
    }

    ctx->computeRenderPipelineState = (__bridge_retained void*)renderPipelineState;

    // Create depth stencil state
    MTLDepthStencilDescriptor *depthDescriptor = [[MTLDepthStencilDescriptor alloc] init];
    depthDescriptor.depthCompareFunction = MTLCompareFunctionLess;
    depthDescriptor.depthWriteEnabled = YES;

    id<MTLDepthStencilState> depthStencilState = [device newDepthStencilStateWithDescriptor:depthDescriptor];
    ctx->computeDepthStencilState = (__bridge_retained void*)depthStencilState;

    return true;
}

bool metal_generate_mandelbrot_texture_impl(void) {
    if (!ctx || !ctx->device || !ctx->computePipelineState) {
        return false;
    }

    id<MTLDevice> device = (__bridge id<MTLDevice>)ctx->device;
    id<MTLCommandQueue> commandQueue = (__bridge id<MTLCommandQueue>)ctx->commandQueue;

    // Create Mandelbrot texture if not already created
    if (!ctx->mandelbrotTexture) {
        const uint32_t textureWidth = 128;
        const uint32_t textureHeight = 128;

        MTLTextureDescriptor *textureDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                                      width:textureWidth
                                                                                                     height:textureHeight
                                                                                                  mipmapped:NO];
        textureDescriptor.storageMode = MTLStorageModeManaged;
        textureDescriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;

        id<MTLTexture> texture = [device newTextureWithDescriptor:textureDescriptor];
        if (!texture) {
            return false;
        }

        ctx->mandelbrotTexture = (__bridge_retained void*)texture;
    }

    // Update animation buffer with current frame counter
    if (ctx->textureAnimationBuffer) {
        uint *animPtr = (uint*)[(__bridge id<MTLBuffer>)ctx->textureAnimationBuffer contents];
        *animPtr = (ctx->animationIndex++) % 5000;  // Match the C++ reference modulo 5000
        [(__bridge id<MTLBuffer>)ctx->textureAnimationBuffer didModifyRange:NSMakeRange(0, sizeof(uint))];
    }

    // Generate Mandelbrot texture using compute shader
    id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];
    id<MTLComputeCommandEncoder> computeEncoder = [commandBuffer computeCommandEncoder];

    [computeEncoder setComputePipelineState:(__bridge id<MTLComputePipelineState>)ctx->computePipelineState];
    [computeEncoder setTexture:(__bridge id<MTLTexture>)ctx->mandelbrotTexture atIndex:0];
    [computeEncoder setBuffer:(__bridge id<MTLBuffer>)ctx->textureAnimationBuffer offset:0 atIndex:0];

    // Dispatch compute shader
    MTLSize gridSize = MTLSizeMake(128, 128, 1);
    NSUInteger threadGroupSize = [(__bridge id<MTLComputePipelineState>)ctx->computePipelineState maxTotalThreadsPerThreadgroup];
    MTLSize threadgroupSize = MTLSizeMake(threadGroupSize, 1, 1);

    [computeEncoder dispatchThreads:gridSize threadsPerThreadgroup:threadgroupSize];
    [computeEncoder endEncoding];

    [commandBuffer commit];
    [commandBuffer waitUntilCompleted];

    return true;
}

bool metal_create_compute_cubes_impl(void) {
    if (!ctx || !ctx->device) {
        return false;
    }

    id<MTLDevice> device = (__bridge id<MTLDevice>)ctx->device;

    // Setup the compute pipeline
    if (!metal_setup_compute_pipeline()) {
        return false;
    }

    // Create animation buffer for compute shader
    ctx->textureAnimationBuffer = (__bridge_retained void*)[device newBufferWithLength:sizeof(uint) options:MTLResourceStorageModeManaged];
    if (!ctx->textureAnimationBuffer) {
        return false;
    }

    // Initialize animation index
    ctx->animationIndex = 0;

    // Generate the Mandelbrot texture
    if (!metal_generate_mandelbrot_texture_impl()) {
        return false;
    }

    // Create cube vertices with texture coordinates (same as textured cubes)
    const float s = 0.5f;
    struct metal_textured_vertex vertices[] = {
        // Front face
        {{-s, -s, +s}, {0.0f, 0.0f, 1.0f}, {0.0f, 1.0f}},
        {{+s, -s, +s}, {0.0f, 0.0f, 1.0f}, {1.0f, 1.0f}},
        {{+s, +s, +s}, {0.0f, 0.0f, 1.0f}, {1.0f, 0.0f}},
        {{-s, +s, +s}, {0.0f, 0.0f, 1.0f}, {0.0f, 0.0f}},

        // Right face
        {{+s, -s, +s}, {1.0f, 0.0f, 0.0f}, {0.0f, 1.0f}},
        {{+s, -s, -s}, {1.0f, 0.0f, 0.0f}, {1.0f, 1.0f}},
        {{+s, +s, -s}, {1.0f, 0.0f, 0.0f}, {1.0f, 0.0f}},
        {{+s, +s, +s}, {1.0f, 0.0f, 0.0f}, {0.0f, 0.0f}},

        // Back face
        {{+s, -s, -s}, {0.0f, 0.0f, -1.0f}, {0.0f, 1.0f}},
        {{-s, -s, -s}, {0.0f, 0.0f, -1.0f}, {1.0f, 1.0f}},
        {{-s, +s, -s}, {0.0f, 0.0f, -1.0f}, {1.0f, 0.0f}},
        {{+s, +s, -s}, {0.0f, 0.0f, -1.0f}, {0.0f, 0.0f}},

        // Left face
        {{-s, -s, -s}, {-1.0f, 0.0f, 0.0f}, {0.0f, 1.0f}},
        {{-s, -s, +s}, {-1.0f, 0.0f, 0.0f}, {1.0f, 1.0f}},
        {{-s, +s, +s}, {-1.0f, 0.0f, 0.0f}, {1.0f, 0.0f}},
        {{-s, +s, -s}, {-1.0f, 0.0f, 0.0f}, {0.0f, 0.0f}},

        // Top face
        {{-s, +s, +s}, {0.0f, 1.0f, 0.0f}, {0.0f, 1.0f}},
        {{+s, +s, +s}, {0.0f, 1.0f, 0.0f}, {1.0f, 1.0f}},
        {{+s, +s, -s}, {0.0f, 1.0f, 0.0f}, {1.0f, 0.0f}},
        {{-s, +s, -s}, {0.0f, 1.0f, 0.0f}, {0.0f, 0.0f}},

        // Bottom face
        {{-s, -s, -s}, {0.0f, -1.0f, 0.0f}, {0.0f, 1.0f}},
        {{+s, -s, -s}, {0.0f, -1.0f, 0.0f}, {1.0f, 1.0f}},
        {{+s, -s, +s}, {0.0f, -1.0f, 0.0f}, {1.0f, 0.0f}},
        {{-s, -s, +s}, {0.0f, -1.0f, 0.0f}, {0.0f, 0.0f}}
    };

    // Create indices for the cube
    uint16_t indices[] = {
        0,  1,  2,   2,  3,  0,  // front
        4,  5,  6,   6,  7,  4,  // right
        8,  9, 10,  10, 11,  8,  // back
       12, 13, 14,  14, 15, 12,  // left
       16, 17, 18,  18, 19, 16,  // top
       20, 21, 22,  22, 23, 20,  // bottom
    };

    // Create vertex buffer
    NSUInteger vertexDataSize = sizeof(vertices);
    id<MTLBuffer> vertexBuffer = [device newBufferWithBytes:vertices length:vertexDataSize options:MTLResourceStorageModeManaged];
    if (!vertexBuffer) {
        return false;
    }
    ctx->computeVertexBuffer = (__bridge_retained void*)vertexBuffer;
    ctx->computeVertexCount = sizeof(vertices) / sizeof(vertices[0]);

    // Create index buffer
    NSUInteger indexDataSize = sizeof(indices);
    id<MTLBuffer> indexBuffer = [device newBufferWithBytes:indices length:indexDataSize options:MTLResourceStorageModeManaged];
    if (!indexBuffer) {
        return false;
    }
    ctx->computeIndexBuffer = (__bridge_retained void*)indexBuffer;
    ctx->computeIndexCount = sizeof(indices) / sizeof(indices[0]);

    // Mark buffers as modified
    [vertexBuffer didModifyRange:NSMakeRange(0, vertexDataSize)];
    [indexBuffer didModifyRange:NSMakeRange(0, indexDataSize)];

    // Create instance data buffers for multiple frames - 10x10x10 grid like reference
    const size_t kNumInstances = 1000;
    NSUInteger instanceDataSize = kNumInstances * sizeof(struct metal_lighting_instance_data);
    for (int i = 0; i < MAX_FRAMES_IN_FLIGHT; i++) {
        id<MTLBuffer> instanceBuffer = [device newBufferWithLength:instanceDataSize options:MTLResourceStorageModeManaged];
        if (!instanceBuffer) {
            return false;
        }
        ctx->computeInstanceDataBuffers[i] = (__bridge_retained void*)instanceBuffer;
    }

    // Create camera data buffers for multiple frames
    NSUInteger cameraDataSize = sizeof(struct metal_lighting_camera_data);
    for (int i = 0; i < MAX_FRAMES_IN_FLIGHT; i++) {
        id<MTLBuffer> cameraBuffer = [device newBufferWithLength:cameraDataSize options:MTLResourceStorageModeManaged];
        if (!cameraBuffer) {
            return false;
        }
        ctx->computeCameraDataBuffers[i] = (__bridge_retained void*)cameraBuffer;
    }

    return true;
}

bool metal_render_compute_cubes_impl(int r, int g, int b, int a) {
    if (!ctx || !ctx->device || !ctx->computeRenderPipelineState) {
        return false;
    }

    id<MTLDevice> device = (__bridge id<MTLDevice>)ctx->device;
    id<MTLCommandQueue> commandQueue = (__bridge id<MTLCommandQueue>)ctx->commandQueue;
    CAMetalLayer *layer = (__bridge CAMetalLayer*)ctx->layer;

    // Get next drawable
    id<CAMetalDrawable> drawable = [layer nextDrawable];
    if (!drawable) {
        return false;
    }

    // Update frame index
    ctx->frameIndex = (ctx->frameIndex + 1) % MAX_FRAMES_IN_FLIGHT;

    // Update animation
    ctx->angle += 0.002f;

    // Create command buffer for both compute and render passes
    id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];

    // Update animation buffer and generate Mandelbrot texture each frame
    if (ctx->textureAnimationBuffer) {
        uint *animPtr = (uint*)[(__bridge id<MTLBuffer>)ctx->textureAnimationBuffer contents];
        *animPtr = (ctx->animationIndex++) % 5000;
        [(__bridge id<MTLBuffer>)ctx->textureAnimationBuffer didModifyRange:NSMakeRange(0, sizeof(uint))];

        // Generate animated Mandelbrot texture using compute shader
        id<MTLComputeCommandEncoder> computeEncoder = [commandBuffer computeCommandEncoder];
        [computeEncoder setComputePipelineState:(__bridge id<MTLComputePipelineState>)ctx->computePipelineState];
        [computeEncoder setTexture:(__bridge id<MTLTexture>)ctx->mandelbrotTexture atIndex:0];
        [computeEncoder setBuffer:(__bridge id<MTLBuffer>)ctx->textureAnimationBuffer offset:0 atIndex:0];

        MTLSize gridSize = MTLSizeMake(128, 128, 1);
        NSUInteger threadGroupSize = [(__bridge id<MTLComputePipelineState>)ctx->computePipelineState maxTotalThreadsPerThreadgroup];
        MTLSize threadgroupSize = MTLSizeMake(threadGroupSize, 1, 1);

        [computeEncoder dispatchThreads:gridSize threadsPerThreadgroup:threadgroupSize];
        [computeEncoder endEncoding];
    }

    // Update instance data (same as textured cubes)
    id<MTLBuffer> instanceBuffer = (__bridge id<MTLBuffer>)ctx->computeInstanceDataBuffers[ctx->frameIndex];
    struct metal_lighting_instance_data *instanceData = (struct metal_lighting_instance_data *)[instanceBuffer contents];

    simd_float3 objectPosition = simd_make_float3(0.0f, 0.0f, -10.0f);
    const float scl = 0.2f;

    simd_float4x4 rt = makeTranslate(objectPosition);
    simd_float4x4 rr1 = makeYRotate(-ctx->angle);
    simd_float4x4 rr0 = makeXRotate(ctx->angle * 0.5f);
    simd_float4x4 rtInv = makeTranslate(simd_make_float3(-objectPosition.x, -objectPosition.y, -objectPosition.z));
    simd_float4x4 fullObjectRot = simd_mul(simd_mul(simd_mul(rt, rr1), rr0), rtInv);

    // Create 10x10x10 grid of cubes
    const int kInstanceRows = 10;
    const int kInstanceColumns = 10;
    const int kInstanceDepth = 10;
    const int kNumInstances = kInstanceRows * kInstanceColumns * kInstanceDepth;

    size_t ix = 0, iy = 0, iz = 0;
    for (size_t i = 0; i < kNumInstances; ++i) {
        if (ix == kInstanceRows) {
            ix = 0;
            iy += 1;
        }
        if (iy == kInstanceRows) {
            iy = 0;
            iz += 1;
        }

        simd_float4x4 scale = makeScale(simd_make_float3(scl, scl, scl));
        simd_float4x4 zrot = makeZRotate(ctx->angle * sinf((float)ix));
        simd_float4x4 yrot = makeYRotate(ctx->angle * cosf((float)iy));

        float x = ((float)ix - (float)kInstanceRows/2.0f) * (2.0f * scl) + scl;
        float y = ((float)iy - (float)kInstanceColumns/2.0f) * (2.0f * scl) + scl;
        float z = ((float)iz - (float)kInstanceDepth/2.0f) * (2.0f * scl);
        simd_float4x4 translate = makeTranslate(addFloat3(objectPosition, simd_make_float3(x, y, z)));

        instanceData[i].instanceTransform = simd_mul(simd_mul(simd_mul(simd_mul(fullObjectRot, translate), yrot), zrot), scale);
        instanceData[i].instanceNormalTransform = discardTranslation(instanceData[i].instanceTransform);

        float iDivNumInstances = (float)i / (float)kNumInstances;
        float red = iDivNumInstances;
        float green = 1.0f - red;
        float blue = sinf(M_PI * 2.0f * iDivNumInstances);
        instanceData[i].instanceColor = simd_make_float4(red, green, blue, 1.0f);

        ix += 1;
    }

    // Mark instance buffer as modified
    [instanceBuffer didModifyRange:NSMakeRange(0, instanceBuffer.length)];

    // Update camera data
    id<MTLBuffer> cameraBuffer = (__bridge id<MTLBuffer>)ctx->computeCameraDataBuffers[ctx->frameIndex];
    struct metal_lighting_camera_data *cameraData = (struct metal_lighting_camera_data *)[cameraBuffer contents];
    cameraData->perspectiveTransform = makePerspective(45.0f * M_PI / 180.0f, 1.0f, 0.03f, 500.0f);
    cameraData->worldTransform = makeIdentity();
    cameraData->worldNormalTransform = discardTranslation(cameraData->worldTransform);

    // Mark camera buffer as modified
    [cameraBuffer didModifyRange:NSMakeRange(0, sizeof(struct metal_lighting_camera_data))];

    // Begin render pass
    MTLRenderPassDescriptor *renderPassDescriptor = [MTLRenderPassDescriptor renderPassDescriptor];
    renderPassDescriptor.colorAttachments[0].texture = drawable.texture;
    renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
    renderPassDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
    renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(r/255.0, g/255.0, b/255.0, a/255.0);

    // Setup depth texture
    if (!ctx->depthTexture) {
        MTLTextureDescriptor *depthTextureDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth16Unorm width:drawable.texture.width height:drawable.texture.height mipmapped:NO];
        depthTextureDesc.usage = MTLTextureUsageRenderTarget;
        ctx->depthTexture = (__bridge_retained void*)[device newTextureWithDescriptor:depthTextureDesc];
    }

    renderPassDescriptor.depthAttachment.texture = (__bridge id<MTLTexture>)ctx->depthTexture;
    renderPassDescriptor.depthAttachment.loadAction = MTLLoadActionClear;
    renderPassDescriptor.depthAttachment.storeAction = MTLStoreActionDontCare;
    renderPassDescriptor.depthAttachment.clearDepth = 1.0;

    // Create render command encoder
    id<MTLRenderCommandEncoder> renderEncoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];

    [renderEncoder setRenderPipelineState:(__bridge id<MTLRenderPipelineState>)ctx->computeRenderPipelineState];
    [renderEncoder setDepthStencilState:(__bridge id<MTLDepthStencilState>)ctx->computeDepthStencilState];

    [renderEncoder setVertexBuffer:(__bridge id<MTLBuffer>)ctx->computeVertexBuffer offset:0 atIndex:0];
    [renderEncoder setVertexBuffer:instanceBuffer offset:0 atIndex:1];
    [renderEncoder setVertexBuffer:cameraBuffer offset:0 atIndex:2];

    [renderEncoder setFragmentTexture:(__bridge id<MTLTexture>)ctx->mandelbrotTexture atIndex:0];

    [renderEncoder setCullMode:MTLCullModeBack];
    [renderEncoder setFrontFacingWinding:MTLWindingCounterClockwise];

    [renderEncoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                              indexCount:ctx->computeIndexCount
                               indexType:MTLIndexTypeUInt16
                             indexBuffer:(__bridge id<MTLBuffer>)ctx->computeIndexBuffer
                       indexBufferOffset:0
                           instanceCount:kNumInstances];

    [renderEncoder endEncoding];
    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];

    return true;
}

// HashLink exports for compute shader cube rendering
HL_PRIM bool HL_NAME(create_compute_cubes)(void) {
    return metal_create_compute_cubes_impl();
}

HL_PRIM bool HL_NAME(render_compute_cubes)(int r, int g, int b, int a) {
    return metal_render_compute_cubes_impl(r, g, b, a);
}

HL_PRIM bool HL_NAME(generate_mandelbrot_texture)(void) {
    return metal_generate_mandelbrot_texture_impl();
}

DEFINE_PRIM(_BOOL, create_compute_cubes, _NO_ARG);
DEFINE_PRIM(_BOOL, render_compute_cubes, _I32 _I32 _I32 _I32);
DEFINE_PRIM(_BOOL, generate_mandelbrot_texture, _NO_ARG);
