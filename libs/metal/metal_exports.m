#include "metal.h"

// Device and command queue - Metal specific API (new functions only)
HL_PRIM vdynamic* HL_NAME(get_device)() {
    if (ctx == NULL) {
        metal_debug_log("ERROR: get_device() - ctx is NULL");
        return NULL;
    }
    metal_debug_log("get_device() - returning device");
    return (vdynamic*)ctx->device;
}

HL_PRIM vdynamic* HL_NAME(create_command_buffer)() {
    if (ctx == NULL || ctx->commandQueue == NULL) {
        metal_debug_log("ERROR: create_command_buffer() - ctx or commandQueue is NULL");
        return NULL;
    }

    @autoreleasepool {
        id<MTLCommandQueue> commandQueue = (__bridge id<MTLCommandQueue>)ctx->commandQueue;
        id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];
        if (commandBuffer == NULL) {
            metal_debug_log("ERROR: create_command_buffer() - failed to create command buffer");
            return NULL;
        }

        metal_debug_log("create_command_buffer() - SUCCESS");
        return (vdynamic*)(__bridge_retained void*)commandBuffer;
    }
}

HL_PRIM bool HL_NAME(commit_command_buffer)(vdynamic *cmdBuffer) {
    if (cmdBuffer == NULL) {
        metal_debug_log("ERROR: commit_command_buffer() - cmdBuffer is NULL");
        return false;
    }

    @autoreleasepool {
        id<MTLCommandBuffer> commandBuffer = (__bridge_transfer id<MTLCommandBuffer>)cmdBuffer;

        // Present the drawable if we have one
        if (ctx != NULL && ctx->currentDrawable != NULL) {
            id<CAMetalDrawable> drawable = (__bridge id<CAMetalDrawable>)ctx->currentDrawable;
            [commandBuffer presentDrawable:drawable];

            // Release the drawable after presenting
            id<CAMetalDrawable> drawableToRelease = (__bridge_transfer id<CAMetalDrawable>)ctx->currentDrawable;
            (void)drawableToRelease; // ARC will handle release
            ctx->currentDrawable = NULL;
            ctx->currentCommandBuffer = NULL;
            metal_debug_log("commit_command_buffer() - SUCCESS with drawable");
        } else {
            metal_debug_log("WARNING: commit_command_buffer() - no drawable to present");
        }

        [commandBuffer commit];
        return true;
    }
}

HL_PRIM void HL_NAME(wait_until_completed)(vdynamic *cmdBuffer) {
    if (cmdBuffer == NULL) return;

    @autoreleasepool {
        id<MTLCommandBuffer> commandBuffer = (__bridge id<MTLCommandBuffer>)cmdBuffer;
        
        // Wait synchronously for the command buffer to finish execution
        [commandBuffer waitUntilCompleted];
        
        metal_debug_log("wait_until_completed() - Command buffer completed");
    }
}

HL_PRIM bool HL_NAME(commit_without_present)(vdynamic *cmdBuffer) {
    if (cmdBuffer == NULL) {
        metal_debug_log("ERROR: commit_without_present() - null command buffer");
        return false;
    }

    @autoreleasepool {
        id<MTLCommandBuffer> commandBuffer = (__bridge_transfer id<MTLCommandBuffer>)cmdBuffer;
        
        // Just commit, don't present drawable
        [commandBuffer commit];
        metal_debug_log("commit_without_present() - SUCCESS");
        return true;
    }
}

// Buffer management - Metal specific with proper memory management (new functions only)
HL_PRIM vdynamic* HL_NAME(create_buffer)(int size, int usage) {
    if (ctx == NULL || ctx->device == NULL || size <= 0) {
        metal_debug_log("ERROR: create_buffer() - invalid parameters (size=%d)", size);
        return NULL;
    }

    @autoreleasepool {
        id<MTLDevice> device = (__bridge id<MTLDevice>)ctx->device;

        MTLResourceOptions options = MTLResourceStorageModeShared;
        if (usage & 1) options = MTLResourceStorageModeShared; // Dynamic
        if (usage & 2) options |= MTLResourceCPUCacheModeWriteCombined; // Uniform

        id<MTLBuffer> buffer = [device newBufferWithLength:size options:options];
        if (buffer == NULL) {
            metal_debug_log("ERROR: create_buffer() - failed to create buffer");
            return NULL;
        }

        metal_debug_log("create_buffer() - SUCCESS (size=%d, usage=%d)", size, usage);
        return (vdynamic*)(__bridge_retained void*)buffer;
    }
}

