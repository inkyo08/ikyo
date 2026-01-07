cmake_minimum_required(VERSION 4.0)
cmake_policy(SET CMP0184 NEW)
project(Ikyo CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

set(FLAG_VARS CMAKE_CXX_FLAGS CMAKE_EXE_LINKER_FLAGS CMAKE_SHARED_LINKER_FLAGS CMAKE_MODULE_LINKER_FLAGS)
set(CONFIGS DEBUG RELEASE RELWITHDEBINFO MINSIZEREL)

foreach(var ${FLAG_VARS})
    set(${var} "" CACHE STRING "" FORCE)
    
    foreach(config ${CONFIGS})
        set(${var}_${config} "" CACHE STRING "" FORCE)
    endforeach()
endforeach()

if (WIN32)
  set(CMAKE_MSVC_RUNTIME_LIBRARY "MultiThreaded")
  set(CMAKE_MSVC_RUNTIME_CHECKS "")
  string(CONCAT CMAKE_CXX_FLAGS
    "/W4 /WX "
    "/O2 /Oi /Ot /Oy /GL "
    "/fp:fast /GS- /Gw /Gy /GR- /EHs-c- "
    "/MP "
    "/DDEBUG"
  )
  string(CONCAT CMAKE_EXE_LINKER_FLAGS
    "/LTCG /OPT:REF /OPT:ICF /INCREMENTAL:NO"
  )
elseif (UNIX)
  string(CONCAT CMAKE_CXX_FLAGS
    "-Wall -Wextra -Werror "
    "-O3 -march=native -mtune=native -flto -ffast-math -funroll-loops -fomit-frame-pointer "
    "-fno-exceptions -fno-rtti "
    "-pthread "
    "-DDEBUG"
  )
  string(CONCAT CMAKE_EXE_LINKER_FLAGS
    "-flto"
  )
endif ()

file(GLOB_RECURSE SOURCES "Sources/*.h" "Sources/*.inl" "Sources/*.cc")
source_group(TREE ${CMAKE_SOURCE_DIR}/Sources PREFIX "Sources" FILES ${SOURCES})

add_executable(Game ${SOURCES})
target_include_directories(Game PRIVATE ${CMAKE_SOURCE_DIR}/Sources)
