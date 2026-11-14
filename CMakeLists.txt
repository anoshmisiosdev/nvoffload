cmake_minimum_required(VERSION 3.20)
project(nvoffload VERSION 0.1.0 LANGUAGES C CXX OBJC OBJCXX)

if(NOT APPLE)
  message(FATAL_ERROR "nvoffload builds only on macOS (x86_64, NullMoth NVIDIA driver). Copy the tree to the Mac and run cmake there.")
endif()

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OSX_DEPLOYMENT_TARGET "15.0" CACHE STRING "Minimum macOS (NullMoth needs 15.5+)")
set(CMAKE_OSX_ARCHITECTURES "x86_64" CACHE STRING "NullMoth is x86_64 only")
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

option(NVO_BUILD_PRESENTER "Build the standalone IOSurface presenter / smoke test" ON)

# ARC for every Objective-C(++) translation unit.
add_compile_options("$<$<COMPILE_LANGUAGE:OBJC,OBJCXX>:-fobjc-arc>")
add_compile_options(-Wall -Wextra -Wno-unused-parameter)

foreach(fw Metal Foundation IOKit IOSurface QuartzCore CoreGraphics CoreFoundation AppKit)
  find_library(NVO_FW_${fw} ${fw} REQUIRED)
endforeach()
set(NVO_CORE_FRAMEWORKS
  ${NVO_FW_Metal} ${NVO_FW_Foundation} ${NVO_FW_IOKit} ${NVO_FW_IOSurface}
  ${NVO_FW_QuartzCore} ${NVO_FW_CoreGraphics} ${NVO_FW_CoreFoundation})

# ---------------------------------------------------------------- common
add_library(nvo_common STATIC
  src/common/nvo_log.cpp)
target_include_directories(nvo_common PUBLIC src)

# ---------------------------------------------------------------- diagnostics (shared by nvprime-run --info and the dylib)
add_library(nvo_diag STATIC
  src/diag/ioreg_util.mm
  src/diag/metal_enum.mm
  src/diag/iokit_enum.mm
  src/diag/display_enum.mm
  src/diag/nullmoth_probe.mm)
target_include_directories(nvo_diag PUBLIC src)
target_link_libraries(nvo_diag PUBLIC nvo_common ${NVO_CORE_FRAMEWORKS})

# ---------------------------------------------------------------- libnvoffload.dylib (DYLD_INSERT_LIBRARIES interposer)
add_library(nvoffload SHARED
  src/interposer/init.mm
  src/interposer/device_select.mm
  src/interposer/moltenvk_env.mm
  src/interposer/present_bridge.mm)
target_include_directories(nvoffload PRIVATE src)
target_link_libraries(nvoffload PRIVATE nvo_common ${NVO_CORE_FRAMEWORKS})
set_target_properties(nvoffload PROPERTIES
  OUTPUT_NAME nvoffload
  PREFIX "lib"
  SUFFIX ".dylib"
  INSTALL_RPATH "@loader_path")
# Interposing needs flat symbol resolution for the replacee stubs; nothing else special.
target_link_options(nvoffload PRIVATE -Wl,-undefined,dynamic_lookup)

# ---------------------------------------------------------------- nvprime-run (launcher + --info)
add_executable(nvprime-run
  src/launcher/main.mm)
target_link_libraries(nvprime-run PRIVATE nvo_diag)
add_dependencies(nvprime-run nvoffload)

# ---------------------------------------------------------------- nvoffload-presenter (IOSurface -> screen smoke test / helper)
if(NVO_BUILD_PRESENTER)
  add_executable(nvoffload-presenter
    src/presenter/main.mm)
  target_include_directories(nvoffload-presenter PRIVATE src)
  target_link_libraries(nvoffload-presenter PRIVATE nvo_common ${NVO_CORE_FRAMEWORKS} ${NVO_FW_AppKit})
endif()

install(TARGETS nvoffload nvprime-run
  RUNTIME DESTINATION bin
  LIBRARY DESTINATION lib)
if(NVO_BUILD_PRESENTER)
  install(TARGETS nvoffload-presenter RUNTIME DESTINATION bin)
endif()
