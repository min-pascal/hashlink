#include "metal.h"

// ============================================================================
// Render pass and encoding functions
// ============================================================================

vdynamic* metal_begin_render_pass_impl(vdynamic *cmdBuffer, int r, int g, int b, int a) {
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

        // Set pixel format to backbuffer format (BGRA8Unorm)
        ctx->currentTargetPixelFormat = (int)MTLPixelFormatBGRA8Unorm;
        ctx->currentMRTCount = 0;  // Backbuffer is single target, not MRT

        // CRITICAL: Clear lastMRTCount at the start of a new frame (when clearing backbuffer)
        // This ensures MRT textures from the previous frame don't leak into the new frame
        ctx->lastMRTCount = 0;
        for (int i = 0; i < 8; i++) {
            if (ctx->lastMRTTextures[i] != NULL) {
                // Release the retained texture reference
                id<MTLTexture> tex = (__bridge_transfer id<MTLTexture>)ctx->lastMRTTextures[i];
                (void)tex; // ARC will release
                ctx->lastMRTTextures[i] = NULL;
            }
        }
        ctx->lastMRTDepthTexture = NULL;

        // Backbuffer rendering always has depth buffer attached
        ctx->hasDepthBuffer = true;

        MTLRenderPassDescriptor *renderPassDescriptor = [MTLRenderPassDescriptor renderPassDescriptor];
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture;
        renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
        renderPassDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(r/255.0, g/255.0, b/255.0, a/255.0);

        // CRITICAL: Attach depth-stencil texture for depth and stencil testing to work!
        if (ctx->depthTexture != NULL) {
            id<MTLTexture> depthTexture = (__bridge id<MTLTexture>)ctx->depthTexture;
            renderPassDescriptor.depthAttachment.texture = depthTexture;
            renderPassDescriptor.depthAttachment.loadAction = MTLLoadActionClear;
            renderPassDescriptor.depthAttachment.storeAction = MTLStoreActionStore;  // MUST Store to preserve depth between passes
            renderPassDescriptor.depthAttachment.clearDepth = 1.0;

            // Attach stencil (using the same texture as depth since we use combined depth-stencil format)
            renderPassDescriptor.stencilAttachment.texture = depthTexture;
            renderPassDescriptor.stencilAttachment.loadAction = MTLLoadActionClear;
            renderPassDescriptor.stencilAttachment.storeAction = MTLStoreActionStore;  // MUST Store to preserve stencil between passes!
            renderPassDescriptor.stencilAttachment.clearStencil = 0;

            metal_debug_log("begin_render_pass() - Stencil attachment configured (clear=0)");

            metal_debug_log("begin_render_pass() - Depth-stencil texture attached: %p", depthTexture);
        } else {
            metal_debug_log("begin_render_pass() - WARNING: No depth-stencil texture!");
        }

        id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
        if (encoder == NULL) return NULL;

        // Set winding order to counter-clockwise (Heaps/OpenGL convention)
        [encoder setFrontFacingWinding:MTLWindingClockwise];

        metal_debug_log("begin_render_pass() - SUCCESS");
        return (vdynamic*)(__bridge_retained void*)encoder;
    }
}

