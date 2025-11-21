cmake_minimum_required(VERSION 4.0)
project(Ikyo CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_executable(Game)
target_include_directories(Game PRIVATE Source)

add_executable(Sandbox)
target_compile_definitions(Sandbox PRIVATE SANDBOX)
target_include_directories(Sandbox PRIVATE Source)

file(GLOB_RECURSE IKYO_SOURCES
        "${CMAKE_CURRENT_SOURCE_DIR}/Source/*.h"
        "${CMAKE_CURRENT_SOURCE_DIR}/Source/*.cc"
        "${CMAKE_CURRENT_SOURCE_DIR}/Source/*.cpp"
)

file(GLOB_RECURSE IKYO_MODULES
        "${CMAKE_CURRENT_SOURCE_DIR}/Source/*.ixx"
)

target_sources(Game PRIVATE ${IKYO_SOURCES})
target_sources(Game PRIVATE FILE_SET CXX_MODULES FILES ${IKYO_MODULES})
target_sources(Sandbox PRIVATE ${IKYO_SOURCES})
target_sources(Sandbox PRIVATE FILE_SET CXX_MODULES FILES ${IKYO_MODULES})