HL_PRIM bool HL_NAME(upload_buffer_data)(vdynamic *buffer, vbyte *data, int size, int offset) {
    if (buffer == NULL || data == NULL || size <= 0) {
        return false;
    }

    @autoreleasepool {
        id<MTLBuffer> metalBuffer = (__bridge id<MTLBuffer>)buffer;
        
        if (offset + size > metalBuffer.length) {
            return false;
        }

        memcpy((char*)metalBuffer.contents + offset, data, size);
        
        // CRITICAL: For MTLResourceStorageModeManaged buffers, we must call didModifyRange
        // to sync CPU changes to GPU! Without this, GPU never sees the data.
        [metalBuffer didModifyRange:NSMakeRange(offset, size)];
        
        // Log ALL buffer uploads to debug lighting issue
        metal_debug_log("upload_buffer_data() - size=%d, offset=%d", size, offset);
        
        // Verify data after upload for parameter buffers (128 bytes = 8 vec4s)
        if (size == 128 && offset == 0) {
            float *floats = (float*)metalBuffer.contents;
            metal_debug_log("=== NATIVE SIDE: Parameter buffer received (128 bytes) ===");
            metal_debug_log("vec4[0]: [%.6f, %.6f, %.6f, %.6f]", floats[0], floats[1], floats[2], floats[3]);
            metal_debug_log("vec4[1]: [%.6f, %.6f, %.6f, %.6f]", floats[4], floats[5], floats[6], floats[7]);
            metal_debug_log("vec4[2]: [%.6f, %.6f, %.6f, %.6f]", floats[8], floats[9], floats[10], floats[11]);
            metal_debug_log("vec4[3]: [%.6f, %.6f, %.6f, %.6f]", floats[12], floats[13], floats[14], floats[15]);
            metal_debug_log("vec4[4]: [%.6f, %.6f, %.6f, %.6f]", floats[16], floats[17], floats[18], floats[19]);
            metal_debug_log("vec4[5]: [%.6f, %.6f, %.6f, %.6f]", floats[20], floats[21], floats[22], floats[23]);
            metal_debug_log("vec4[6] (viewportA): [%.6f, %.6f, %.6f, %.6f]", floats[24], floats[25], floats[26], floats[27]);
            metal_debug_log("vec4[7] (viewportB): [%.6f, %.6f, %.6f, %.6f]", floats[28], floats[29], floats[30], floats[31]);
            metal_debug_log("=== END NATIVE VERIFICATION ===");
        }
        
        return true;
    }
}

// Texture management - Metal specific (new functions only)
HL_PRIM vdynamic* HL_NAME(create_texture)(int width, int height, int format, int usage, bool mipmapped, bool isCube) {
    if (ctx == NULL || ctx->device == NULL || width <= 0 || height <= 0) return NULL;

    @autoreleasepool {
        id<MTLDevice> device = (__bridge id<MTLDevice>)ctx->device;

        MTLTextureDescriptor *descriptor;
        if (isCube) {
            descriptor = [MTLTextureDescriptor textureCubeDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                size:width
                                                                           mipmapped:mipmapped];
        } else {
            descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                                  width:width
                                                                                 height:height
                                                                              mipmapped:mipmapped];
        }

        // Map format parameter to Metal pixel format
        switch (format) {
            case 0: descriptor.pixelFormat = MTLPixelFormatRGBA8Unorm; break;
            case 1: descriptor.pixelFormat = MTLPixelFormatBGRA8Unorm; break;
            case 2: descriptor.pixelFormat = MTLPixelFormatRGBA8Unorm; break; // RGB8 -> RGBA8
            case 3: descriptor.pixelFormat = MTLPixelFormatRG8Unorm; break;
            case 4: descriptor.pixelFormat = MTLPixelFormatR8Unorm; break;
            case 5: descriptor.pixelFormat = MTLPixelFormatRGBA16Float; break;
            case 6: descriptor.pixelFormat = MTLPixelFormatRGBA32Float; break;
            default: descriptor.pixelFormat = MTLPixelFormatRGBA8Unorm; break;
        }

        // Set texture usage
        MTLTextureUsage textureUsage = MTLTextureUsageShaderRead;
        if (usage & 2) textureUsage |= MTLTextureUsageRenderTarget;
        if (usage & 4) textureUsage |= MTLTextureUsageShaderWrite;
        descriptor.usage = textureUsage;

        id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor];
        if (texture == NULL) {
            metal_debug_log("ERROR: create_texture() - failed to create texture");
            return NULL;
        }

        metal_debug_log("create_texture() - SUCCESS (width=%d, height=%d, format=%d, usage=%d)", width, height, format, usage);
        return (vdynamic*)(__bridge_retained void*)texture;
    }
}

HL_PRIM bool HL_NAME(upload_texture_data)(vdynamic *texture, vbyte *data, int width, int height, int level, int slice) {
    if (texture == NULL || data == NULL || width <= 0 || height <= 0) return false;

    @autoreleasepool {
        id<MTLTexture> metalTexture = (__bridge id<MTLTexture>)texture;

        MTLRegion region = MTLRegionMake2D(0, 0, width, height);
        NSUInteger bytesPerRow = width * 4; // Assuming RGBA8

        [metalTexture replaceRegion:region
                        mipmapLevel:level
                              slice:slice
                          withBytes:data
                        bytesPerRow:bytesPerRow
                      bytesPerImage:0];

        return true;
    }
}

