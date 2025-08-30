#include "metal.h"

// Texture rendering shader source
NSString *texturingShaderSource = @"\
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
    float3 position;\n\
    float3 normal;\n\
    float2 texcoord;\n\
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
    float4 pos = float4( vd.position, 1.0 );\n\
    pos = instanceData[ instanceId ].instanceTransform * pos;\n\
    pos = cameraData.perspectiveTransform * cameraData.worldTransform * pos;\n\
    o.position = pos;\n\
\n\
    float3 normal = instanceData[ instanceId ].instanceNormalTransform * vd.normal;\n\
    normal = cameraData.worldNormalTransform * normal;\n\
    o.normal = normal;\n\
\n\
    o.texcoord = vd.texcoord.xy;\n\
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

bool metal_setup_textured_pipeline(void) {
    if (!ctx || !ctx->device) {
        return false;
    }

    id<MTLDevice> device = (__bridge id<MTLDevice>)ctx->device;
    NSError *error = nil;

    // Create shader library
    id<MTLLibrary> library = [device newLibraryWithSource:texturingShaderSource options:nil error:&error];
    if (!library) {
        return false;
    }

    id<MTLFunction> vertexFunction = [library newFunctionWithName:@"vertexMain"];
    id<MTLFunction> fragmentFunction = [library newFunctionWithName:@"fragmentMain"];

    // Create render pipeline descriptor
    MTLRenderPipelineDescriptor *descriptor = [[MTLRenderPipelineDescriptor alloc] init];
    descriptor.vertexFunction = vertexFunction;
    descriptor.fragmentFunction = fragmentFunction;
    descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
    descriptor.depthAttachmentPixelFormat = MTLPixelFormatDepth16Unorm;

    // Create pipeline state
    id<MTLRenderPipelineState> pipelineState = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
    if (!pipelineState) {
        return false;
    }

    ctx->texturedPipelineState = (__bridge_retained void*)pipelineState;

    // Create depth stencil state
    MTLDepthStencilDescriptor *depthDescriptor = [[MTLDepthStencilDescriptor alloc] init];
    depthDescriptor.depthCompareFunction = MTLCompareFunctionLess;
    depthDescriptor.depthWriteEnabled = YES;

    id<MTLDepthStencilState> depthStencilState = [device newDepthStencilStateWithDescriptor:depthDescriptor];
    ctx->texturedDepthStencilState = (__bridge_retained void*)depthStencilState;

    return true;
}

