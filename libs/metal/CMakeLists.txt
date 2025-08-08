cmake_minimum_required(VERSION 3.10)
project(metal_hdll)

# Find SDL2
find_package(SDL2 REQUIRED)
include_directories(${SDL2_INCLUDE_DIRS})

# Include HL headers
include_directories(../../src)

# Add the Metal library
add_library(metal SHARED metal.m)

# Set frameworks for Metal
set_target_properties(metal PROPERTIES
    LINK_FLAGS "-framework Metal -framework Foundation -framework QuartzCore -framework AppKit"
)

# Link against HL and SDL2
target_link_libraries(metal
    ${CMAKE_SOURCE_DIR}/../../libhl.dylib
    ${SDL2_LIBRARIES}
)

# Set output name to metal.hdll
set_target_properties(metal PROPERTIES
    PREFIX ""
    OUTPUT_NAME "metal"
    SUFFIX ".hdll"
)

# Copy to the hashlink root directory
add_custom_command(TARGET metal POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy $<TARGET_FILE:metal> ${CMAKE_SOURCE_DIR}/../../metal.hdll
)
