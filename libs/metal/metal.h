
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
#define MAX_FRAMES_IN_FLIGHT 3

// Forward declarations
typedef struct metal_context metal_context;
typedef struct metal_vertex metal_vertex;
typedef struct frame_data frame_data;
typedef struct metal_instance_data metal_instance_data;

// Vertex structure with position and color for triangle rendering
struct metal_vertex {
    float position[3];
    float color[4];
};

// Frame data structure for animation
struct frame_data {
    float angle;
};

// Instance data for instanced rendering
struct metal_instance_data {
    simd_float4x4 instanceTransform;
    simd_float4 instanceColor;
};

// Main context structure - use void* for ARC compatibility
struct metal_context {
    void *device;           // id<MTLDevice>
    void *commandQueue;     // id<MTLCommandQueue>
    void *layer;            // CAMetalLayer*
    SDL_MetalView metalView;
    SDL_Window *window;
    bool windowSetup;

    // Pipeline states
    void *pipelineState;           // id<MTLRenderPipelineState>
    void *vertexBuffer;            // id<MTLBuffer>
    NSUInteger vertexCount;

    // Support for argument buffers
    void *argBuffer;               // id<MTLBuffer>
    void *positionBuffer;          // id<MTLBuffer>
    void *colorBuffer;             // id<MTLBuffer>

    // Animation support
    float angle;
    void *frameDataBuffer;         // id<MTLBuffer>
    void *frameSemaphore;          // dispatch_semaphore_t
    int frameIndex;
    void *frameDataBuffers[MAX_FRAMES_IN_FLIGHT];  // id<MTLBuffer>

    // Instancing support fields
    void *instanceDataBuffers[MAX_FRAMES_IN_FLIGHT];  // id<MTLBuffer>
    void *instanceIndexBuffer;     // id<MTLBuffer>
    void *instanceVertexBuffer;    // id<MTLBuffer>
    void *instancingPipelineState; // id<MTLRenderPipelineState>
    NSUInteger instanceIndexCount;
    NSUInteger instanceVertexCount;
};

// Global context
extern metal_context *ctx;

// Debug utilities
void metal_debug_log(const char* message, ...);

// Context management functions (metal_context.m)
void metal_init_context(void);
bool metal_setup_window_context(vdynamic *win);
void metal_shutdown_context(void);

// Shader management functions (metal_shaders.m)
extern NSString *shaderSource;
extern NSString *instancingShaderSource;
bool metal_setup_pipeline(void);
bool metal_setup_instancing_pipeline(void);

// Buffer management functions (metal_buffers.m)
vdynamic* metal_alloc_buffer_impl(int size, int flags);
void metal_dispose_buffer_impl(vdynamic *buffer);
bool metal_update_buffer_impl(vdynamic *buffer, void *data, int size, int offset);
bool metal_setup_frame_data(void);

// Basic rendering functions (metal_rendering.m)
bool metal_begin_render_impl(int r, int g, int b, int a);
bool metal_create_triangle_impl(float* positions, float* colors, int vertexCount);
bool metal_render_triangle_impl(int r, int g, int b, int a);

// Advanced rendering functions (metal_advanced.m)
bool metal_create_triangle_with_argbuffers_impl(float* positions, float* colors, int vertexCount);
bool metal_render_triangle_with_argbuffers_impl(int r, int g, int b, int a);
bool metal_create_instanced_rectangles_impl(void);
bool metal_render_instanced_rectangles_impl(int r, int g, int b, int a);

#endif // METAL_H