bool metal_create_textured_cubes_impl(void) {
    if (!ctx || !ctx->device) {
        return false;
    }

    id<MTLDevice> device = (__bridge id<MTLDevice>)ctx->device;

    // Setup the textured pipeline
    if (!metal_setup_textured_pipeline()) {
        return false;
    }

    // Create cube vertices with texture coordinates (similar to 07-texturing.cpp)
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
    id<MTLBuffer> vertexBuffer = [device newBufferWithBytes:vertices length:vertexDataSize options:MTLResourceStorageModeShared];
    if (!vertexBuffer) {
        return false;
    }
    ctx->texturedVertexBuffer = (__bridge_retained void*)vertexBuffer;
    ctx->texturedVertexCount = sizeof(vertices) / sizeof(vertices[0]);

    // Create index buffer
    NSUInteger indexDataSize = sizeof(indices);
    id<MTLBuffer> indexBuffer = [device newBufferWithBytes:indices length:indexDataSize options:MTLResourceStorageModeShared];
    if (!indexBuffer) {
        return false;
    }
    ctx->texturedIndexBuffer = (__bridge_retained void*)indexBuffer;
    ctx->texturedIndexCount = sizeof(indices) / sizeof(indices[0]);

    // Create instance data buffers for multiple frames
    NSUInteger instanceDataSize = NUM_INSTANCES * sizeof(struct metal_lighting_instance_data);
    for (int i = 0; i < MAX_FRAMES_IN_FLIGHT; i++) {
        id<MTLBuffer> instanceBuffer = [device newBufferWithLength:instanceDataSize options:MTLResourceStorageModeShared];
        if (!instanceBuffer) {
            return false;
        }
        ctx->texturedInstanceDataBuffers[i] = (__bridge_retained void*)instanceBuffer;
    }

    // Create camera data buffers for multiple frames
    NSUInteger cameraDataSize = sizeof(struct metal_lighting_camera_data);
    for (int i = 0; i < MAX_FRAMES_IN_FLIGHT; i++) {
        id<MTLBuffer> cameraBuffer = [device newBufferWithLength:cameraDataSize options:MTLResourceStorageModeShared];
        if (!cameraBuffer) {
            return false;
        }
        ctx->texturedCameraDataBuffers[i] = (__bridge_retained void*)cameraBuffer;
    }

    // Create procedural checkerboard texture (128x128 like in the sample)
    const uint32_t textureWidth = 128;
    const uint32_t textureHeight = 128;

    MTLTextureDescriptor *textureDescriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                                  width:textureWidth
                                                                                                 height:textureHeight
                                                                                              mipmapped:NO];
    textureDescriptor.storageMode = MTLStorageModeShared;
    textureDescriptor.usage = MTLTextureUsageShaderRead;

    id<MTLTexture> texture = [device newTextureWithDescriptor:textureDescriptor];
    if (!texture) {
        return false;
    }

    // Generate checkerboard pattern data
    uint8_t *textureData = malloc(textureWidth * textureHeight * 4);
    for (size_t y = 0; y < textureHeight; ++y) {
        for (size_t x = 0; x < textureWidth; ++x) {
            bool isWhite = (x^y) & 0b1000000; // Same pattern as 07-texturing.cpp
            uint8_t c = isWhite ? 0xFF : 0x0A;

            size_t i = y * textureWidth + x;
            textureData[i * 4 + 0] = c;  // R
            textureData[i * 4 + 1] = c;  // G
            textureData[i * 4 + 2] = c;  // B
            textureData[i * 4 + 3] = 0xFF; // A
        }
    }

    // Upload texture data
    MTLRegion region = MTLRegionMake2D(0, 0, textureWidth, textureHeight);
    [texture replaceRegion:region mipmapLevel:0 withBytes:textureData bytesPerRow:textureWidth * 4];

    free(textureData);
    ctx->checkerboardTexture = (__bridge_retained void*)texture;

    return true;
}

