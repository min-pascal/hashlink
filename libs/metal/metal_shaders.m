#include "metal.h"

// Metal shader source code with animation support
NSString *shaderSource = @"\
#include <metal_stdlib>\n\
using namespace metal;\n\
\n\
// Define the data structure for the argument buffer\n\
struct VertexData {\n\
    device float3* positions [[id(0)]];\n\
    device float3* colors [[id(1)]];\n\
};\n\
\n\
// Frame data for animation\n\
struct FrameData {\n\
    float angle;\n\
};\n\
\n\
// Define the output of the vertex shader, which is the input to the fragment shader\n\
struct RasterizerData {\n\
    float4 position [[position]];\n\
    float3 color;\n\
};\n\
\n\
// Vertex shader function using argument buffer with animation\n\
vertex RasterizerData vertexShader(uint vertexID [[vertex_id]],\n\
                                  device const VertexData* vertexData [[buffer(0)]],\n\
                                  constant FrameData* frameData [[buffer(1)]]) {\n\
    RasterizerData out;\n\
\n\
    // Create rotation matrix for clockwise rotation\n\
    float a = frameData->angle;\n\
    float3x3 rotationMatrix = float3x3(\n\
        sin(a), cos(a), 0.0,\n\
        cos(a), -sin(a), 0.0,\n\
        0.0, 0.0, 1.0\n\
    );\n\
\n\
    // Apply rotation to the vertex position\n\
    float3 rotatedPosition = rotationMatrix * vertexData->positions[vertexID];\n\
    out.position = float4(rotatedPosition, 1.0);\n\
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

// Instancing shader source
NSString *instancingShaderSource = @"\
#include <metal_stdlib>\n\
using namespace metal;\n\
\n\
struct VertexData {\n\
    float3 position;\n\
};\n\
\n\
struct InstanceData {\n\
    float4x4 instanceTransform;\n\
    float4 instanceColor;\n\
};\n\
\n\
struct RasterizerData {\n\
    float4 position [[position]];\n\
    half3 color;\n\
};\n\
\n\
vertex RasterizerData instancingVertexShader(device const VertexData* vertexData [[buffer(0)]],\n\
                                            device const InstanceData* instanceData [[buffer(1)]],\n\
                                            uint vertexId [[vertex_id]],\n\
                                            uint instanceId [[instance_id]]) {\n\
    RasterizerData out;\n\
    float4 pos = float4(vertexData[vertexId].position, 1.0);\n\
    out.position = instanceData[instanceId].instanceTransform * pos;\n\
    out.color = half3(instanceData[instanceId].instanceColor.rgb);\n\
    return out;\n\
}\n\
\n\
fragment half4 instancingFragmentShader(RasterizerData in [[stage_in]]) {\n\
    return half4(in.color, 1.0);\n\
}\n\
";

// Perspective shader source
NSString *perspectiveShaderSource = @"\
#include <metal_stdlib>\n\
using namespace metal;\n\
\n\
struct VertexData {\n\
    float3 position;\n\
};\n\
\n\
struct InstanceData {\n\
    float4x4 instanceTransform;\n\
    float4 instanceColor;\n\
};\n\
\n\
struct CameraData {\n\
    float4x4 perspectiveTransform;\n\
    float4x4 worldTransform;\n\
};\n\
\n\
struct RasterizerData {\n\
    float4 position [[position]];\n\
    half3 color;\n\
};\n\
\n\
vertex RasterizerData perspectiveVertexShader(device const VertexData* vertexData [[buffer(0)]],\n\
                                            device const InstanceData* instanceData [[buffer(1)]],\n\
                                            device const CameraData& cameraData [[buffer(2)]],\n\
                                            uint vertexId [[vertex_id]],\n\
                                            uint instanceId [[instance_id]]) {\n\
    RasterizerData out;\n\
    float4 pos = float4(vertexData[vertexId].position, 1.0);\n\
    pos = instanceData[instanceId].instanceTransform * pos;\n\
    pos = cameraData.perspectiveTransform * cameraData.worldTransform * pos;\n\
    out.position = pos;\n\
    out.color = half3(instanceData[instanceId].instanceColor.rgb);\n\
    return out;\n\
}\n\
\n\
fragment half4 perspectiveFragmentShader(RasterizerData in [[stage_in]]) {\n\
    return half4(in.color, 1.0);\n\
}\n\
";

