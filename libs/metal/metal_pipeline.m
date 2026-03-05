#include "metal.h"

// ============================================================================
// Pipeline management: shader compilation, render/compute pipeline creation
// ============================================================================

vdynamic* metal_compile_shader_impl(vstring *source, int shaderType) {
    if (ctx == NULL || ctx->device == NULL || source == NULL) return NULL;

    @autoreleasepool {
        id<MTLDevice> device = (__bridge id<MTLDevice>)ctx->device;

        NSString *shaderSource = [NSString stringWithUTF8String:(const char*)hl_to_utf8(source->bytes)];
        if (shaderSource == NULL) return NULL;

        // Log full shader source for debugging
        metal_debug_log("=== FULL SHADER SOURCE (type=%d) ===\n%s\n=== END SHADER SOURCE ===", shaderType, [shaderSource UTF8String]);

        NSError *error = nil;
        id<MTLLibrary> library = [device newLibraryWithSource:shaderSource options:nil error:&error];
        if (library == NULL || error != nil) {
            metal_log_error("Shader compilation failed: %s", [error.localizedDescription UTF8String]);
            return NULL;
        }

        // Get the main function - Metal shaders should have a main function
        // shaderType: 0=vertex, 1=fragment, 2=compute
        NSString *functionName;
        if (shaderType == 0) {
            functionName = @"vertex_main";
        } else if (shaderType == 1) {
            functionName = @"fragment_main";
        } else if (shaderType == 2) {
            functionName = @"compute_main";
        } else {
            metal_debug_log("Unknown shader type: %d", shaderType);
            return NULL;
        }
        
        id<MTLFunction> function = [library newFunctionWithName:functionName];
        if (function == NULL) {
            metal_debug_log("Failed to find function %s in shader", [functionName UTF8String]);
            return NULL;
        }

        return (vdynamic*)(__bridge_retained void*)function;
    }
}

vdynamic* metal_create_compute_pipeline_from_function_impl(vdynamic *func) {
    if (ctx == NULL || ctx->device == NULL || func == NULL) return NULL;

    @autoreleasepool {
        id<MTLDevice> device = (__bridge id<MTLDevice>)ctx->device;
        id<MTLFunction> function = (__bridge id<MTLFunction>)func;

        NSError *error = nil;
        id<MTLComputePipelineState> pipelineState = [device newComputePipelineStateWithFunction:function error:&error];
        if (!pipelineState) {
            metal_debug_log("Failed to create compute pipeline state: %s", [[error localizedDescription] UTF8String]);
            return NULL;
        }

        metal_debug_log("Created compute pipeline state successfully");
        return (vdynamic*)(__bridge_retained void*)pipelineState;
    }
}

// Map Heaps Blend enum to MTLBlendFactor
// MUST match order in h3d/mat/Data.hx Blend enum:
// One=0, Zero=1, SrcAlpha=2, SrcColor=3, DstAlpha=4, DstColor=5,
// OneMinusSrcAlpha=6, OneMinusSrcColor=7, OneMinusDstAlpha=8, OneMinusDstColor=9,
// SrcAlphaSaturate=10
static const MTLBlendFactor BLEND_FACTORS[] = {
    MTLBlendFactorOne,                      // One = 0
    MTLBlendFactorZero,                     // Zero = 1
    MTLBlendFactorSourceAlpha,              // SrcAlpha = 2
    MTLBlendFactorSourceColor,              // SrcColor = 3
    MTLBlendFactorDestinationAlpha,         // DstAlpha = 4
    MTLBlendFactorDestinationColor,         // DstColor = 5
    MTLBlendFactorOneMinusSourceAlpha,      // OneMinusSrcAlpha = 6
    MTLBlendFactorOneMinusSourceColor,      // OneMinusSrcColor = 7
    MTLBlendFactorOneMinusDestinationAlpha, // OneMinusDstAlpha = 8
    MTLBlendFactorOneMinusDestinationColor, // OneMinusDstColor = 9
    MTLBlendFactorSourceAlphaSaturated,     // SrcAlphaSaturate = 10
};

// Map Heaps Operation enum to MTLBlendOperation
// MUST match order in h3d/mat/Data.hx Operation enum:
// Add=0, Sub=1, ReverseSub=2, Min=3, Max=4
static const MTLBlendOperation BLEND_OPS[] = {
    MTLBlendOperationAdd,             // Add = 0
    MTLBlendOperationSubtract,        // Sub = 1
    MTLBlendOperationReverseSubtract, // ReverseSub = 2
    MTLBlendOperationMin,             // Min = 3
    MTLBlendOperationMax,             // Max = 4
};