bool metal_render_textured_cubes_impl(int r, int g, int b, int a) {
    if (!ctx || !ctx->device || !ctx->texturedPipelineState) {
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

    // Update instance data
    id<MTLBuffer> instanceBuffer = (__bridge id<MTLBuffer>)ctx->texturedInstanceDataBuffers[ctx->frameIndex];
    struct metal_lighting_instance_data *instanceData = (struct metal_lighting_instance_data *)[instanceBuffer contents];

    simd_float3 objectPosition = {0.0f, 0.0f, -10.0f};
    const float scl = 0.2f;

    simd_float4x4 rt = makeTranslate(objectPosition);
    simd_float4x4 rr1 = makeYRotate(-ctx->angle);
    simd_float4x4 rr0 = makeXRotate(ctx->angle * 0.5f);
    simd_float4x4 rtInv = makeTranslate((simd_float3){-objectPosition.x, -objectPosition.y, -objectPosition.z});
    simd_float4x4 fullObjectRot = simd_mul(simd_mul(simd_mul(rt, rr1), rr0), rtInv);

    // Create 10x10x10 grid of cubes
    const int kInstanceRows = 10;
    const int kInstanceColumns = 10;
    const int kInstanceDepth = 10;

    size_t ix = 0, iy = 0, iz = 0;
    for (size_t i = 0; i < NUM_INSTANCES && i < (kInstanceRows * kInstanceColumns * kInstanceDepth); ++i) {
        if (ix == kInstanceRows) {
            ix = 0;
            iy += 1;
        }
        if (iy == kInstanceRows) {
            iy = 0;
            iz += 1;
        }

        simd_float4x4 scale = makeScale((simd_float3){scl, scl, scl});
        simd_float4x4 zrot = makeZRotate(ctx->angle * sinf((float)ix));
        simd_float4x4 yrot = makeYRotate(ctx->angle * cosf((float)iy));

        float x = ((float)ix - (float)kInstanceRows/2.0f) * (2.0f * scl) + scl;
        float y = ((float)iy - (float)kInstanceColumns/2.0f) * (2.0f * scl) + scl;
        float z = ((float)iz - (float)kInstanceDepth/2.0f) * (2.0f * scl);
        simd_float4x4 translate = makeTranslate(addFloat3(objectPosition, (simd_float3){x, y, z}));

        instanceData[i].instanceTransform = simd_mul(simd_mul(simd_mul(simd_mul(fullObjectRot, translate), yrot), zrot), scale);
        instanceData[i].instanceNormalTransform = discardTranslation(instanceData[i].instanceTransform);

        float iDivNumInstances = (float)i / (float)NUM_INSTANCES;
        float red = iDivNumInstances;
        float green = 1.0f - red;
        float blue = sinf(M_PI * 2.0f * iDivNumInstances);
        instanceData[i].instanceColor = (simd_float4){red, green, blue, 1.0f};

        ix += 1;
    }

    // Update camera data
    id<MTLBuffer> cameraBuffer = (__bridge id<MTLBuffer>)ctx->texturedCameraDataBuffers[ctx->frameIndex];
    struct metal_lighting_camera_data *cameraData = (struct metal_lighting_camera_data *)[cameraBuffer contents];
    cameraData->perspectiveTransform = makePerspective(45.0f * M_PI / 180.0f, 1.0f, 0.03f, 500.0f);
    cameraData->worldTransform = makeIdentity();
    cameraData->worldNormalTransform = discardTranslation(cameraData->worldTransform);

    // Create command buffer
    id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];

    // Create render pass descriptor
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

    [renderEncoder setRenderPipelineState:(__bridge id<MTLRenderPipelineState>)ctx->texturedPipelineState];
    [renderEncoder setDepthStencilState:(__bridge id<MTLDepthStencilState>)ctx->texturedDepthStencilState];

    [renderEncoder setVertexBuffer:(__bridge id<MTLBuffer>)ctx->texturedVertexBuffer offset:0 atIndex:0];
    [renderEncoder setVertexBuffer:instanceBuffer offset:0 atIndex:1];
    [renderEncoder setVertexBuffer:cameraBuffer offset:0 atIndex:2];

    [renderEncoder setFragmentTexture:(__bridge id<MTLTexture>)ctx->checkerboardTexture atIndex:0];

    [renderEncoder setCullMode:MTLCullModeBack];
    [renderEncoder setFrontFacingWinding:MTLWindingCounterClockwise];

    [renderEncoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                              indexCount:ctx->texturedIndexCount
                               indexType:MTLIndexTypeUInt16
                             indexBuffer:(__bridge id<MTLBuffer>)ctx->texturedIndexBuffer
                       indexBufferOffset:0
                           instanceCount:NUM_INSTANCES];

    [renderEncoder endEncoding];
    [commandBuffer presentDrawable:drawable];
    [commandBuffer commit];

    return true;
}

// HashLink exports for textured cube rendering
HL_PRIM bool HL_NAME(create_textured_cubes)(void) {
    return metal_create_textured_cubes_impl();
}

HL_PRIM bool HL_NAME(render_textured_cubes)(int r, int g, int b, int a) {
    return metal_render_textured_cubes_impl(r, g, b, a);
}

DEFINE_PRIM(_BOOL, create_textured_cubes, _NO_ARG);
DEFINE_PRIM(_BOOL, render_textured_cubes, _I32 _I32 _I32 _I32);