vdynamic* metal_resume_render_pass_impl(vdynamic *cmdBuffer) {
    metal_debug_log("resume_render_pass called");
    if (ctx == NULL || cmdBuffer == NULL) {
        metal_debug_log("ERROR: resume_render_pass() - ctx=%p cmdBuffer=%p", ctx, cmdBuffer);
        metal_log_error("resume_render_pass: ctx or cmdBuffer is NULL");
        return NULL;
    }
    
    if (ctx->currentDrawable == NULL) {
        metal_debug_log("resume_render_pass: no currentDrawable - caller should fall back to begin_render_pass");
        return NULL;
    }
    
    metal_debug_log("resume_render_pass: lastMRTCount=%d", ctx->lastMRTCount);

    @autoreleasepool {
        id<MTLCommandBuffer> commandBuffer = (__bridge id<MTLCommandBuffer>)cmdBuffer;
        id<CAMetalDrawable> drawable = (__bridge id<CAMetalDrawable>)ctx->currentDrawable;
        
        metal_debug_log("resume_render_pass() - drawable=%p texture=%p", drawable, drawable.texture);
        
        // Update command buffer reference
        ctx->currentCommandBuffer = (__bridge void*)commandBuffer;
        
        // CRITICAL: Reset target format and MRT count for backbuffer
        ctx->currentTargetPixelFormat = (int)MTLPixelFormatBGRA8Unorm;
        ctx->currentMRTCount = 0;  // Backbuffer is single target, not MRT
        ctx->hasDepthBuffer = true;  // Backbuffer has depth buffer

        MTLRenderPassDescriptor *renderPassDescriptor = [MTLRenderPassDescriptor renderPassDescriptor];
        renderPassDescriptor.colorAttachments[0].texture = drawable.texture;
        renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionLoad;  // LOAD existing content!
        renderPassDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;

        // CRITICAL: Attach depth-stencil texture for depth and stencil testing to work!
        if (ctx->depthTexture != NULL) {
            id<MTLTexture> depthTexture = (__bridge id<MTLTexture>)ctx->depthTexture;
            renderPassDescriptor.depthAttachment.texture = depthTexture;
            renderPassDescriptor.depthAttachment.loadAction = MTLLoadActionLoad;  // Load existing depth
            renderPassDescriptor.depthAttachment.storeAction = MTLStoreActionStore;

            // CRITICAL: Also load the stencil attachment to preserve stencil buffer between passes!
            renderPassDescriptor.stencilAttachment.texture = depthTexture;
            renderPassDescriptor.stencilAttachment.loadAction = MTLLoadActionLoad;  // Load existing stencil
            renderPassDescriptor.stencilAttachment.storeAction = MTLStoreActionStore;
        }

        id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
        if (encoder == NULL) {
            metal_debug_log("ERROR: resume_render_pass() - failed to create encoder!");
            return NULL;
        }

        // Set winding order to counter-clockwise (Heaps/OpenGL convention)
        [encoder setFrontFacingWinding:MTLWindingClockwise];
        
        // CRITICAL FIX: Declare G-Buffer/MRT textures as resources for the lighting pass
        // This ensures Metal properly synchronizes texture data from the previous G-Buffer pass
        // Without this, the lighting shader may receive invalid/uninitialized texture data
        metal_debug_log("resume_render_pass: About to declare %d MRT resources", ctx->lastMRTCount);
        if (ctx->lastMRTCount > 0) {
            metal_debug_log("resume_render_pass: Declaring MRT textures...");
            for (int i = 0; i < ctx->lastMRTCount; i++) {
                if (ctx->lastMRTTextures[i] != NULL) {
                    id<MTLTexture> gBufferTex = (__bridge id<MTLTexture>)ctx->lastMRTTextures[i];
                    [encoder useResource:gBufferTex usage:MTLResourceUsageRead stages:MTLRenderStageFragment];
                    metal_debug_log("resume_render_pass: useResource called for MRT[%d]", i);
                } else {
                    metal_log_warning("resume_render_pass: MRT[%d] is NULL!", i);
                }
            }
            // Also declare depth buffer if available
            if (ctx->lastMRTDepthTexture != NULL) {
                id<MTLTexture> depthTex = (__bridge id<MTLTexture>)ctx->lastMRTDepthTexture;
                [encoder useResource:depthTex usage:MTLResourceUsageRead stages:MTLRenderStageFragment];
                metal_debug_log("resume_render_pass: useResource called for depth texture");
            }
        } else {
            metal_log_warning("resume_render_pass: WARNING - lastMRTCount is 0!");
        }

        metal_debug_log("resume_render_pass() - SUCCESS");
        return (vdynamic*)(__bridge_retained void*)encoder;
    }
}

