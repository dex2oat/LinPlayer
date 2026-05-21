cmake_minimum_required(VERSION 3.22.1)
project("linplayer_native")

set(MPV_LIB_DIR ${CMAKE_SOURCE_DIR}/../jniLibs/${ANDROID_ABI})

# ========== linass_jni（字幕渲染 JNI，动态加载 libass 符号） ==========
add_library(linass_jni SHARED linass_jni.cpp)

find_library(log-lib log)
find_library(dl-lib dl)

target_link_libraries(linass_jni ${log-lib} ${dl-lib})

# ========== libmpv render ==========
set(LIBMPV_FOUND FALSE)
if(EXISTS "${MPV_LIB_DIR}/libmpv.so")
    set(LIBMPV_FOUND TRUE)
    message(STATUS "libmpv found: ${MPV_LIB_DIR}/libmpv.so")
else()
    message(WARNING "libmpv NOT found in ${MPV_LIB_DIR}, MPV kernel unavailable")
endif()

if(LIBMPV_FOUND)
    add_library(mpv_render_jni SHARED mpv_render_jni.cpp)
    target_include_directories(mpv_render_jni PRIVATE ${CMAKE_SOURCE_DIR}/include)

    add_library(mpv SHARED IMPORTED)
    set_target_properties(mpv PROPERTIES
        IMPORTED_LOCATION "${MPV_LIB_DIR}/libmpv.so"
    )

    find_library(egl-lib EGL)
    find_library(gles-lib GLESv2)
    find_library(android-lib android)

    target_link_libraries(mpv_render_jni
        mpv
        ${egl-lib}
        ${gles-lib}
        ${android-lib}
        ${log-lib}
    )
endif()