bool metal_setup_pipeline(void) {
    if (ctx == NULL || !ctx->windowSetup) return false;

    metal_debug_log("Setting up Metal render pipeline for animated triangles");

    @autoreleasepool {
        id<MTLDevice> device = (__bridge id<MTLDevice>)ctx->device;
        CAMetalLayer* layer = (__bridge CAMetalLayer*)ctx->layer;

        // Create a library from the shader source
        NSError *error = nil;
        id<MTLLibrary> library = [device newLibraryWithSource:shaderSource
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
        pipelineDescriptor.colorAttachments[0].pixelFormat = layer.pixelFormat;
        pipelineDescriptor.colorAttachments[0].blendingEnabled = YES;
        pipelineDescriptor.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
        pipelineDescriptor.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
        pipelineDescriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
        pipelineDescriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
        pipelineDescriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        pipelineDescriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;

        // Create the pipeline state
        error = nil;
        id<MTLRenderPipelineState> pipelineState = [device newRenderPipelineStateWithDescriptor:pipelineDescriptor
                                                                                           error:&error];
        if (!pipelineState) {
            metal_debug_log("Failed to create render pipeline state: %s",
                           error ? [[error localizedDescription] UTF8String] : "Unknown error");
            return false;
        }
        
        ctx->pipelineState = (__bridge_retained void*)pipelineState;
        metal_debug_log("Render pipeline created successfully");
    }

    return true;
}

bool metal_setup_instancing_pipeline(void) {
    if (ctx == NULL || !ctx->windowSetup) return false;

    metal_debug_log("Setting up Metal instancing pipeline");

    @autoreleasepool {
        id<MTLDevice> device = (__bridge id<MTLDevice>)ctx->device;
        CAMetalLayer* layer = (__bridge CAMetalLayer*)ctx->layer;
        
        NSError *error = nil;
        id<MTLLibrary> library = [device newLibraryWithSource:instancingShaderSource
                                                      options:nil
                                                        error:&error];
        if (!library) {
            metal_debug_log("Failed to create instancing shader library: %s",
                           error ? [[error localizedDescription] UTF8String] : "Unknown error");
            return false;
        }

        id<MTLFunction> vertexFunction = [library newFunctionWithName:@"instancingVertexShader"];
        id<MTLFunction> fragmentFunction = [library newFunctionWithName:@"instancingFragmentShader"];

        if (!vertexFunction || !fragmentFunction) {
            metal_debug_log("Failed to get instancing shader functions");
            return false;
        }

        MTLRenderPipelineDescriptor *pipelineDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
        pipelineDescriptor.vertexFunction = vertexFunction;
        pipelineDescriptor.fragmentFunction = fragmentFunction;
        pipelineDescriptor.colorAttachments[0].pixelFormat = layer.pixelFormat;

        id<MTLRenderPipelineState> instancingPipelineState = [device newRenderPipelineStateWithDescriptor:pipelineDescriptor
                                                                                                     error:&error];
        if (!instancingPipelineState) {
            metal_debug_log("Failed to create instancing pipeline state: %s",
                           error ? [[error localizedDescription] UTF8String] : "Unknown error");
            return false;
        }
        
        ctx->instancingPipelineState = (__bridge_retained void*)instancingPipelineState;
        metal_debug_log("Instancing pipeline created successfully");
    }

    return true;
}

bool metal_setup_perspective_pipeline(void) {
    if (ctx == NULL || !ctx->windowSetup) return false;

    metal_debug_log("Setting up Metal perspective render pipeline");

    @autoreleasepool {
        id<MTLDevice> device = (__bridge id<MTLDevice>)ctx->device;
        CAMetalLayer* layer = (__bridge CAMetalLayer*)ctx->layer;

        NSError *error = nil;
        id<MTLLibrary> library = [device newLibraryWithSource:perspectiveShaderSource
                                                      options:nil
                                                        error:&error];
        if (!library) {
            metal_debug_log("Failed to create perspective shader library: %s",
                           error ? [[error localizedDescription] UTF8String] : "Unknown error");
            return false;
        }

        id<MTLFunction> vertexFunction = [library newFunctionWithName:@"perspectiveVertexShader"];
        id<MTLFunction> fragmentFunction = [library newFunctionWithName:@"perspectiveFragmentShader"];

        if (!vertexFunction || !fragmentFunction) {
            metal_debug_log("Failed to get perspective shader functions");
            return false;
        }

        MTLRenderPipelineDescriptor *pipelineDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
        pipelineDescriptor.vertexFunction = vertexFunction;
        pipelineDescriptor.fragmentFunction = fragmentFunction;
        pipelineDescriptor.colorAttachments[0].pixelFormat = layer.pixelFormat;
        pipelineDescriptor.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float; // Add depth format

        id<MTLRenderPipelineState> perspectivePipelineState = [device newRenderPipelineStateWithDescriptor:pipelineDescriptor
                                                                                                     error:&error];
        if (!perspectivePipelineState) {
            metal_debug_log("Failed to create perspective pipeline state: %s",
                           error ? [[error localizedDescription] UTF8String] : "Unknown error");
            return false;
        }

        ctx->perspectivePipelineState = (__bridge_retained void*)perspectivePipelineState;

        // Create depth stencil state for 3D rendering
        MTLDepthStencilDescriptor *depthStencilDescriptor = [[MTLDepthStencilDescriptor alloc] init];
        depthStencilDescriptor.depthCompareFunction = MTLCompareFunctionLess;
        depthStencilDescriptor.depthWriteEnabled = YES;

        id<MTLDepthStencilState> depthStencilState = [device newDepthStencilStateWithDescriptor:depthStencilDescriptor];
        if (!depthStencilState) {
            metal_debug_log("Failed to create depth stencil state");
            return false;
        }

        ctx->perspectiveDepthStencilState = (__bridge_retained void*)depthStencilState;
        metal_debug_log("Perspective pipeline created successfully with depth testing");
    }

    return true;
}
