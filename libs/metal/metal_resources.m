#include "metal.h"

// ============================================================================
// Resource management: buffers, textures, samplers
// ============================================================================

vdynamic* metal_create_buffer_impl(int size, int usage) {
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

bool metal_upload_buffer_data_impl(vdynamic *buffer, vbyte *data, int size, int offset) {
    if (buffer == NULL || data == NULL || size <= 0) {
        return false;
    }

    @autoreleasepool {
        id<MTLBuffer> metalBuffer = (__bridge id<MTLBuffer>)buffer;
        
        if (offset + size > metalBuffer.length) {
            return false;
        }

        memcpy((char*)metalBuffer.contents + offset, data, size);
        
        // CRITICAL: Only call didModifyRange for Managed buffers
        // Shared buffers don't need (and don't support) this call
        MTLResourceOptions storageMode = metalBuffer.resourceOptions & MTLResourceStorageModeMask;
        if (storageMode == MTLResourceStorageModeManaged) {
            [metalBuffer didModifyRange:NSMakeRange(offset, size)];
        }
        
        // Log ALL buffer uploads to debug lighting issue
        metal_debug_log("upload_buffer_data() - size=%d, offset=%d", size, offset);

#ifdef METAL_DEBUG
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
        
        // Verify data after upload for fragment parameter buffers (112 bytes = 7 vec4s)
        if (size == 112 && offset == 0) {
            float *floats = (float*)metalBuffer.contents;
            metal_debug_log("=== NATIVE SIDE: Fragment parameter buffer received (112 bytes) ===");
            metal_debug_log("vec4[0] (albedo): [%.6f, %.6f, %.6f, %.6f]", floats[0], floats[1], floats[2], floats[3]);
            metal_debug_log("vec4[1] (metalness): [%.6f, %.6f, %.6f, %.6f]", floats[4], floats[5], floats[6], floats[7]);
            metal_debug_log("vec4[2] (roughness): [%.6f, %.6f, %.6f, %.6f]", floats[8], floats[9], floats[10], floats[11]);
            metal_debug_log("vec4[3] (occlusion): [%.6f, %.6f, %.6f, %.6f]", floats[12], floats[13], floats[14], floats[15]);
            metal_debug_log("vec4[4] (emissive): [%.6f, %.6f, %.6f, %.6f]", floats[16], floats[17], floats[18], floats[19]);
            metal_debug_log("vec4[5] (custom1): [%.6f, %.6f, %.6f, %.6f]", floats[20], floats[21], floats[22], floats[23]);
            metal_debug_log("vec4[6] (custom2): [%.6f, %.6f, %.6f, %.6f]", floats[24], floats[25], floats[26], floats[27]);
            metal_debug_log("=== END FRAGMENT NATIVE VERIFICATION ===");
        }
        
        // Verify data after upload for lighting parameter buffers (80 bytes = 5 vec4s)
        if (size == 80 && offset == 0) {
            float *floats = (float*)metalBuffer.contents;
            metal_debug_log("=== NATIVE SIDE: Lighting parameter buffer received (80 bytes) ===");
            metal_debug_log("vec4[0]: [%.6f, %.6f, %.6f, %.6f]", floats[0], floats[1], floats[2], floats[3]);
            metal_debug_log("vec4[1]: [%.6f, %.6f, %.6f, %.6f]", floats[4], floats[5], floats[6], floats[7]);
            metal_debug_log("vec4[2]: [%.6f, %.6f, %.6f, %.6f]", floats[8], floats[9], floats[10], floats[11]);
            metal_debug_log("vec4[3]: [%.6f, %.6f, %.6f, %.6f]", floats[12], floats[13], floats[14], floats[15]);
            metal_debug_log("vec4[4]: [%.6f, %.6f, %.6f, %.6f]", floats[16], floats[17], floats[18], floats[19]);
            metal_debug_log("=== END LIGHTING NATIVE VERIFICATION ===");
        }
#endif // METAL_DEBUG
        
        return true;
    }
}

vdynamic* metal_create_texture_impl(int width, int height, int format, int usage, bool mipmapped, bool isCube, int arrayLength) {
    if (ctx == NULL || ctx->device == NULL || width <= 0 || height <= 0) return NULL;

    @autoreleasepool {
        id<MTLDevice> device = (__bridge id<MTLDevice>)ctx->device;

MTLTextureDescriptor *descriptor;
if (isCube) {
    descriptor = [MTLTextureDescriptor textureCubeDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                        size:width
                                                                   mipmapped:mipmapped];
} else if (arrayLength > 1) {
    // Texture array
    descriptor = [[MTLTextureDescriptor alloc] init];
    descriptor.textureType = MTLTextureType2DArray;
    descriptor.pixelFormat = MTLPixelFormatRGBA8Unorm;
    descriptor.width = width;
    descriptor.height = height;
    descriptor.arrayLength = arrayLength;
    descriptor.mipmapLevelCount = mipmapped ? 1 + floor(log2(fmax(width, height))) : 1;
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
            case 7: descriptor.pixelFormat = MTLPixelFormatDepth16Unorm; break;  // Depth16 (legacy)
            case 8: descriptor.pixelFormat = MTLPixelFormatDepth32Float; break;  // Depth24 -> Depth32Float (Apple Silicon doesn't support Depth24)
            case 9: descriptor.pixelFormat = MTLPixelFormatDepth32Float; break;  // Depth24Stencil8 -> Depth32Float (Apple Silicon doesn't support Depth24)
            case 10: descriptor.pixelFormat = MTLPixelFormatDepth32Float; break;  // Depth32 (NEW: depth2d<float>)
            case 11: descriptor.pixelFormat = MTLPixelFormatR16Float; break;
            case 12: descriptor.pixelFormat = MTLPixelFormatR32Float; break;
            case 13: descriptor.pixelFormat = MTLPixelFormatRG16Float; break;
            case 14: descriptor.pixelFormat = MTLPixelFormatRG32Float; break;
            case 15: descriptor.pixelFormat = MTLPixelFormatRGBA16Float; break; // RGB16F -> RGBA16F
            case 16: descriptor.pixelFormat = MTLPixelFormatRGBA32Float; break; // RGB32F -> RGBA32F
            case 17: descriptor.pixelFormat = MTLPixelFormatRGBA8Unorm_sRGB; break; // SRGB -> RGBA8Unorm_sRGB
            case 18: descriptor.pixelFormat = MTLPixelFormatRGBA8Unorm_sRGB; break; // SRGB_ALPHA
            case 19: descriptor.pixelFormat = MTLPixelFormatRGB10A2Unorm; break;
            case 20: descriptor.pixelFormat = MTLPixelFormatRG11B10Float; break;
            case 21: descriptor.pixelFormat = MTLPixelFormatR16Unorm; break;
            case 22: descriptor.pixelFormat = MTLPixelFormatRG16Unorm; break;
            case 23: descriptor.pixelFormat = MTLPixelFormatRGBA16Unorm; break; // RGB16U -> RGBA16U
            case 24: descriptor.pixelFormat = MTLPixelFormatRGBA16Unorm; break;
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

bool metal_upload_texture_data_impl(vdynamic *texture, vbyte *data, int width, int height, int level, int slice) {
    if (texture == NULL || data == NULL || width <= 0 || height <= 0) return false;

    @autoreleasepool {
        id<MTLTexture> metalTexture = (__bridge id<MTLTexture>)texture;
        
        // Calculate bytes per pixel based on actual texture pixel format
        NSUInteger bytesPerPixel = 4;  // Default to RGBA8
        MTLPixelFormat pixelFormat = [metalTexture pixelFormat];
        switch (pixelFormat) {
            case MTLPixelFormatRGBA8Unorm:
            case MTLPixelFormatRGBA8Unorm_sRGB:
            case MTLPixelFormatBGRA8Unorm:
            case MTLPixelFormatRGB10A2Unorm:
                bytesPerPixel = 4;
                break;
            case MTLPixelFormatRG8Unorm:
                bytesPerPixel = 2;
                break;
            case MTLPixelFormatR8Unorm:
                bytesPerPixel = 1;
                break;
            case MTLPixelFormatRGBA16Float:
            case MTLPixelFormatRG16Float:
                bytesPerPixel = 8;
                break;
            case MTLPixelFormatRGBA32Float:
            case MTLPixelFormatRG32Float:
                bytesPerPixel = 16;
                break;
            case MTLPixelFormatR16Float:
                bytesPerPixel = 2;
                break;
            case MTLPixelFormatR32Float:
                bytesPerPixel = 4;
                break;
            case MTLPixelFormatRGB9E5Float:
                bytesPerPixel = 4;
                break;
            case MTLPixelFormatRG11B10Float:
                bytesPerPixel = 4;
                break;
            default:
                bytesPerPixel = 4;  // Conservative default
        }
        
        MTLRegion region = MTLRegionMake2D(0, 0, width, height);
        NSUInteger bytesPerRow = width * bytesPerPixel;

        [metalTexture replaceRegion:region
                        mipmapLevel:level
                              slice:slice
                          withBytes:data
                        bytesPerRow:bytesPerRow
                      bytesPerImage:0];

        return true;
    }
}

bool metal_capture_texture_pixels_impl(vdynamic *texture, vbyte *data, int width, int height, int level) {
    if (texture == NULL || data == NULL || width <= 0 || height <= 0) {
        metal_debug_log("ERROR: capture_texture_pixels() - invalid parameters");
        return false;
    }

    @autoreleasepool {
        id<MTLTexture> metalTexture = (__bridge id<MTLTexture>)texture;
        MTLPixelFormat pixelFormat = [metalTexture pixelFormat];

        MTLRegion region = MTLRegionMake2D(0, 0, width, height);
        // Calculate bytes per row based on actual pixel format
        NSUInteger bytesPerPixel;
        switch (pixelFormat) {
            case MTLPixelFormatR8Unorm:
                bytesPerPixel = 1;
                break;
            case MTLPixelFormatRG8Unorm:
            case MTLPixelFormatR16Float:
            case MTLPixelFormatR16Unorm:
            case MTLPixelFormatDepth16Unorm:
                bytesPerPixel = 2;
                break;
            case MTLPixelFormatRGBA8Unorm:
            case MTLPixelFormatBGRA8Unorm:
            case MTLPixelFormatRGBA8Unorm_sRGB:
            case MTLPixelFormatRGB10A2Unorm:
            case MTLPixelFormatRG11B10Float:
            case MTLPixelFormatRG16Float:
            case MTLPixelFormatRG16Unorm:
            case MTLPixelFormatR32Float:
            case MTLPixelFormatDepth24Unorm_Stencil8:
                bytesPerPixel = 4;
                break;
            case MTLPixelFormatRGBA16Float:
            case MTLPixelFormatRGBA16Unorm:
            case MTLPixelFormatRG32Float:
                bytesPerPixel = 8;
                break;
            case MTLPixelFormatRGBA32Float:
                bytesPerPixel = 16;
                break;
            case MTLPixelFormatDepth32Float:
            case MTLPixelFormatDepth32Float_Stencil8:
                // Depth textures can't be directly read - this will fail
                metal_debug_log("ERROR: capture_texture_pixels() - cannot read depth texture directly");
                return false;
            default:
                metal_debug_log("ERROR: capture_texture_pixels() - unsupported pixel format %lu", (unsigned long)pixelFormat);
                return false;
        }

        NSUInteger bytesPerRow = width * bytesPerPixel;

        // Read pixels from texture to buffer
        [metalTexture getBytes:data
                   bytesPerRow:bytesPerRow
                    fromRegion:region
                   mipmapLevel:level];

        metal_debug_log("capture_texture_pixels() - SUCCESS (width=%d, height=%d, level=%d)", width, height, level);
        return true;
    }
}

void metal_generate_mipmaps_impl(vdynamic *texture) {
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

void metal_dispose_buffer_impl(vdynamic *buffer) {
    if (buffer == NULL) return;

    @autoreleasepool {
        id<MTLBuffer> metalBuffer = (__bridge_transfer id<MTLBuffer>)buffer;
        (void)metalBuffer; // ARC will handle release
    }
}

void metal_dispose_texture_impl(vdynamic *texture) {
    if (texture == NULL) return;

    @autoreleasepool {
        id<MTLTexture> metalTexture = (__bridge_transfer id<MTLTexture>)texture;
        (void)metalTexture; // ARC will handle release
    }
}

vdynamic* metal_create_sampler_state_impl(int minFilter, int magFilter, int mipFilter, int wrapS, int wrapT) {
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

void metal_dispose_sampler_impl(vdynamic *sampler) {
    if (sampler == NULL) return;

    @autoreleasepool {
        id<MTLSamplerState> samplerState = (__bridge_transfer id<MTLSamplerState>)sampler;
        (void)samplerState; // ARC will handle release
    }
}

void metal_set_fragment_samplers_impl(vdynamic *encoder, varray *samplers) {
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

void metal_set_fragment_sampler_impl(vdynamic *encoder, vdynamic *sampler, int index) {
    if (encoder == NULL || sampler == NULL) return;

    @autoreleasepool {
        id<MTLRenderCommandEncoder> renderEncoder = (__bridge id<MTLRenderCommandEncoder>)encoder;
        id<MTLSamplerState> samplerState = (__bridge id<MTLSamplerState>)sampler;
        [renderEncoder setFragmentSamplerState:samplerState atIndex:index];
    }
}
