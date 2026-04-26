# CMake toolchain file for building libprojectM for Apple tvOS.
#
# Usage:
#   cmake -S <projectm-root> -B <build-dir> -G Xcode \
#         -DCMAKE_TOOLCHAIN_FILE=apps/tvos/scripts/toolchains/tvos.cmake \
#         -DCMAKE_OSX_SYSROOT=appletvos            # device
#     or  -DCMAKE_OSX_SYSROOT=appletvsimulator     # simulator
#         -DCMAKE_BUILD_TYPE=Release
#
# Caller selects SDK via CMAKE_OSX_SYSROOT. Both slices are built by
# apps/tvos/scripts/build-libprojectm-xcframework.sh and combined into an XCFramework.

# CMake 3.26+ has native tvOS support.
cmake_minimum_required(VERSION 3.26)

set(CMAKE_SYSTEM_NAME tvOS)
set(CMAKE_SYSTEM_PROCESSOR arm64)

# tvOS 16.0 is the minimum that supports MusicKit's ApplicationMusicPlayer.
# Bump to 17.0 once the build host has Xcode 15+.
if(NOT DEFINED CMAKE_OSX_DEPLOYMENT_TARGET)
    set(CMAKE_OSX_DEPLOYMENT_TARGET "16.0" CACHE STRING "tvOS deployment target")
endif()

# Architectures:
# - appletvos       -> arm64 (device)
# - appletvsimulator on Apple Silicon host -> arm64
# - appletvsimulator on Intel host         -> x86_64
# Caller may override via -DCMAKE_OSX_ARCHITECTURES=...
if(NOT DEFINED CMAKE_OSX_ARCHITECTURES)
    if(CMAKE_OSX_SYSROOT MATCHES "simulator")
        if(CMAKE_HOST_SYSTEM_PROCESSOR STREQUAL "arm64")
            set(CMAKE_OSX_ARCHITECTURES "arm64" CACHE STRING "")
        else()
            set(CMAKE_OSX_ARCHITECTURES "x86_64" CACHE STRING "")
        endif()
    else()
        set(CMAKE_OSX_ARCHITECTURES "arm64" CACHE STRING "")
    endif()
endif()

# Xcode-specific attributes (kept for compatibility if generator is switched to Xcode).
set(CMAKE_XCODE_ATTRIBUTE_ONLY_ACTIVE_ARCH NO)
set(CMAKE_XCODE_ATTRIBUTE_SKIP_INSTALL NO)
set(CMAKE_XCODE_ATTRIBUTE_ENABLE_BITCODE NO)
set(CMAKE_XCODE_ATTRIBUTE_IPHONEOS_DEPLOYMENT_TARGET "")
set(CMAKE_XCODE_ATTRIBUTE_TVOS_DEPLOYMENT_TARGET ${CMAKE_OSX_DEPLOYMENT_TARGET})

# For Unix Makefiles cross-compilation: tell CMake we're cross-compiling.
set(CMAKE_CROSSCOMPILING TRUE)

# Force static, GLES, no shared lib, no frontends, no tests, no install.
set(BUILD_SHARED_LIBS               OFF CACHE BOOL "" FORCE)
set(ENABLE_GLES                     ON  CACHE BOOL "" FORCE)
set(ENABLE_PLAYLIST                 OFF CACHE BOOL "" FORCE)
set(ENABLE_SDL_UI                   OFF CACHE BOOL "" FORCE)
set(ENABLE_EMSCRIPTEN               OFF CACHE BOOL "" FORCE)
set(ENABLE_SYSTEM_GLM               OFF CACHE BOOL "" FORCE)
set(ENABLE_SYSTEM_PROJECTM_EVAL     OFF CACHE BOOL "" FORCE)
set(ENABLE_CXX_INTERFACE            OFF CACHE BOOL "" FORCE)
set(BUILD_TESTING                   OFF CACHE BOOL "" FORCE)
set(ENABLE_INSTALL                  OFF CACHE BOOL "" FORCE)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

# Signal the tvOS branch to projectM sources. The guarded upstream edits in
# GladLoader.cpp, PlatformLibraryNames.hpp, and GLResolver.cpp check this define.
add_compile_definitions(PROJECTM_TVOS=1 USE_GLES=1)

# Make find_package/find_library search the tvOS SDK, never the host.
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