HL_PRIM bool HL_NAME(capture_texture_pixels)(vdynamic *texture, vbyte *data, int width, int height, int level) {
    if (texture == NULL || data == NULL || width <= 0 || height <= 0) {
        metal_debug_log("ERROR: capture_texture_pixels() - invalid parameters");
        return false;
    }

    @autoreleasepool {
        id<MTLTexture> metalTexture = (__bridge id<MTLTexture>)texture;

        MTLRegion region = MTLRegionMake2D(0, 0, width, height);
        NSUInteger bytesPerRow = width * 4; // Assuming RGBA8

        // Read pixels from texture to buffer
        [metalTexture getBytes:data
                   bytesPerRow:bytesPerRow
                    fromRegion:region
                   mipmapLevel:level];

        metal_debug_log("capture_texture_pixels() - SUCCESS (width=%d, height=%d, level=%d)", width, height, level);
        return true;
    }
}

HL_PRIM void HL_NAME(generate_mipmaps)(vdynamic *texture) {
    if (texture == NULL || ctx == NULL || ctx->commandQueue == NULL) return;

    @autoreleasepool {
        id<MTLTexture> metalTexture = (__bridge id<MTLTexture>)texture;
        id<MTLCommandQueue> commandQueue = (__bridge id<MTLCommandQueue>)ctx->commandQueue;
        
        // Create a blit command encoder to generate mipmaps
        id<MTLCommandBuffer> commandBuffer = [commandQueue commandBuffer];
        if (commandBuffer == NULL) {
            metal_debug_log("ERROR: generate_mipmaps() - failed to create command buffer");
            return;
        }
        
        id<MTLBlitCommandEncoder> blitEncoder = [commandBuffer blitCommandEncoder];
        if (blitEncoder == NULL) {
            metal_debug_log("ERROR: generate_mipmaps() - failed to create blit encoder");
            return;
        }
        
        [blitEncoder generateMipmapsForTexture:metalTexture];
        [blitEncoder endEncoding];
        
        [commandBuffer commit];
        [commandBuffer waitUntilCompleted];
        
        metal_debug_log("generate_mipmaps() - SUCCESS");
    }
}

HL_PRIM void HL_NAME(dispose_texture)(vdynamic *texture) {
    if (texture == NULL) return;

    @autoreleasepool {
        id<MTLTexture> metalTexture = (__bridge_transfer id<MTLTexture>)texture;
        (void)metalTexture; // ARC will handle release
    }
}

// Sampler State Management
// filter: 0=Nearest, 1=Linear
// mipFilter: 0=None, 1=Nearest, 2=Linear
// wrap: 0=Clamp, 1=Repeat
HL_PRIM vdynamic* HL_NAME(create_sampler_state)(int minFilter, int magFilter, int mipFilter, int wrapS, int wrapT) {
    if (ctx == NULL || ctx->device == NULL) return NULL;

    @autoreleasepool {
        id<MTLDevice> device = (__bridge id<MTLDevice>)ctx->device;
        
        MTLSamplerDescriptor *samplerDesc = [[MTLSamplerDescriptor alloc] init];
        
        // Min/Mag filter
        samplerDesc.minFilter = (minFilter == 0) ? MTLSamplerMinMagFilterNearest : MTLSamplerMinMagFilterLinear;
        samplerDesc.magFilter = (magFilter == 0) ? MTLSamplerMinMagFilterNearest : MTLSamplerMinMagFilterLinear;
        
        // Mip filter
        if (mipFilter == 0) {
            samplerDesc.mipFilter = MTLSamplerMipFilterNotMipmapped;
        } else if (mipFilter == 1) {
            samplerDesc.mipFilter = MTLSamplerMipFilterNearest;
        } else {
            samplerDesc.mipFilter = MTLSamplerMipFilterLinear;
        }
        
        // Wrap modes
        MTLSamplerAddressMode addressModeS = (wrapS == 1) ? MTLSamplerAddressModeRepeat : MTLSamplerAddressModeClampToEdge;
        MTLSamplerAddressMode addressModeT = (wrapT == 1) ? MTLSamplerAddressModeRepeat : MTLSamplerAddressModeClampToEdge;
        samplerDesc.sAddressMode = addressModeS;
        samplerDesc.tAddressMode = addressModeT;
        
        id<MTLSamplerState> samplerState = [device newSamplerStateWithDescriptor:samplerDesc];
        if (samplerState == NULL) {
            metal_debug_log("ERROR: create_sampler_state() - failed to create sampler");
            return NULL;
        }
        
        return (vdynamic*)(__bridge_retained void*)samplerState;
    }
}

HL_PRIM void HL_NAME(dispose_sampler)(vdynamic *sampler) {
    if (sampler == NULL) return;

    @autoreleasepool {
        id<MTLSamplerState> samplerState = (__bridge_transfer id<MTLSamplerState>)sampler;
        (void)samplerState; // ARC will handle release
    }
}

HL_PRIM void HL_NAME(set_fragment_samplers)(vdynamic *encoder, varray *samplers) {
    if (encoder == NULL || samplers == NULL) return;

    @autoreleasepool {
        id<MTLRenderCommandEncoder> renderEncoder = (__bridge id<MTLRenderCommandEncoder>)encoder;
        
        int count = samplers->size;
        if (count <= 0) return;
        
        // Convert varray to id<MTLSamplerState> array
        id<MTLSamplerState> samplerArray[count];
        vdynamic **samplerPtrs = hl_aptr(samplers, vdynamic*);
        
        for (int i = 0; i < count; i++) {
            samplerArray[i] = (__bridge id<MTLSamplerState>)samplerPtrs[i];
        }
        
        [renderEncoder setFragmentSamplerStates:samplerArray withRange:NSMakeRange(0, count)];
    }
}