vdynamic* metal_begin_texture_render_pass_impl(vdynamic *cmdBuffer, vdynamic *texture, int r, int g, int b, int a, vdynamic *depthTexParam, int layer, int mipLevel, int depthAction) {
    if (ctx == NULL || cmdBuffer == NULL || texture == NULL) {
        metal_debug_log("ERROR: begin_texture_render_pass() - invalid parameters");
        return NULL;
    }

    @autoreleasepool {
        id<MTLCommandBuffer> commandBuffer = (__bridge id<MTLCommandBuffer>)cmdBuffer;
        id<MTLTexture> metalTexture = (__bridge id<MTLTexture>)texture;
        
        // Update command buffer reference
        ctx->currentCommandBuffer = (__bridge void*)commandBuffer;

        // Check if this is a depth texture (for shadow maps)
        MTLPixelFormat pixelFormat = [metalTexture pixelFormat];
        BOOL isDepthTexture = (pixelFormat == MTLPixelFormatDepth16Unorm ||
                               pixelFormat == MTLPixelFormatDepth32Float ||
                               pixelFormat == MTLPixelFormatDepth32Float_Stencil8 ||
                               pixelFormat == MTLPixelFormatDepth24Unorm_Stencil8);

        // Store texture format and MRT count for pipeline creation
        ctx->currentTargetPixelFormat = (int)pixelFormat;
        ctx->currentMRTCount = 0;  // Single render target (not MRT)

        MTLRenderPassDescriptor *renderPassDescriptor = [MTLRenderPassDescriptor renderPassDescriptor];

        if (isDepthTexture) {
            // Depth-only render pass for shadow maps (NO color attachment!)
            metal_debug_log("begin_texture_render_pass() - Creating DEPTH-ONLY pass for shadow map");

            renderPassDescriptor.depthAttachment.texture = metalTexture;
            if (a < 0) {
                renderPassDescriptor.depthAttachment.loadAction = MTLLoadActionLoad;
            } else {
                renderPassDescriptor.depthAttachment.loadAction = MTLLoadActionClear;
                renderPassDescriptor.depthAttachment.clearDepth = 1.0;
            }
            renderPassDescriptor.depthAttachment.storeAction = MTLStoreActionStore;

            // Handle stencil component if present
            if (pixelFormat == MTLPixelFormatDepth32Float_Stencil8 ||
                pixelFormat == MTLPixelFormatDepth24Unorm_Stencil8) {
                renderPassDescriptor.stencilAttachment.texture = metalTexture;
                if (a < 0) {
                    renderPassDescriptor.stencilAttachment.loadAction = MTLLoadActionLoad;
                } else {
                    renderPassDescriptor.stencilAttachment.loadAction = MTLLoadActionClear;
                    renderPassDescriptor.stencilAttachment.clearStencil = 0;
                }
                renderPassDescriptor.stencilAttachment.storeAction = MTLStoreActionStore;
            }
        } else {
            // Color render pass
            // For cube maps or texture arrays, set the slice (layer)
            // For mipmapped textures, set the mip level
            renderPassDescriptor.colorAttachments[0].texture = metalTexture;
            renderPassDescriptor.colorAttachments[0].slice = layer;
            renderPassDescriptor.colorAttachments[0].level = mipLevel;

            // If alpha is negative, use Load action to preserve existing content (additive rendering)
            // Otherwise use Clear action
            if (a < 0) {
                renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionLoad;
            } else {
                renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
                renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(r/255.0, g/255.0, b/255.0, a/255.0);
            }

            renderPassDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;

            // Only attach ctx->depthTexture if it matches the target texture size
            // Otherwise Metal will clip rendering to the smaller of the two sizes!
            if (ctx->depthTexture != NULL) {
                id<MTLTexture> depthTexture = (__bridge id<MTLTexture>)ctx->depthTexture;
                
                // Check if depth texture matches target size
                if (depthTexture.width == metalTexture.width && depthTexture.height == metalTexture.height) {
                    renderPassDescriptor.depthAttachment.texture = depthTexture;
                    // depthAction: 0=Load (preserve), 1=Clear, -1=DontCare
                    if (depthAction == 0) {
                        renderPassDescriptor.depthAttachment.loadAction = MTLLoadActionLoad;
                    } else if (depthAction == 1) {
                        renderPassDescriptor.depthAttachment.loadAction = MTLLoadActionClear;
                        renderPassDescriptor.depthAttachment.clearDepth = 1.0;
                    } else {
                        renderPassDescriptor.depthAttachment.loadAction = MTLLoadActionDontCare;
                    }
                    renderPassDescriptor.depthAttachment.storeAction = MTLStoreActionStore;

                    // CRITICAL: Also attach stencil to preserve stencil buffer
                    renderPassDescriptor.stencilAttachment.texture = depthTexture;
                    if (depthAction == 0) {
                        renderPassDescriptor.stencilAttachment.loadAction = MTLLoadActionLoad;
                    } else if (depthAction == 1) {
                        renderPassDescriptor.stencilAttachment.loadAction = MTLLoadActionClear;
                        renderPassDescriptor.stencilAttachment.clearStencil = 0;
                    } else {
                        renderPassDescriptor.stencilAttachment.loadAction = MTLLoadActionDontCare;
                    }
                    renderPassDescriptor.stencilAttachment.storeAction = MTLStoreActionStore;
                }
            }
        }

        id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
        if (encoder == NULL) {
            metal_debug_log("ERROR: begin_texture_render_pass() - failed to create encoder!");
            return NULL;
        }

        // Set winding order to counter-clockwise (Heaps/OpenGL convention)
        [encoder setFrontFacingWinding:MTLWindingClockwise];

        // CRITICAL: Declare G-Buffer/MRT textures as resources for the lighting pass
        // This ensures Metal properly synchronizes texture data from the previous G-Buffer pass
        if (ctx->lastMRTCount > 0) {
            for (int i = 0; i < ctx->lastMRTCount && i < 8; i++) {
                if (ctx->lastMRTTextures[i] != NULL) {
                    id<MTLTexture> gBufferTex = (__bridge id<MTLTexture>)ctx->lastMRTTextures[i];
                    [encoder useResource:gBufferTex usage:MTLResourceUsageRead stages:MTLRenderStageFragment];
                }
            }
        }

        // CRITICAL: Set initial viewport and scissor for depth-only passes
        if (isDepthTexture) {
            MTLViewport viewport = {0, 0, (double)metalTexture.width, (double)metalTexture.height, 0.0, 1.0};
            [encoder setViewport:viewport];
            MTLScissorRect scissor = {0, 0, metalTexture.width, metalTexture.height};
            [encoder setScissorRect:scissor];
            metal_debug_log("NATIVE: Initial viewport for depth: %lu x %lu", (unsigned long)metalTexture.width, (unsigned long)metalTexture.height);
        }

        metal_debug_log("begin_texture_render_pass() - SUCCESS");
        return (vdynamic*)(__bridge_retained void*)encoder;
    }
}

