# rayman_legends - ReXGlue Recompiled Project
#
# SDK boilerplate lives in generated/rexglue.cmake.

cmake_minimum_required(VERSION 3.25)
if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
    project(rayman_legends LANGUAGES C CXX OBJC OBJCXX)
else()
    project(rayman_legends LANGUAGES CXX)
endif()

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

if(IOS)
    # iOS builds the SDK from source in this tree (REXSDK_DIR) and runs codegen
    # with the Mac-built rexglue CLI, which the iOS SDK build leaves out.
    set(REXSDK_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../rexglue-sdk" CACHE PATH "")
    set(REXGLUE_HOST_TOOL "${CMAKE_CURRENT_SOURCE_DIR}/../sdk-mac/bin/rexglue" CACHE FILEPATH
        "rexglue CLI built for the build machine")
    add_executable(rex::rexglue IMPORTED GLOBAL)
    set_target_properties(rex::rexglue PROPERTIES IMPORTED_LOCATION "${REXGLUE_HOST_TOOL}")
endif()

include(generated/rexglue.cmake)

# The registration and init tables are a few giant straight-line functions
# (~62,000 calls) that run once at startup. Optimizing them is pointless, and
# arm64's GlobalISel (the -O0 default) has a pass that is quadratic in a block
# that size: build them at -O0 with the classic instruction selector.
foreach(_table rayman_legends_register.cpp rayman_legends_init.cpp)
    set(_src "${CMAKE_CURRENT_SOURCE_DIR}/generated/default/${_table}")
    if(EXISTS "${_src}")
        set_property(SOURCE "${_src}" APPEND PROPERTY COMPILE_OPTIONS -O0 -mllvm -global-isel=0)
        # The shared PCH is built optimized; clang refuses it in an -O0 file.
        set_property(SOURCE "${_src}" PROPERTY SKIP_PRECOMPILE_HEADERS ON)
    endif()
endforeach()

# Sources
set(RAYMANLEGENDS_SOURCES
    src/main.cpp
    src/spin_waits.cpp
    src/widescreen.cpp
)

if(WIN32)
    add_executable(rayman_legends WIN32 ${RAYMANLEGENDS_SOURCES})
elseif(IOS)
    add_executable(rayman_legends MACOSX_BUNDLE ${RAYMANLEGENDS_SOURCES})
else()
    add_executable(rayman_legends ${RAYMANLEGENDS_SOURCES})
endif()

rexglue_setup_target(rayman_legends GPU_PLUGINS xenos)

# The Help screen's controllers (art/help_pad_*.tga.ckd, made by tools/make_pad_art.py from the game's own atlas,
# kept out of git), beside the executable.
file(GLOB RL_HELP_PADS "${CMAKE_CURRENT_SOURCE_DIR}/art/help_pad_*.tga.ckd")
if(RL_HELP_PADS)
    add_custom_command(TARGET rayman_legends POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E copy_if_different ${RL_HELP_PADS} "$<TARGET_FILE_DIR:rayman_legends>/"
        VERBATIM)
endif()

if(IOS)
    include(ios/ios.cmake)
endif()
