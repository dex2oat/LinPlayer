package com.example.linplayer_mobile

/**
 * Bridge to register the JavaVM with ffmpeg for mpv Android EGL support.
 *
 * System.loadLibrary("mpv_init_jni") triggers JNI_OnLoad which caches
 * the JavaVM. Then nativeRegisterJavaVm() calls av_jni_set_java_vm()
 * via dlsym (after libavcodec.so is loaded as a dependency of libmpv.so).
 */
object MpvInitBridge {
    init {
        System.loadLibrary("mpv_init_jni")
    }

    @JvmStatic
    external fun nativeRegisterJavaVm()

    /**
     * Call after libmpv.so is loaded to register the JavaVM with ffmpeg.
     */
    fun ensureJavaVmRegistered() {
        try {
            nativeRegisterJavaVm()
        } catch (e: UnsatisfiedLinkError) {
            android.util.Log.e("MpvInitBridge", "nativeRegisterJavaVm failed: ${e.message}")
        }
    }
}