vdynamic* metal_begin_mrt_render_pass_impl(vdynamic *cmdBuffer, varray *textures, int r, int g, int b, int a, vdynamic *depthTex) {
    if (ctx == NULL || cmdBuffer == NULL || textures == NULL) return NULL;
    
    @autoreleasepool {
        id<MTLCommandBuffer> commandBuffer = (__bridge id<MTLCommandBuffer>)cmdBuffer;
        
        // Update command buffer reference
        ctx->currentCommandBuffer = (__bridge void*)commandBuffer;
        
        int texCount = textures->size;
        if (texCount == 0) return NULL;
        
        MTLRenderPassDescriptor *renderPassDescriptor = [MTLRenderPassDescriptor renderPassDescriptor];
        
        vdynamic **texPtrs = hl_aptr(textures, vdynamic*);
        id<MTLTexture> firstTexture = nil;
        
        // Set up each color attachment and store their pixel formats
        // CRITICAL: MRT requires per-attachment pixel format tracking for correct pipeline creation
        for (int i = 0; i < texCount; i++) {
            if (texPtrs[i] == NULL) {
                ctx->currentMRTPixelFormats[i] = (int)MTLPixelFormatBGRA8Unorm; // default
                continue;
            }
            
            id<MTLTexture> metalTexture = (__bridge id<MTLTexture>)texPtrs[i];
            if (i == 0) firstTexture = metalTexture;
            
            // Store the pixel format for this attachment
            ctx->currentMRTPixelFormats[i] = (int)metalTexture.pixelFormat;
            
            renderPassDescriptor.colorAttachments[i].texture = metalTexture;
            
            if (a < 0) {
                renderPassDescriptor.colorAttachments[i].loadAction = MTLLoadActionLoad;
            } else {
                renderPassDescriptor.colorAttachments[i].loadAction = MTLLoadActionClear;
                renderPassDescriptor.colorAttachments[i].clearColor = MTLClearColorMake(r/255.0, g/255.0, b/255.0, a/255.0);
            }
            renderPassDescriptor.colorAttachments[i].storeAction = MTLStoreActionStore;
            
            metal_debug_log("MRT attachment %d: format=%d (%s)", i, (int)metalTexture.pixelFormat,
                metalTexture.pixelFormat == MTLPixelFormatRGBA16Float ? "RGBA16F" :
                metalTexture.pixelFormat == MTLPixelFormatRGBA8Unorm ? "RGBA8" :
                metalTexture.pixelFormat == MTLPixelFormatR32Float ? "R32F" :
                metalTexture.pixelFormat == MTLPixelFormatBGRA8Unorm ? "BGRA8" : "other");
        }
        
        // Attach depth buffer: prefer caller-supplied depth texture, fall back to ctx->depthTexture
        void *depthTexSource = (depthTex != NULL) ? (void*)depthTex : ctx->depthTexture;
        if (depthTexSource != NULL && firstTexture != nil) {
            id<MTLTexture> depthTexture = (__bridge id<MTLTexture>)depthTexSource;
            
            if (depthTexture.width == firstTexture.width && depthTexture.height == firstTexture.height) {
                renderPassDescriptor.depthAttachment.texture = depthTexture;
                if (a < 0) {
                    renderPassDescriptor.depthAttachment.loadAction = MTLLoadActionLoad;
                } else {
                    renderPassDescriptor.depthAttachment.loadAction = MTLLoadActionClear;
                    renderPassDescriptor.depthAttachment.clearDepth = 1.0;
                }
                renderPassDescriptor.depthAttachment.storeAction = MTLStoreActionStore;
                
                renderPassDescriptor.stencilAttachment.texture = depthTexture;
                if (a < 0) {
                    renderPassDescriptor.stencilAttachment.loadAction = MTLLoadActionLoad;
                } else {
                    renderPassDescriptor.stencilAttachment.loadAction = MTLLoadActionClear;
                    renderPassDescriptor.stencilAttachment.clearStencil = 0;
                }
                renderPassDescriptor.stencilAttachment.storeAction = MTLStoreActionStore;
                
                // CRITICAL: Set hasDepthBuffer so pipeline is created with correct depth format
                ctx->hasDepthBuffer = true;
            }
        } else {
            // No depth buffer for this MRT pass
            ctx->hasDepthBuffer = false;
        }
        
        // Store MRT count and pixel format for pipeline creation
        ctx->currentMRTCount = texCount;
        if (firstTexture != nil) {
            ctx->currentTargetPixelFormat = (int)firstTexture.pixelFormat;
        }
        
        // CRITICAL: Store MRT textures for resource synchronization in next pass
        // This allows the lighting pass to read from the G-Buffers written here
        ctx->lastMRTCount = texCount;
        
        // Store MRT textures (only log in verbose mode)
        for (int i = 0; i < texCount; i++) {
            if (texPtrs[i] != NULL) {
                id<MTLTexture> metalTexture = (__bridge id<MTLTexture>)texPtrs[i];
                ctx->lastMRTTextures[i] = (__bridge_retained void*)metalTexture;
                metal_debug_log("MRT[%d] STORED: ptr=%p dim=%lux%u", 
                    i, metalTexture, (unsigned long)metalTexture.width, (unsigned)metalTexture.height);
            } else {
                ctx->lastMRTTextures[i] = NULL;
            }
        }
        metal_debug_log("MRT_STORAGE_COMPLETE: ctx->lastMRTCount=%d", ctx->lastMRTCount);
        
        // Store depth texture reference if available
        if (ctx->depthTexture != NULL) {
            ctx->lastMRTDepthTexture = ctx->depthTexture;
        }
        
        id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
        if (encoder == NULL) {
            metal_debug_log("ERROR: begin_mrt_render_pass() - failed to create encoder!");
            return NULL;
        }
        
        // Set winding order
        [encoder setFrontFacingWinding:MTLWindingClockwise];
        
        // Set viewport based on first texture
        if (firstTexture != nil) {
            MTLViewport viewport = {0, 0, (double)firstTexture.width, (double)firstTexture.height, 0.0, 1.0};
            [encoder setViewport:viewport];
            MTLScissorRect scissor = {0, 0, firstTexture.width, firstTexture.height};
            [encoder setScissorRect:scissor];
        }
        
        metal_debug_log("begin_mrt_render_pass() - SUCCESS with %d targets", texCount);
        return (vdynamic*)(__bridge_retained void*)encoder;
    }
}

