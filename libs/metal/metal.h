#ifndef METAL_H
#define METAL_H

#define HL_NAME(n) metal_##n

#include <hl.h>
#include <SDL2/SDL.h>
#include <SDL2/SDL_metal.h>
#include <Metal/Metal.h>
#include <QuartzCore/CAMetalLayer.h>
#include <simd/simd.h>
#include <stdarg.h>  // Add this for va_list

// Common constants and macros
#define DEBUG_FILE "/tmp/metal_debug.log"

// Buffer usage flags (match h3d.Buffer.BufferFlag enum)
#define BUFFER_FLAG_DYNAMIC      (1 << 0)  // Dynamic buffer content
#define BUFFER_FLAG_VERTEX_READ  (1 << 1)  // Used as vertex buffer
#define BUFFER_FLAG_COMPUTE_WRITE (1 << 2) // Written by compute shaders

// Helper macro: Only call didModifyRange for Managed buffers (not Shared)
#define METAL_NOTIFY_BUFFER_MODIFIED(buffer, offset, size) \
    do { \
        MTLResourceOptions storageMode = (buffer).resourceOptions & MTLResourceStorageModeMask; \
        if (storageMode == MTLResourceStorageModeManaged) { \
            [(buffer) didModifyRange:NSMakeRange((offset), (size))]; \
        } \
    } while(0)

// Forward declarations
typedef struct metal_context metal_context;

// Main context structure - use void* for ARC compatibility
struct metal_context {
    void *device;              // id<MTLDevice>
    void *commandQueue;        // id<MTLCommandQueue>
    void *layer;               // CAMetalLayer*
    SDL_MetalView metalView;
    SDL_Window *window;
    bool windowSetup;

    // Current frame rendering state
    void *currentDrawable;     // id<CAMetalDrawable>
    void *currentCommandBuffer; // id<MTLCommandBuffer>

    // Current frame resources
    int currentTargetPixelFormat;     // MTLPixelFormat
    int currentMRTCount;
    int currentMRTPixelFormats[8];
    bool hasDepthBuffer;

    // MRT texture tracking for deferred rendering
    void *lastMRTTextures[8];         // id<MTLTexture>[]
    int lastMRTCount;
    void *lastMRTDepthTexture;        // id<MTLTexture>

    // Depth buffer
    void *depthTexture;               // id<MTLTexture>

    // Depth-stencil state cache
    void *depthStencilStateCache;     // NSMutableDictionary*
};

// Global context
extern metal_context *ctx;

// ============================================================================
// Debug/Logging System
// ============================================================================
// Compile with -DMETAL_DEBUG to enable verbose logging
// Without this flag, all debug/warning/info logs compile to nothing (zero overhead)
//
// Logging levels (when METAL_DEBUG is defined):
// 0 = errors only (default)
// 1 = warnings + errors
// 2 = info + warnings + errors  
// 3 = verbose (all debug output)

// Error logging - ALWAYS available (errors indicate real problems)
void metal_log_error_impl(const char* message, ...);
#define metal_log_error(...) metal_log_error_impl(__VA_ARGS__)

#ifdef METAL_DEBUG
    // Debug build: logging functions are available and respect log level
    void metal_set_log_level(int level);
    int metal_get_log_level(void);
    void metal_debug_log_impl(const char* message, ...);
    void metal_log_warning_impl(const char* message, ...);
    void metal_log_info_impl(const char* message, ...);
    
    #define metal_debug_log(...) metal_debug_log_impl(__VA_ARGS__)
    #define metal_log_warning(...) metal_log_warning_impl(__VA_ARGS__)
    #define metal_log_info(...) metal_log_info_impl(__VA_ARGS__)
#else
    // Release build: all non-error logging compiles to nothing (zero overhead)
    static inline void metal_set_log_level(int level) { (void)level; }
    static inline int metal_get_log_level(void) { return 0; }
    
    #define metal_debug_log(...) ((void)0)
    #define metal_log_warning(...) ((void)0)
    #define metal_log_info(...) ((void)0)
#endif

// Context management functions (metal_context.m)
void metal_init_context(void);
bool metal_setup_window_context(vdynamic *win);
void metal_shutdown_context(void);

