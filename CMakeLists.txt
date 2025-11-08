cmake_minimum_required(VERSION 3.23)
project(ikyo C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

add_executable(ikyo)

add_subdirectory(Source)

target_include_directories(ikyo PRIVATE Source)