vdynamic* metal_begin_depth_render_pass_impl(vdynamic *cmdBuffer, vdynamic *depthTexture, double clearDepth) {
    if (ctx == NULL || cmdBuffer == NULL || depthTexture == NULL) {
        metal_debug_log("ERROR: begin_depth_render_pass() - invalid parameters");
        return NULL;
    }

    @autoreleasepool {
        id<MTLCommandBuffer> commandBuffer = (__bridge id<MTLCommandBuffer>)cmdBuffer;
        id<MTLTexture> metalDepthTexture = (__bridge id<MTLTexture>)depthTexture;

        // Update command buffer reference
        ctx->currentCommandBuffer = (__bridge void*)commandBuffer;

        // Create render pass descriptor with ONLY depth attachment (no color)
        MTLRenderPassDescriptor *renderPassDescriptor = [MTLRenderPassDescriptor new];

        // Attach depth texture
        renderPassDescriptor.depthAttachment.texture = metalDepthTexture;
        renderPassDescriptor.depthAttachment.loadAction = MTLLoadActionClear;
        renderPassDescriptor.depthAttachment.storeAction = MTLStoreActionStore;
        renderPassDescriptor.depthAttachment.clearDepth = clearDepth;

        // NO color attachments for depth-only rendering (shadow pass)

        id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];
        if (encoder == NULL) {
            metal_debug_log("ERROR: begin_depth_render_pass() - failed to create encoder!");
            return NULL;
        }

        // Set winding order to counter-clockwise (Heaps/OpenGL convention)
        [encoder setFrontFacingWinding:MTLWindingClockwise];

        metal_debug_log("begin_depth_render_pass() - SUCCESS");
        return (vdynamic*)(__bridge_retained void*)encoder;
    }
}

void metal_set_render_pipeline_state_impl(vdynamic *encoder, vdynamic *pipeline) {
    if (encoder == NULL || pipeline == NULL) return;

    @autoreleasepool {
        id<MTLRenderCommandEncoder> renderEncoder = (__bridge id<MTLRenderCommandEncoder>)encoder;
        id<MTLRenderPipelineState> pipelineState = (__bridge id<MTLRenderPipelineState>)pipeline;

        [renderEncoder setRenderPipelineState:pipelineState];
        
        // Note: Depth state is now set separately via set_depth_state()
        metal_debug_log("set_render_pipeline_state() - SUCCESS");
    }
}