// Resources (metal_resources.m)
vdynamic* metal_create_buffer_impl(int size, int usage);
bool metal_upload_buffer_data_impl(vdynamic *buffer, vbyte *data, int size, int offset);
vdynamic* metal_create_texture_impl(int width, int height, int format, int usage, bool mipmapped, bool isCube, int arrayLength);
bool metal_upload_texture_data_impl(vdynamic *texture, vbyte *data, int width, int height, int level, int slice);
bool metal_capture_texture_pixels_impl(vdynamic *texture, vbyte *data, int width, int height, int level);
void metal_generate_mipmaps_impl(vdynamic *texture);
void metal_dispose_texture_impl(vdynamic *texture);
vdynamic* metal_create_sampler_state_impl(int minFilter, int magFilter, int mipFilter, int wrapS, int wrapT);
void metal_dispose_buffer_impl(vdynamic *buffer);
void metal_dispose_sampler_impl(vdynamic *sampler);
void metal_set_fragment_samplers_impl(vdynamic *encoder, varray *samplers);
void metal_set_fragment_sampler_impl(vdynamic *encoder, vdynamic *sampler, int index);

// Pipeline (metal_pipeline.m)
vdynamic* metal_compile_shader_impl(vstring *source, int shaderType);
vdynamic* metal_create_render_pipeline_impl(vdynamic *vertexShader, vdynamic *fragmentShader, vstring *vertexDesc, int blendSrc, int blendDst, int blendAlphaSrc, int blendAlphaDst, int blendOp, int blendAlphaOp);
vdynamic* metal_create_compute_pipeline_from_function_impl(vdynamic *func);
void metal_dispose_pipeline_impl(vdynamic *pipeline);

// Render (metal_render.m)
vdynamic* metal_begin_render_pass_impl(vdynamic *cmdBuffer, int r, int g, int b, int a);
vdynamic* metal_resume_render_pass_impl(vdynamic *cmdBuffer);
vdynamic* metal_begin_texture_render_pass_impl(vdynamic *cmdBuffer, vdynamic *texture, int r, int g, int b, int a, vdynamic *depthTexParam, int layer, int mipLevel, int depthAction);
vdynamic* metal_begin_mrt_render_pass_impl(vdynamic *cmdBuffer, varray *textures, int r, int g, int b, int a, vdynamic *depthTex);
vdynamic* metal_begin_depth_render_pass_impl(vdynamic *cmdBuffer, vdynamic *depthTexture, double clearDepth);
void metal_set_render_pipeline_state_impl(vdynamic *encoder, vdynamic *pipeline);
void metal_set_depth_state_impl(vdynamic *encoder, bool depthTest, bool depthWrite);
void metal_set_stencil_state_impl(vdynamic *encoder, int depthCompareFunc, bool depthWrite, int frontFunc, int frontSTfail, int frontDPfail, int frontPass, int backFunc, int backSTfail, int backDPfail, int backPass, int reference, int readMask, int writeMask);
void metal_set_cull_mode_impl(vdynamic *encoder, int cullMode);
void metal_set_triangle_fill_mode_impl(vdynamic *encoder, bool wireframe);
void metal_set_viewport_impl(vdynamic *encoder, double x, double y, double width, double height);
void metal_set_scissor_rect_impl(vdynamic *encoder, int x, int y, int width, int height);
void metal_set_vertex_buffer_impl(vdynamic *encoder, vdynamic *buffer, int offset, int index);
void metal_set_vertex_bytes_impl(vdynamic *encoder, vbyte *data, int length, int index);
void metal_set_fragment_bytes_impl(vdynamic *encoder, vbyte *data, int length, int index);
void metal_set_fragment_texture_impl(vdynamic *encoder, vdynamic *texture, int index);
void metal_set_fragment_buffer_impl(vdynamic *encoder, vdynamic *buffer, int offset, int index);
void metal_draw_primitives_impl(vdynamic *encoder, int primitiveType, int vertexStart, int vertexCount);
void metal_draw_indexed_primitives_impl(vdynamic *encoder, int primitiveType, int indexCount, vdynamic *indexBuffer, int indexOffset, int is32bit);
void metal_draw_indexed_primitives_instanced_impl(vdynamic *encoder, int primitiveType, int indexCount, vdynamic *indexBuffer, int indexOffset, int instanceCount, int is32bit);
void metal_end_encoding_impl(vdynamic *encoder);

// Compute (metal_compute.m)
vdynamic* metal_create_compute_pipeline_impl(vbyte *source, vbyte *functionName);
void metal_set_compute_pipeline_impl(vdynamic *pipeline);
void metal_set_compute_buffer_impl(vdynamic *buffer, int index);
void metal_set_compute_texture_impl(vdynamic *texture, int index);
bool metal_dispatch_compute_impl(vdynamic *cmdBuffer, int x, int y, int z);
void metal_memory_barrier_impl(vdynamic *cmdBuffer);

#endif // METAL_H