vdynamic* metal_create_render_pipeline_impl(vdynamic *vertexShader, vdynamic *fragmentShader, vstring *vertexDesc, int blendSrc, int blendDst, int blendAlphaSrc, int blendAlphaDst, int blendOp, int blendAlphaOp) {
    if (ctx == NULL || ctx->device == NULL || vertexShader == NULL || fragmentShader == NULL) return NULL;

    @autoreleasepool {
        id<MTLDevice> device = (__bridge id<MTLDevice>)ctx->device;
        id<MTLFunction> vertexFunction = (__bridge id<MTLFunction>)vertexShader;
        id<MTLFunction> fragmentFunction = (__bridge id<MTLFunction>)fragmentShader;

#ifdef METAL_DEBUG
        // Debug: log the vertex descriptor string
        if (vertexDesc != NULL && vertexDesc->bytes != NULL) {
            const char *descStr = (const char*)hl_to_utf8(vertexDesc->bytes);
            metal_debug_log("create_render_pipeline() - vertexDesc: '%s'", descStr);
        } else {
            metal_debug_log("create_render_pipeline() - vertexDesc is NULL");
        }
#endif

        MTLRenderPipelineDescriptor *descriptor = [[MTLRenderPipelineDescriptor alloc] init];
        descriptor.vertexFunction = vertexFunction;
        descriptor.fragmentFunction = fragmentFunction;

// CRITICAL FIX: Use current render target's pixel format instead of hardcoded BGRA8Unorm
// Use the pixel format stored when we began the render pass
MTLPixelFormat targetPixelFormat = (MTLPixelFormat)ctx->currentTargetPixelFormat;

// If no format was set (shouldn't happen), default to BGRA8Unorm
if (targetPixelFormat == 0) {
    targetPixelFormat = MTLPixelFormatBGRA8Unorm;
    metal_debug_log("WARNING: create_render_pipeline() - currentTargetPixelFormat not set, using BGRA8Unorm");
} else {
    metal_debug_log("create_render_pipeline() - Using pixel format: %d", (int)targetPixelFormat);
}

// Check if this is a depth-only format (for shadow maps)
BOOL isDepthFormat = (targetPixelFormat == MTLPixelFormatDepth16Unorm ||
                      targetPixelFormat == MTLPixelFormatDepth32Float ||
                      targetPixelFormat == MTLPixelFormatDepth32Float_Stencil8 ||
                      targetPixelFormat == MTLPixelFormatDepth24Unorm_Stencil8);

if (isDepthFormat) {
    // Depth-only rendering (e.g., shadow maps) - NO color attachment
    metal_debug_log("create_render_pipeline() - Depth-only pipeline (no color attachment)");
    descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatInvalid;

    // Set depth attachment format
    descriptor.depthAttachmentPixelFormat = targetPixelFormat;

    // Set stencil format if applicable
    if (targetPixelFormat == MTLPixelFormatDepth32Float_Stencil8 ||
        targetPixelFormat == MTLPixelFormatDepth24Unorm_Stencil8) {
        descriptor.stencilAttachmentPixelFormat = targetPixelFormat;
    }
} else {
    // Color rendering - set up color attachment(s)
    // Check for MRT (Multiple Render Targets)
    int mrtCount = ctx->currentMRTCount;
    if (mrtCount <= 0) mrtCount = 1;  // Default to single target
    
    metal_debug_log("create_render_pipeline() - Setting up %d color attachment(s)", mrtCount);
    
    // CRITICAL FIX: Use per-attachment pixel formats for MRT
    // Different G-Buffer textures may have different formats (RGBA8, RGBA16F, R32F, etc.)
    for (int i = 0; i < mrtCount; i++) {
        MTLPixelFormat attachmentFormat;
        if (mrtCount > 1 && ctx->currentMRTPixelFormats[i] != 0) {
            // MRT mode: use the specific format for each attachment
            attachmentFormat = (MTLPixelFormat)ctx->currentMRTPixelFormats[i];
            metal_debug_log("  MRT attachment %d: format=%d", i, (int)attachmentFormat);
        } else {
            // Single target mode: use the common target format
            attachmentFormat = targetPixelFormat;
        }
        descriptor.colorAttachments[i].pixelFormat = attachmentFormat;
        
        // Configure blend state from parameters
        // Disable blending only for (One, Zero) which is opaque rendering
        BOOL blendingEnabled = !(blendSrc == 0 && blendDst == 1);
        descriptor.colorAttachments[i].blendingEnabled = blendingEnabled;
        descriptor.colorAttachments[i].rgbBlendOperation = BLEND_OPS[blendOp];
        descriptor.colorAttachments[i].alphaBlendOperation = BLEND_OPS[blendAlphaOp];
        descriptor.colorAttachments[i].sourceRGBBlendFactor = BLEND_FACTORS[blendSrc];
        descriptor.colorAttachments[i].sourceAlphaBlendFactor = BLEND_FACTORS[blendAlphaSrc];
        descriptor.colorAttachments[i].destinationRGBBlendFactor = BLEND_FACTORS[blendDst];
        descriptor.colorAttachments[i].destinationAlphaBlendFactor = BLEND_FACTORS[blendAlphaDst];
    }
    
    // CRITICAL: Mark unused color attachments as Invalid to handle shader outputs
    // that exceed the current render target count (e.g., shader writes to [[color(5)]]
    // but render pass only has 5 targets 0-4)
    for (int i = mrtCount; i < 8; i++) {
        descriptor.colorAttachments[i].pixelFormat = MTLPixelFormatInvalid;
    }

    metal_debug_log("create_render_pipeline() - Blend: src=%d dst=%d alphaSrc=%d alphaDst=%d op=%d alphaOp=%d enabled=%d",
                   blendSrc, blendDst, blendAlphaSrc, blendAlphaDst, blendOp, blendAlphaOp, !(blendSrc == 0 && blendDst == 1));

    // Only set depth-stencil formats if we have a depth buffer attached
    // Check if ctx has depth texture information (stored during render pass setup)
    if (ctx->hasDepthBuffer) {
        descriptor.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
        descriptor.stencilAttachmentPixelFormat = MTLPixelFormatDepth32Float_Stencil8;
    } else {
        // No depth buffer - leave formats as MTLPixelFormatInvalid (default)
        descriptor.depthAttachmentPixelFormat = MTLPixelFormatInvalid;
        descriptor.stencilAttachmentPixelFormat = MTLPixelFormatInvalid;
    }
}

// Parse vertexDesc and dynamically build vertex descriptor
// Format: "position:float3,normal:float3,uv:float2" etc.
        MTLVertexDescriptor *vertexDescriptor = [[MTLVertexDescriptor alloc] init];

if (vertexDesc != NULL && vertexDesc->bytes != NULL) {
    NSString *descStr = [NSString stringWithUTF8String:(const char*)hl_to_utf8(vertexDesc->bytes)];

    // Check if stride is explicitly specified: "attr1:type1,attr2:type2|stride:N|instride:M"
    int explicitStride = 0;
    int explicitInstanceStride = 0;
    NSArray *mainParts = [descStr componentsSeparatedByString:@"|"];
    NSString *attributesStr = mainParts[0];

    if (mainParts.count > 1) {
        // Parse optional stride parameters
        for (int i = 1; i < mainParts.count; i++) {
            NSString *param = [mainParts[i] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if ([param hasPrefix:@"stride:"]) {
                explicitStride = [[param substringFromIndex:7] intValue];
                metal_debug_log("Explicit stride specified: %d bytes", explicitStride);
            } else if ([param hasPrefix:@"instride:"]) {
                explicitInstanceStride = [[param substringFromIndex:9] intValue];
                metal_debug_log("Explicit instance stride specified: %d bytes", explicitInstanceStride);
            }
        }
    }

    NSArray *attributes = [attributesStr componentsSeparatedByString:@","];

    int currentOffset = 0;
    int attributeIndex = 0;
    int instanceBufferOffset = 0;  // Track offset for instance buffer attributes
    int instanceAttrStartIndex = -1;  // First instance attribute index
    int instanceStepRate = 1;  // Track step rate for instance buffer (divisor)

    for (NSString *attr in attributes) {
        NSArray *parts = [attr componentsSeparatedByString:@":"];
        if (parts.count >= 2) {
            // Format: name:type or name:type:bufferIndex or name:type:bufferIndex:divisor
            __unused NSString *name = [parts[0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            NSString *type = [parts[1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            int bufferIndex = 0;  // Default to buffer 0
            int divisor = 1;  // Default divisor
            if (parts.count >= 3) {
                bufferIndex = [[parts[2] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] intValue];
            }
            if (parts.count >= 4) {
                divisor = [[parts[3] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] intValue];
                if (divisor > 0) instanceStepRate = divisor;
            }

            MTLVertexFormat format;
            int size = 0;

            if ([type isEqualToString:@"float"]) {
                format = MTLVertexFormatFloat;
                size = 4;
            } else if ([type isEqualToString:@"float2"]) {
                format = MTLVertexFormatFloat2;
                size = 8;
            } else if ([type isEqualToString:@"float3"]) {
                format = MTLVertexFormatFloat3;
                size = 12;
            } else if ([type isEqualToString:@"float4"]) {
                format = MTLVertexFormatFloat4;
                size = 16;
            } else if ([type isEqualToString:@"uchar4"]) {
                format = MTLVertexFormatUChar4;
                size = 4;
            } else {
                metal_debug_log("Unknown vertex type: %s", [type UTF8String]);
                continue;
            }

            vertexDescriptor.attributes[attributeIndex].format = format;
            if (bufferIndex == 0) {
                vertexDescriptor.attributes[attributeIndex].offset = currentOffset;
                vertexDescriptor.attributes[attributeIndex].bufferIndex = 0;
                currentOffset += size;
            } else {
                // Instance buffer attribute
                if (instanceAttrStartIndex < 0) instanceAttrStartIndex = attributeIndex;
                vertexDescriptor.attributes[attributeIndex].offset = instanceBufferOffset;
                vertexDescriptor.attributes[attributeIndex].bufferIndex = bufferIndex;
                instanceBufferOffset += size;
            }

            metal_debug_log("Vertex attribute %d: %s (%s) at offset %d in buffer %d",
                          attributeIndex, [name UTF8String], [type UTF8String], 
                          (bufferIndex == 0) ? (currentOffset - size) : (instanceBufferOffset - size),
                          bufferIndex);

            attributeIndex++;
        }
    }

    // Set vertex buffer 0 layout (per-vertex data)
    int finalStride = (explicitStride > 0) ? explicitStride : currentOffset;
    vertexDescriptor.layouts[0].stride = finalStride;
    vertexDescriptor.layouts[0].stepRate = 1;
    vertexDescriptor.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;
    
    // Set vertex buffer 1 layout for instance data (per-instance stepping)
    if (instanceBufferOffset > 0 || explicitInstanceStride > 0) {
        int finalInstanceStride = (explicitInstanceStride > 0) ? explicitInstanceStride : instanceBufferOffset;
        vertexDescriptor.layouts[1].stride = finalInstanceStride;
        vertexDescriptor.layouts[1].stepRate = instanceStepRate;
        vertexDescriptor.layouts[1].stepFunction = MTLVertexStepFunctionPerInstance;
        metal_debug_log("Instance buffer layout: stride=%d bytes (explicit=%d, calculated=%d), stepRate=%d", finalInstanceStride, explicitInstanceStride, instanceBufferOffset, instanceStepRate);
    }

    metal_debug_log("Vertex descriptor: stride=%d bytes (explicit=%d, calculated=%d), %d attributes",
                  finalStride, explicitStride, currentOffset, attributeIndex);
} else {
    // Fallback to 2D format if no descriptor provided
    metal_debug_log("No vertex descriptor provided, using 2D fallback");
    vertexDescriptor.attributes[0].format = MTLVertexFormatFloat2;
    vertexDescriptor.attributes[0].offset = 0;
    vertexDescriptor.attributes[0].bufferIndex = 0;

    vertexDescriptor.attributes[1].format = MTLVertexFormatFloat2;
    vertexDescriptor.attributes[1].offset = 8;
    vertexDescriptor.attributes[1].bufferIndex = 0;

    vertexDescriptor.attributes[2].format = MTLVertexFormatFloat4;
    vertexDescriptor.attributes[2].offset = 16;
    vertexDescriptor.attributes[2].bufferIndex = 0;

    vertexDescriptor.layouts[0].stride = 32;
    vertexDescriptor.layouts[0].stepRate = 1;
    vertexDescriptor.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;
}

        descriptor.vertexDescriptor = vertexDescriptor;

        NSError *error = nil;
        id<MTLRenderPipelineState> pipelineState = [device newRenderPipelineStateWithDescriptor:descriptor error:&error];
        if (pipelineState == NULL || error != nil) {
            metal_debug_log("Pipeline creation failed: %s", [error.localizedDescription UTF8String]);
            return NULL;
        }

        metal_debug_log("create_render_pipeline() - SUCCESS");
        return (vdynamic*)(__bridge_retained void*)pipelineState;
    }
}

void metal_dispose_pipeline_impl(vdynamic *pipeline) {
    if (pipeline == NULL) return;

    @autoreleasepool {
        id<MTLRenderPipelineState> pipelineState = (__bridge_transfer id<MTLRenderPipelineState>)pipeline;
        (void)pipelineState; // ARC will handle release
    }
}