void metal_set_depth_state_impl(vdynamic *encoder, bool depthTest, bool depthWrite) {
    if (encoder == NULL || ctx == NULL) return;

    @autoreleasepool {
        id<MTLRenderCommandEncoder> renderEncoder = (__bridge id<MTLRenderCommandEncoder>)encoder;
        id<MTLDevice> device = (__bridge id<MTLDevice>)ctx->device;

        // Lazily initialise cache if needed
        if (ctx->depthStencilStateCache == NULL) {
            NSMutableDictionary *cache = [[NSMutableDictionary alloc] init];
            ctx->depthStencilStateCache = (__bridge_retained void*)cache;
        }
        NSMutableDictionary *cache = (__bridge NSMutableDictionary*)ctx->depthStencilStateCache;

        // Build cache key from depthTest and depthWrite
        NSString *cacheKey = [NSString stringWithFormat:@"%d-%d", depthTest ? 1 : 0, depthWrite ? 1 : 0];

        id<MTLDepthStencilState> depthState = cache[cacheKey];

        if (depthState == nil) {
            MTLDepthStencilDescriptor *descriptor = [[MTLDepthStencilDescriptor alloc] init];
            descriptor.depthCompareFunction = depthTest ? MTLCompareFunctionLessEqual : MTLCompareFunctionAlways;
            descriptor.depthWriteEnabled = depthWrite;

            depthState = [device newDepthStencilStateWithDescriptor:descriptor];
            if (depthState) {
                cache[cacheKey] = depthState;
                metal_debug_log("set_depth_state() - Created and cached state (test=%d, write=%d)", depthTest, depthWrite);
            }
        }

        if (depthState) {
            [renderEncoder setDepthStencilState:depthState];
        }
    }
}

void metal_set_stencil_state_impl(vdynamic *encoder, int depthCompareFunc, bool depthWrite,
    int frontFunc, int frontSTfail, int frontDPfail, int frontPass,
    int backFunc, int backSTfail, int backDPfail, int backPass,
    int reference, int readMask, int writeMask) {

    if (encoder == NULL || ctx == NULL) return;

    @autoreleasepool {
        id<MTLRenderCommandEncoder> renderEncoder = (__bridge id<MTLRenderCommandEncoder>)encoder;
        id<MTLDevice> device = (__bridge id<MTLDevice>)ctx->device;

        // Lazily initialise cache if needed
        if (ctx->depthStencilStateCache == NULL) {
            NSMutableDictionary *cache = [[NSMutableDictionary alloc] init];
            ctx->depthStencilStateCache = (__bridge_retained void*)cache;
        }
        NSMutableDictionary *cache = (__bridge NSMutableDictionary*)ctx->depthStencilStateCache;

        // Create cache key from all parameters
        // Format: "depthFunc-depthWrite-frontFunc-frontFail-frontDepthFail-frontPass-backFunc-backFail-backDepthFail-backPass-readMask-writeMask"
        NSString *cacheKey = [NSString stringWithFormat:@"%d-%d-%d-%d-%d-%d-%d-%d-%d-%d-%d-%d",
            depthCompareFunc, depthWrite ? 1 : 0,
            frontFunc, frontSTfail, frontDPfail, frontPass,
            backFunc, backSTfail, backDPfail, backPass,
            readMask, writeMask];

        // Check if state exists in cache
        id<MTLDepthStencilState> depthStencilState = cache[cacheKey];
        
        if (depthStencilState == nil) {
            // State not cached - create new one
            MTLDepthStencilDescriptor *descriptor = [[MTLDepthStencilDescriptor alloc] init];

            // Map Heaps Compare enum to Metal compare function
            // Compare enum: Always=0, Never=1, Equal=2, NotEqual=3, Greater=4, GreaterEqual=5, Less=6, LessEqual=7
            MTLCompareFunction compareFuncs[] = {
                MTLCompareFunctionAlways,      // 0: Always
                MTLCompareFunctionNever,       // 1: Never
                MTLCompareFunctionEqual,       // 2: Equal
                MTLCompareFunctionNotEqual,    // 3: NotEqual
                MTLCompareFunctionGreater,     // 4: Greater
                MTLCompareFunctionGreaterEqual,// 5: GreaterEqual
                MTLCompareFunctionLess,        // 6: Less
                MTLCompareFunctionLessEqual    // 7: LessEqual
            };

            // Set depth compare function from the parameter
            descriptor.depthCompareFunction = compareFuncs[depthCompareFunc];
            descriptor.depthWriteEnabled = depthWrite ? YES : NO;

            // Map Heaps StencilOp enum to Metal stencil operation
            // StencilOp enum: Keep=0, Zero=1, Replace=2, Increment=3, IncrementWrap=4, Decrement=5, DecrementWrap=6, Invert=7
            MTLStencilOperation stencilOps[] = {
                MTLStencilOperationKeep,           // 0: Keep
                MTLStencilOperationZero,           // 1: Zero
                MTLStencilOperationReplace,        // 2: Replace
                MTLStencilOperationIncrementClamp, // 3: Increment
                MTLStencilOperationIncrementWrap,  // 4: IncrementWrap
                MTLStencilOperationDecrementClamp, // 5: Decrement
                MTLStencilOperationDecrementWrap,  // 6: DecrementWrap
                MTLStencilOperationInvert          // 7: Invert
            };

            // Front face stencil
            MTLStencilDescriptor *frontStencil = [[MTLStencilDescriptor alloc] init];
            frontStencil.stencilCompareFunction = compareFuncs[frontFunc];
            frontStencil.stencilFailureOperation = stencilOps[frontSTfail];
            frontStencil.depthFailureOperation = stencilOps[frontDPfail];
            frontStencil.depthStencilPassOperation = stencilOps[frontPass];
            frontStencil.readMask = (uint32_t)readMask;
            frontStencil.writeMask = (uint32_t)writeMask;
            descriptor.frontFaceStencil = frontStencil;

            // Back face stencil
            MTLStencilDescriptor *backStencil = [[MTLStencilDescriptor alloc] init];
            backStencil.stencilCompareFunction = compareFuncs[backFunc];
            backStencil.stencilFailureOperation = stencilOps[backSTfail];
            backStencil.depthFailureOperation = stencilOps[backDPfail];
            backStencil.depthStencilPassOperation = stencilOps[backPass];
            backStencil.readMask = (uint32_t)readMask;
            backStencil.writeMask = (uint32_t)writeMask;
            descriptor.backFaceStencil = backStencil;

            // Create the depth stencil state
            depthStencilState = [device newDepthStencilStateWithDescriptor:descriptor];
            
            // Cache it for future use
            if (depthStencilState) {
                cache[cacheKey] = depthStencilState;
                metal_debug_log("Created and cached new depth-stencil state: %s", [cacheKey UTF8String]);
            }
        }

        // Apply the state (cached or newly created)
        if (depthStencilState) {
            [renderEncoder setDepthStencilState:depthStencilState];
            [renderEncoder setStencilReferenceValue:(uint32_t)reference];
        }
    }
}

