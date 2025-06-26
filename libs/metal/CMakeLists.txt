cmake_minimum_required(VERSION 3.1)

if(APPLE)
    set(CMAKE_MACOSX_RPATH ON)

    add_library(metal.hdll SHARED metal.m)

    target_include_directories(metal.hdll PRIVATE ${HL_INCLUDE_DIR})

    # Link Metal and other required frameworks
    find_library(METAL_FRAMEWORK Metal REQUIRED)
    find_library(FOUNDATION_FRAMEWORK Foundation REQUIRED)
    find_library(QUARTZ_CORE_FRAMEWORK QuartzCore REQUIRED)

    target_link_libraries(metal.hdll
        ${HL_LIBRARY}
        ${METAL_FRAMEWORK}
        ${FOUNDATION_FRAMEWORK}
        ${QUARTZ_CORE_FRAMEWORK}
    )

    set_target_properties(metal.hdll PROPERTIES
        PREFIX ""
        OUTPUT_NAME "metal"
        SUFFIX ".hdll"
    )
endif()
