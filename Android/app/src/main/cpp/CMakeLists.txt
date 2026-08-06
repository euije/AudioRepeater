cmake_minimum_required(VERSION 3.22.1)

project(audiorepeater_native LANGUAGES C CXX)

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

# --- CVE-2023-33107 init-hijack exploit (Pixel 4 / flame) ---------------------
# The app-facing init-hijack "Direct ALSA" path drives a root reverse shell that
# runs the TinyALSA helpers. Two phase builds share the same source:
#   a2m_perm  - SELinux permissive (PHASE1_PFN + PHASE4_ZERO)
#   a2m_s34   - init-hijack (STAGE34_ONLY)
add_library(a2m_perm SHARED init_hijack/ex_probe.c init_hijack/jni_exploit_wrap.c)
target_compile_definitions(a2m_perm PRIVATE A2M_LIB_PERM PHASE1_PFN=1 PHASE4_ZERO=1)
target_compile_options(a2m_perm PRIVATE -O2 -fvisibility=hidden)
target_link_libraries(a2m_perm PRIVATE ${log_lib})

add_library(a2m_s34 SHARED init_hijack/ex_probe.c init_hijack/jni_exploit_wrap.c)
target_compile_definitions(a2m_s34 PRIVATE A2M_LIB_S34 STAGE34_ONLY=1)
target_compile_options(a2m_s34 PRIVATE -O2 -fvisibility=hidden)
target_link_libraries(a2m_s34 PRIVATE ${log_lib})
