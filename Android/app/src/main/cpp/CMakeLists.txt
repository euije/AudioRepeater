cmake_minimum_required(VERSION 3.22.1)

project(audiorepeater_native LANGUAGES CXX)

add_library(
    audiorepeater_native
    SHARED
    native_aaudio.cpp
)

find_library(aaudio_lib aaudio REQUIRED)
find_library(log_lib log REQUIRED)

target_link_libraries(
    audiorepeater_native
    PRIVATE
    c++_static
    c++abi
    ${aaudio_lib}
    ${log_lib}
)