void metal_set_cull_mode_impl(vdynamic *encoder, int cullMode) {
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

void metal_set_triangle_fill_mode_impl(vdynamic *encoder, bool wireframe) {
    if (encoder == NULL) return;

    @autoreleasepool {
        id<MTLRenderCommandEncoder> renderEncoder = (__bridge id<MTLRenderCommandEncoder>)encoder;

        // Metal triangle fill modes: MTLTriangleFillModeFill (solid) or MTLTriangleFillModeLines (wireframe)
        MTLTriangleFillMode fillMode = wireframe ? MTLTriangleFillModeLines : MTLTriangleFillModeFill;

        [renderEncoder setTriangleFillMode:fillMode];
        metal_debug_log("set_triangle_fill_mode() - Mode: %s", wireframe ? "Wireframe" : "Solid");
    }
}

void metal_set_viewport_impl(vdynamic *encoder, double x, double y, double width, double height) {
    if (encoder == NULL) return;

    @autoreleasepool {
        id<MTLRenderCommandEncoder> renderEncoder = (__bridge id<MTLRenderCommandEncoder>)encoder;

        MTLViewport viewport = {x, y, width, height, 0.0, 1.0};
        [renderEncoder setViewport:viewport];
        metal_debug_log("set_viewport() - SUCCESS (x=%.2f, y=%.2f, width=%.2f, height=%.2f)", x, y, width, height);
    }
}

void metal_set_scissor_rect_impl(vdynamic *encoder, int x, int y, int width, int height) {
    if (encoder == NULL) return;

    @autoreleasepool {
        id<MTLRenderCommandEncoder> renderEncoder = (__bridge id<MTLRenderCommandEncoder>)encoder;

        // Coordinates must be non-negative
        if (x < 0) x = 0;
        if (y < 0) y = 0;

        MTLScissorRect scissor = {(NSUInteger)x, (NSUInteger)y, (NSUInteger)width, (NSUInteger)height};
        [renderEncoder setScissorRect:scissor];
        [renderEncoder setScissorRect:scissor];
        metal_debug_log("set_scissor_rect() - SUCCESS (x=%d, y=%d, width=%d, height=%d)", x, y, width, height);
    }
}

void metal_set_vertex_buffer_impl(vdynamic *encoder, vdynamic *buffer, int offset, int index) {
    if (encoder == NULL || buffer == NULL) return;

    @autoreleasepool {
        id<MTLRenderCommandEncoder> renderEncoder = (__bridge id<MTLRenderCommandEncoder>)encoder;
        id<MTLBuffer> metalBuffer = (__bridge id<MTLBuffer>)buffer;

        [renderEncoder setVertexBuffer:metalBuffer offset:offset atIndex:index];
        metal_debug_log("set_vertex_buffer() - SUCCESS (offset=%d, index=%d)", offset, index);
    }
}

void metal_set_vertex_bytes_impl(vdynamic *encoder, vbyte *data, int length, int index) {
    if (encoder == NULL || data == NULL || length <= 0) return;

    @autoreleasepool {
        id<MTLRenderCommandEncoder> renderEncoder = (__bridge id<MTLRenderCommandEncoder>)encoder;
        [renderEncoder setVertexBytes:(const void*)data length:length atIndex:index];
    }
}

void metal_set_fragment_bytes_impl(vdynamic *encoder, vbyte *data, int length, int index) {
    if (encoder == NULL || data == NULL || length <= 0) return;

    @autoreleasepool {
        id<MTLRenderCommandEncoder> renderEncoder = (__bridge id<MTLRenderCommandEncoder>)encoder;
        [renderEncoder setFragmentBytes:(const void*)data length:length atIndex:index];
    }
}

void metal_set_fragment_texture_impl(vdynamic *encoder, vdynamic *texture, int index) {
    if (encoder == NULL || texture == NULL) return;

    @autoreleasepool {
        id<MTLRenderCommandEncoder> renderEncoder = (__bridge id<MTLRenderCommandEncoder>)encoder;
        id<MTLTexture> metalTexture = (__bridge id<MTLTexture>)texture;

        [renderEncoder setFragmentTexture:metalTexture atIndex:index];
        
        // Enhanced debug: log texture details
        metal_debug_log("set_fragment_texture() - SUCCESS (index=%d, tex=%p, %lux%lu, format=%d)", 
            index, metalTexture, 
            (unsigned long)metalTexture.width, (unsigned long)metalTexture.height,
            (int)metalTexture.pixelFormat);
    }
}

void metal_set_fragment_buffer_impl(vdynamic *encoder, vdynamic *buffer, int offset, int index) {
    if (encoder == NULL || buffer == NULL) return;

    @autoreleasepool {
        id<MTLRenderCommandEncoder> renderEncoder = (__bridge id<MTLRenderCommandEncoder>)encoder;
        id<MTLBuffer> metalBuffer = (__bridge id<MTLBuffer>)buffer;

        [renderEncoder setFragmentBuffer:metalBuffer offset:offset atIndex:index];
        metal_debug_log("set_fragment_buffer() - SUCCESS (offset=%d, index=%d)", offset, index);
    }
}

void metal_draw_primitives_impl(vdynamic *encoder, int primitiveType, int vertexStart, int vertexCount) {
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

void metal_draw_indexed_primitives_impl(vdynamic *encoder, int primitiveType, int indexCount, vdynamic *indexBuffer, int indexOffset, int is32bit) {
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

        MTLIndexType indexType = is32bit ? MTLIndexTypeUInt32 : MTLIndexTypeUInt16;
        [renderEncoder drawIndexedPrimitives:metalPrimitiveType
                                  indexCount:indexCount
                                   indexType:indexType
                                 indexBuffer:metalIndexBuffer
                           indexBufferOffset:indexOffset];
        metal_debug_log("draw_indexed_primitives() - SUCCESS (primitiveType=%d, indexCount=%d, indexOffset=%d, is32bit=%d)", primitiveType, indexCount, indexOffset, is32bit);
    }
}

void metal_draw_indexed_primitives_instanced_impl(vdynamic *encoder, int primitiveType, int indexCount, vdynamic *indexBuffer, int indexOffset, int instanceCount, int is32bit) {
    if (encoder == NULL || indexBuffer == NULL || indexCount <= 0 || instanceCount <= 0) return;

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

        MTLIndexType indexType = is32bit ? MTLIndexTypeUInt32 : MTLIndexTypeUInt16;
        [renderEncoder drawIndexedPrimitives:metalPrimitiveType
                                  indexCount:indexCount
                                   indexType:indexType
                                 indexBuffer:metalIndexBuffer
                           indexBufferOffset:indexOffset
                               instanceCount:instanceCount];
        metal_debug_log("draw_indexed_primitives_instanced() - SUCCESS (primitiveType=%d, indexCount=%d, indexOffset=%d, instanceCount=%d, is32bit=%d)", primitiveType, indexCount, indexOffset, instanceCount, is32bit);
    }
}

void metal_end_encoding_impl(vdynamic *encoder) {
    if (encoder == NULL) return;

    @autoreleasepool {
        id<MTLRenderCommandEncoder> renderEncoder = (__bridge_transfer id<MTLRenderCommandEncoder>)encoder;
        
        // NOTE: Do NOT clear lastMRTCount here!
        // MRT textures need to remain available for subsequent passes to read from.
        // They are only cleared when:
        // 1. A new MRT pass starts (overwriting the old textures in begin_mrt_render_pass)
        // 2. At end of frame (in present() or begin_render_pass with clear)
        
        [renderEncoder endEncoding];
        metal_debug_log("end_encoding() - SUCCESS");
    }
}