// Shader compilation - Metal specific with MSL (new functions only)
HL_PRIM vdynamic* HL_NAME(compile_shader)(vstring *source, int shaderType) {
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
            metal_debug_log("Shader compilation failed: %s", [error.localizedDescription UTF8String]);
            return NULL;
        }

        // Get the main function - Metal shaders should have a main function
        NSString *functionName = (shaderType == 0) ? @"vertex_main" : @"fragment_main";
        id<MTLFunction> function = [library newFunctionWithName:functionName];
        if (function == NULL) {
            metal_debug_log("Failed to find function %s in shader", [functionName UTF8String]);
            return NULL;
        }

        return (vdynamic*)(__bridge_retained void*)function;
    }
}

HL_PRIM vdynamic* HL_NAME(create_render_pipeline)(vdynamic *vertexShader, vdynamic *fragmentShader, vstring *vertexDesc) {
    if (ctx == NULL || ctx->device == NULL || vertexShader == NULL || fragmentShader == NULL) return NULL;

    @autoreleasepool {
        id<MTLDevice> device = (__bridge id<MTLDevice>)ctx->device;
        id<MTLFunction> vertexFunction = (__bridge id<MTLFunction>)vertexShader;
        id<MTLFunction> fragmentFunction = (__bridge id<MTLFunction>)fragmentShader;

        // Debug: log the vertex descriptor string
        if (vertexDesc != NULL && vertexDesc->bytes != NULL) {
            const char *descStr = (const char*)hl_to_utf8(vertexDesc->bytes);
            metal_debug_log("create_render_pipeline() - vertexDesc: '%s'", descStr);
        } else {
            metal_debug_log("create_render_pipeline() - vertexDesc is NULL");
        }

        MTLRenderPipelineDescriptor *descriptor = [[MTLRenderPipelineDescriptor alloc] init];
        descriptor.vertexFunction = vertexFunction;
        descriptor.fragmentFunction = fragmentFunction;

        // Set default color attachment
        descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        descriptor.colorAttachments[0].blendingEnabled = YES;
        descriptor.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
        descriptor.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
        descriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
        descriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;

        // CRITICAL: Set depth attachment format for depth testing to work!
        // Must match the depth texture format (MTLPixelFormatDepth32Float)
        descriptor.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;

        // Parse vertexDesc and dynamically build vertex descriptor
        // Format: "position:float3,normal:float3,uv:float2" etc.
        MTLVertexDescriptor *vertexDescriptor = [[MTLVertexDescriptor alloc] init];
        
        if (vertexDesc != NULL && vertexDesc->bytes != NULL) {
            NSString *descStr = [NSString stringWithUTF8String:(const char*)hl_to_utf8(vertexDesc->bytes)];
            
            // Check if stride is explicitly specified: "attr1:type1,attr2:type2|stride:N"
            int explicitStride = 0;
            NSArray *mainParts = [descStr componentsSeparatedByString:@"|"];
            NSString *attributesStr = mainParts[0];
            
            if (mainParts.count > 1) {
                // Parse optional stride parameter
                for (int i = 1; i < mainParts.count; i++) {
                    NSString *param = [mainParts[i] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    if ([param hasPrefix:@"stride:"]) {
                        explicitStride = [[param substringFromIndex:7] intValue];
                        metal_debug_log("Explicit stride specified: %d bytes", explicitStride);
                    }
                }
            }
            
            NSArray *attributes = [attributesStr componentsSeparatedByString:@","];
            
            int currentOffset = 0;
            int attributeIndex = 0;
            
            for (NSString *attr in attributes) {
                NSArray *parts = [attr componentsSeparatedByString:@":"];
                if (parts.count == 2) {
                    NSString *name = [parts[0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    NSString *type = [parts[1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                    
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
                    } else {
                        metal_debug_log("Unknown vertex type: %s", [type UTF8String]);
                        continue;
                    }
                    
                    vertexDescriptor.attributes[attributeIndex].format = format;
                    vertexDescriptor.attributes[attributeIndex].offset = currentOffset;
                    vertexDescriptor.attributes[attributeIndex].bufferIndex = 0;
                    
                    metal_debug_log("Vertex attribute %d: %s (%s) at offset %d",
                                  attributeIndex, [name UTF8String], [type UTF8String], currentOffset);
                    
                    currentOffset += size;
                    attributeIndex++;
                }
            }
            
            // Set vertex buffer layout
            // Use explicit stride if provided, otherwise use calculated offset
            int finalStride = (explicitStride > 0) ? explicitStride : currentOffset;
            vertexDescriptor.layouts[0].stride = finalStride;
            vertexDescriptor.layouts[0].stepRate = 1;
            vertexDescriptor.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;
            
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

HL_PRIM void HL_NAME(dispose_pipeline)(vdynamic *pipeline) {
    if (pipeline == NULL) return;

    @autoreleasepool {
        id<MTLRenderPipelineState> pipelineState = (__bridge_transfer id<MTLRenderPipelineState>)pipeline;
        (void)pipelineState; // ARC will handle release
    }
}

// Render command encoder - Metal specific API (new functions only)
HL_PRIM vdynamic* HL_NAME(begin_render_pass)(vdynamic *cmdBuffer, int r, int g, int b, int a) {
    if (ctx == NULL || cmdBuffer == NULL) return NULL;

    @autoreleasepool {
        id<MTLCommandBuffer> commandBuffer = (__bridge id<MTLCommandBuffer>)cmdBuffer;
        CAMetalLayer *metalLayer = (__bridge CAMetalLayer*)ctx->layer;

        id<CAMetalDrawable> drawable = [metalLayer nextDrawable];
        if (drawable == NULL) {
            return NULL;
        }

        // Store the drawable and command buffer for presentation
        if (ctx->currentDrawable != NULL) {
            id<CAMetalDrawable> oldDrawable = (__bridge_transfer id<CAMetalDrawable>)ctx->currentDrawable;
            (void)oldDrawable; // Release old drawable
        }
        ctx->currentDrawable = (__bridge_retained void*)drawable;
        ctx->currentCommandBuffer = (__bridge void*)commandBuffer;

        MTLRenderPassDescriptor *renderPassDescriptor = [MTLRenderPassDescriptor renderPassDescriptor];
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture;
        renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
        renderPassDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(r/255.0, g/255.0, b/255.0, a/255.0);

        // CRITICAL: Attach depth texture for depth testing to work!
        if (ctx->depthTexture != NULL) {
            id<MTLTexture> depthTexture = (__bridge id<MTLTexture>)ctx->depthTexture;
            renderPassDescriptor.depthAttachment.texture = depthTexture;
            renderPassDescriptor.depthAttachment.loadAction = MTLLoadActionClear;
            renderPassDescriptor.depthAttachment.storeAction = MTLStoreActionDontCare;
            renderPassDescriptor.depthAttachment.clearDepth = 1.0;
            metal_debug_log("begin_render_pass() - Depth texture attached: %p", depthTexture);
        } else {
            metal_debug_log("begin_render_pass() - WARNING: No depth texture!");
        }

        id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
        if (encoder == NULL) return NULL;

        // Set winding order to counter-clockwise (Heaps/OpenGL convention)
        [encoder setFrontFacingWinding:MTLWindingClockwise];

        metal_debug_log("begin_render_pass() - SUCCESS");
        return (vdynamic*)(__bridge_retained void*)encoder;
    }
}

HL_PRIM vdynamic* HL_NAME(resume_render_pass)(vdynamic *cmdBuffer) {
    if (ctx == NULL || cmdBuffer == NULL) {
        metal_debug_log("ERROR: resume_render_pass() - ctx=%p cmdBuffer=%p", ctx, cmdBuffer);
        return NULL;
    }
    
    if (ctx->currentDrawable == NULL) {
        metal_debug_log("ERROR: resume_render_pass() - no currentDrawable!");
        return NULL;
    }

    @autoreleasepool {
        id<MTLCommandBuffer> commandBuffer = (__bridge id<MTLCommandBuffer>)cmdBuffer;
        id<CAMetalDrawable> drawable = (__bridge id<CAMetalDrawable>)ctx->currentDrawable;
        
        metal_debug_log("resume_render_pass() - drawable=%p texture=%p", drawable, drawable.texture);
        
        // Update command buffer reference
        ctx->currentCommandBuffer = (__bridge void*)commandBuffer;

        MTLRenderPassDescriptor *renderPassDescriptor = [MTLRenderPassDescriptor renderPassDescriptor];
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture;
        renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionLoad;  // LOAD existing content!
        renderPassDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;

        // CRITICAL: Attach depth texture for depth testing to work!
        if (ctx->depthTexture != NULL) {
            id<MTLTexture> depthTexture = (__bridge id<MTLTexture>)ctx->depthTexture;
            renderPassDescriptor.depthAttachment.texture = depthTexture;
            renderPassDescriptor.depthAttachment.loadAction = MTLLoadActionLoad;  // Load existing depth
            renderPassDescriptor.depthAttachment.storeAction = MTLStoreActionStore;
        }

        id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
        if (encoder == NULL) {
            metal_debug_log("ERROR: resume_render_pass() - failed to create encoder!");
            return NULL;
        }

        // Set winding order to counter-clockwise (Heaps/OpenGL convention)
        [encoder setFrontFacingWinding:MTLWindingClockwise];

        metal_debug_log("resume_render_pass() - SUCCESS");
        return (vdynamic*)(__bridge_retained void*)encoder;
    }
}

HL_PRIM vdynamic* HL_NAME(begin_texture_render_pass)(vdynamic *cmdBuffer, vdynamic *texture, int r, int g, int b, int a) {
    if (ctx == NULL || cmdBuffer == NULL || texture == NULL) {
        metal_debug_log("ERROR: begin_texture_render_pass() - invalid parameters");
        return NULL;
    }

    @autoreleasepool {
        id<MTLCommandBuffer> commandBuffer = (__bridge id<MTLCommandBuffer>)cmdBuffer;
        id<MTLTexture> metalTexture = (__bridge id<MTLTexture>)texture;
        
        // Update command buffer reference
        ctx->currentCommandBuffer = (__bridge void*)commandBuffer;

        MTLRenderPassDescriptor *renderPassDescriptor = [MTLRenderPassDescriptor renderPassDescriptor];
        renderPassDescriptor.colorAttachments[0].texture = metalTexture;
        
        // If alpha is negative, use Load action to preserve existing content (additive rendering)
        // Otherwise use Clear action
        if (a < 0) {
            renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionLoad;
        } else {
            renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
            renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(r/255.0, g/255.0, b/255.0, a/255.0);
        }
        
        renderPassDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;

        // CRITICAL: Attach depth texture for depth testing to work!
        // Note: For render-to-texture, we might need a separate depth texture in the future
        if (ctx->depthTexture != NULL) {
            id<MTLTexture> depthTexture = (__bridge id<MTLTexture>)ctx->depthTexture;
            renderPassDescriptor.depthAttachment.texture = depthTexture;
            if (a < 0) {
                renderPassDescriptor.depthAttachment.loadAction = MTLLoadActionLoad;
            } else {
                renderPassDescriptor.depthAttachment.loadAction = MTLLoadActionClear;
                renderPassDescriptor.depthAttachment.clearDepth = 1.0;
            }
            renderPassDescriptor.depthAttachment.storeAction = MTLStoreActionStore;
        }

        id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
        if (encoder == NULL) {
            metal_debug_log("ERROR: begin_texture_render_pass() - failed to create encoder!");
            return NULL;
        }

        // Set winding order to counter-clockwise (Heaps/OpenGL convention)
        [encoder setFrontFacingWinding:MTLWindingClockwise];

        metal_debug_log("begin_texture_render_pass() - SUCCESS");
        return (vdynamic*)(__bridge_retained void*)encoder;
    }
}

HL_PRIM void HL_NAME(set_render_pipeline_state)(vdynamic *encoder, vdynamic *pipeline) {
    if (encoder == NULL || pipeline == NULL) return;

    @autoreleasepool {
        id<MTLRenderCommandEncoder> renderEncoder = (__bridge id<MTLRenderCommandEncoder>)encoder;
        id<MTLRenderPipelineState> pipelineState = (__bridge id<MTLRenderPipelineState>)pipeline;

        [renderEncoder setRenderPipelineState:pipelineState];
        
        // Note: Depth state is now set separately via set_depth_state()
        metal_debug_log("set_render_pipeline_state() - SUCCESS");
    }
}

HL_PRIM void HL_NAME(set_depth_state)(vdynamic *encoder, bool depthTest, bool depthWrite) {
    if (encoder == NULL || ctx == NULL) return;

    @autoreleasepool {
        id<MTLRenderCommandEncoder> renderEncoder = (__bridge id<MTLRenderCommandEncoder>)encoder;
        
        // Choose appropriate depth state based on parameters
        id<MTLDepthStencilState> depthState = nil;
        
        if (depthTest && depthWrite) {
            // Full depth testing and writing - for 3D rendering
            depthState = (__bridge id<MTLDepthStencilState>)ctx->depthEnabledState;
            metal_debug_log("set_depth_state() - Depth test ON, write ON");
        } else if (!depthTest && !depthWrite) {
            // No depth testing or writing - for 2D rendering
            depthState = (__bridge id<MTLDepthStencilState>)ctx->depthDisabledState;
            metal_debug_log("set_depth_state() - Depth test OFF, write OFF");
        } else {
            // For now, treat any other combination as depth-disabled
            // TODO: Create more depth states for other combinations if needed
            depthState = (__bridge id<MTLDepthStencilState>)ctx->depthDisabledState;
            metal_debug_log("set_depth_state() - Using depth-disabled state (test=%d, write=%d)", depthTest, depthWrite);
        }
        
        if (depthState) {
            [renderEncoder setDepthStencilState:depthState];
        }
    }
}

HL_PRIM void HL_NAME(set_cull_mode)(vdynamic *encoder, int cullMode) {
    if (encoder == NULL) return;

    @autoreleasepool {
        id<MTLRenderCommandEncoder> renderEncoder = (__bridge id<MTLRenderCommandEncoder>)encoder;
        
        // Metal cull modes: 0 = None, 1 = Front, 2 = Back
        MTLCullMode metalCullMode;
        switch(cullMode) {
            case 0: metalCullMode = MTLCullModeNone; break;
            case 1: metalCullMode = MTLCullModeFront; break;
            case 2: metalCullMode = MTLCullModeBack; break;
            default: metalCullMode = MTLCullModeNone; break;
        }
        
        [renderEncoder setCullMode:metalCullMode];
        metal_debug_log("set_cull_mode() - Mode: %d (%s)", cullMode, 
            cullMode == 0 ? "None" : cullMode == 1 ? "Front" : "Back");
    }
}

HL_PRIM void HL_NAME(set_triangle_fill_mode)(vdynamic *encoder, bool wireframe) {
    if (encoder == NULL) return;

    @autoreleasepool {
        id<MTLRenderCommandEncoder> renderEncoder = (__bridge id<MTLRenderCommandEncoder>)encoder;
        
        // Metal triangle fill modes: MTLTriangleFillModeFill (solid) or MTLTriangleFillModeLines (wireframe)
        MTLTriangleFillMode fillMode = wireframe ? MTLTriangleFillModeLines : MTLTriangleFillModeFill;
        
        [renderEncoder setTriangleFillMode:fillMode];
        metal_debug_log("set_triangle_fill_mode() - Mode: %s", wireframe ? "Wireframe" : "Solid");
    }
}

HL_PRIM void HL_NAME(set_vertex_buffer)(vdynamic *encoder, vdynamic *buffer, int offset, int index) {
    if (encoder == NULL || buffer == NULL) return;

    @autoreleasepool {
        id<MTLRenderCommandEncoder> renderEncoder = (__bridge id<MTLRenderCommandEncoder>)encoder;
        id<MTLBuffer> metalBuffer = (__bridge id<MTLBuffer>)buffer;

        [renderEncoder setVertexBuffer:metalBuffer offset:offset atIndex:index];
        metal_debug_log("set_vertex_buffer() - SUCCESS (offset=%d, index=%d)", offset, index);
    }
}

HL_PRIM void HL_NAME(set_fragment_texture)(vdynamic *encoder, vdynamic *texture, int index) {
    if (encoder == NULL || texture == NULL) return;

    @autoreleasepool {
        id<MTLRenderCommandEncoder> renderEncoder = (__bridge id<MTLRenderCommandEncoder>)encoder;
        id<MTLTexture> metalTexture = (__bridge id<MTLTexture>)texture;

        [renderEncoder setFragmentTexture:metalTexture atIndex:index];
        metal_debug_log("set_fragment_texture() - SUCCESS (index=%d)", index);
    }
}

HL_PRIM void HL_NAME(set_fragment_buffer)(vdynamic *encoder, vdynamic *buffer, int offset, int index) {
    if (encoder == NULL || buffer == NULL) return;

    @autoreleasepool {
        id<MTLRenderCommandEncoder> renderEncoder = (__bridge id<MTLRenderCommandEncoder>)encoder;
        id<MTLBuffer> metalBuffer = (__bridge id<MTLBuffer>)buffer;

        [renderEncoder setFragmentBuffer:metalBuffer offset:offset atIndex:index];
        metal_debug_log("set_fragment_buffer() - SUCCESS (offset=%d, index=%d)", offset, index);
    }
}

HL_PRIM void HL_NAME(draw_primitives)(vdynamic *encoder, int primitiveType, int vertexStart, int vertexCount) {
    if (encoder == NULL || vertexCount <= 0) return;

    @autoreleasepool {
        id<MTLRenderCommandEncoder> renderEncoder = (__bridge id<MTLRenderCommandEncoder>)encoder;

        MTLPrimitiveType metalPrimitiveType = MTLPrimitiveTypeTriangle;
        switch (primitiveType) {
            case 0: metalPrimitiveType = MTLPrimitiveTypePoint; break;
            case 1: metalPrimitiveType = MTLPrimitiveTypeLine; break;
            case 2: metalPrimitiveType = MTLPrimitiveTypeLineStrip; break;
            case 3: metalPrimitiveType = MTLPrimitiveTypeTriangle; break;
            case 4: metalPrimitiveType = MTLPrimitiveTypeTriangleStrip; break;
        }

        [renderEncoder drawPrimitives:metalPrimitiveType vertexStart:vertexStart vertexCount:vertexCount];
        metal_debug_log("draw_primitives() - SUCCESS (primitiveType=%d, vertexStart=%d, vertexCount=%d)", primitiveType, vertexStart, vertexCount);
    }
}

HL_PRIM void HL_NAME(draw_indexed_primitives)(vdynamic *encoder, int primitiveType, int indexCount, vdynamic *indexBuffer, int indexOffset) {
    if (encoder == NULL || indexBuffer == NULL || indexCount <= 0) return;

    @autoreleasepool {
        id<MTLRenderCommandEncoder> renderEncoder = (__bridge id<MTLRenderCommandEncoder>)encoder;
        id<MTLBuffer> metalIndexBuffer = (__bridge id<MTLBuffer>)indexBuffer;

        MTLPrimitiveType metalPrimitiveType = MTLPrimitiveTypeTriangle;
        switch (primitiveType) {
            case 0: metalPrimitiveType = MTLPrimitiveTypePoint; break;
            case 1: metalPrimitiveType = MTLPrimitiveTypeLine; break;
            case 2: metalPrimitiveType = MTLPrimitiveTypeLineStrip; break;
            case 3: metalPrimitiveType = MTLPrimitiveTypeTriangle; break;
            case 4: metalPrimitiveType = MTLPrimitiveTypeTriangleStrip; break;
        }

        [renderEncoder drawIndexedPrimitives:metalPrimitiveType
                                  indexCount:indexCount
                                   indexType:MTLIndexTypeUInt16
                                 indexBuffer:metalIndexBuffer
                           indexBufferOffset:indexOffset];
        metal_debug_log("draw_indexed_primitives() - SUCCESS (primitiveType=%d, indexCount=%d, indexOffset=%d)", primitiveType, indexCount, indexOffset);
    }
}

HL_PRIM void HL_NAME(end_encoding)(vdynamic *encoder) {
    if (encoder == NULL) return;

    @autoreleasepool {
        id<MTLRenderCommandEncoder> renderEncoder = (__bridge_transfer id<MTLRenderCommandEncoder>)encoder;
        [renderEncoder endEncoding];
        metal_debug_log("end_encoding() - SUCCESS");
    }
}

// Viewport and render state (new functions only)
HL_PRIM void HL_NAME(set_viewport)(vdynamic *encoder, double x, double y, double width, double height) {
    if (encoder == NULL) return;

    @autoreleasepool {
        id<MTLRenderCommandEncoder> renderEncoder = (__bridge id<MTLRenderCommandEncoder>)encoder;

        MTLViewport viewport = {x, y, width, height, 0.0, 1.0};
        [renderEncoder setViewport:viewport];
        metal_debug_log("set_viewport() - SUCCESS (x=%.2f, y=%.2f, width=%.2f, height=%.2f)", x, y, width, height);
    }
}

HL_PRIM void HL_NAME(set_scissor_rect)(vdynamic *encoder, int x, int y, int width, int height) {
    if (encoder == NULL) return;

    @autoreleasepool {
        id<MTLRenderCommandEncoder> renderEncoder = (__bridge id<MTLRenderCommandEncoder>)encoder;

        // Coordinates must be non-negative
        if (x < 0) x = 0;
        if (y < 0) y = 0;

        MTLScissorRect scissor = {(NSUInteger)x, (NSUInteger)y, (NSUInteger)width, (NSUInteger)height};
        [renderEncoder setScissorRect:scissor];
    }
}

// DEFINE_PRIM macros to export ALL functions to Hashlink
DEFINE_PRIM(_DYN, get_device, _NO_ARG);
DEFINE_PRIM(_DYN, create_command_buffer, _NO_ARG);
DEFINE_PRIM(_BOOL, commit_command_buffer, _DYN);
DEFINE_PRIM(_BOOL, commit_without_present, _DYN);
DEFINE_PRIM(_VOID, wait_until_completed, _DYN);

DEFINE_PRIM(_DYN, create_buffer, _I32 _I32);
DEFINE_PRIM(_BOOL, upload_buffer_data, _DYN _BYTES _I32 _I32);

DEFINE_PRIM(_DYN, create_texture, _I32 _I32 _I32 _I32 _BOOL _BOOL);
DEFINE_PRIM(_BOOL, upload_texture_data, _DYN _BYTES _I32 _I32 _I32 _I32);
DEFINE_PRIM(_BOOL, capture_texture_pixels, _DYN _BYTES _I32 _I32 _I32);
DEFINE_PRIM(_VOID, generate_mipmaps, _DYN);
DEFINE_PRIM(_VOID, dispose_texture, _DYN);

DEFINE_PRIM(_DYN, create_sampler_state, _I32 _I32 _I32 _I32 _I32);
DEFINE_PRIM(_VOID, dispose_sampler, _DYN);
DEFINE_PRIM(_VOID, set_fragment_samplers, _DYN _ARR);

DEFINE_PRIM(_DYN, compile_shader, _STRING _I32);
DEFINE_PRIM(_DYN, create_render_pipeline, _DYN _DYN _STRING);
DEFINE_PRIM(_VOID, dispose_pipeline, _DYN);

DEFINE_PRIM(_DYN, begin_render_pass, _DYN _I32 _I32 _I32 _I32);
DEFINE_PRIM(_DYN, resume_render_pass, _DYN);
DEFINE_PRIM(_DYN, begin_texture_render_pass, _DYN _DYN _I32 _I32 _I32 _I32);
DEFINE_PRIM(_VOID, set_render_pipeline_state, _DYN _DYN);
DEFINE_PRIM(_VOID, set_depth_state, _DYN _BOOL _BOOL);
DEFINE_PRIM(_VOID, set_cull_mode, _DYN _I32);
DEFINE_PRIM(_VOID, set_triangle_fill_mode, _DYN _BOOL);
DEFINE_PRIM(_VOID, set_vertex_buffer, _DYN _DYN _I32 _I32);
DEFINE_PRIM(_VOID, set_fragment_texture, _DYN _DYN _I32);
DEFINE_PRIM(_VOID, set_fragment_buffer, _DYN _DYN _I32 _I32);
DEFINE_PRIM(_VOID, draw_primitives, _DYN _I32 _I32 _I32);
DEFINE_PRIM(_VOID, draw_indexed_primitives, _DYN _I32 _I32 _DYN _I32);
DEFINE_PRIM(_VOID, end_encoding, _DYN);

DEFINE_PRIM(_VOID, set_viewport, _DYN _F64 _F64 _F64 _F64);
DEFINE_PRIM(_VOID, set_scissor_rect, _DYN _I32 _I32 _I32 _I32);
