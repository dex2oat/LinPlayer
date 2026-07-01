package xyz.linplayer.app

/**
 * Bridge to register the JavaVM with ffmpeg for mpv Android EGL support.
 *
 * System.loadLibrary("mpv_init_jni") triggers JNI_OnLoad which caches
 * the JavaVM. Then nativeRegisterJavaVm() calls av_jni_set_java_vm()
 * via dlsym (after libavcodec.so is loaded as a dependency of libmpv.so).
 */
object MpvInitBridge {
    init {
        // 蹇呴』鎹曡幏锛歭oadLibrary 澶辫触鎶?UnsatisfiedLinkError(Error)锛岃嫢涓嶆崟鑾蜂細璁╂湰 object 鐨?
        // 棣栨璁块棶鎶?ExceptionInInitializerError锛岀粫杩囪皟鐢ㄥ鐨?catch(Exception) 鐩存帴宕╂簝 App銆?
        // 鎹曡幏鍚庡嵆渚?mpv_init_jni 缂哄け涔熷彧鏄?JavaVM 鏈敞鍐?纭В鍥為€€杞В)锛岀粷涓嶈嚧宕┿€?
        try {
            System.loadLibrary("mpv_init_jni")
        } catch (e: Throwable) {
            android.util.Log.e("MpvInitBridge", "load mpv_init_jni failed: ${e.message}")
        }
    }

    @JvmStatic
    external fun nativeRegisterJavaVm()

    /**
     * Call after libmpv.so is loaded to register the JavaVM with ffmpeg.
     */
    fun ensureJavaVmRegistered() {
        try {
            nativeRegisterJavaVm()
        } catch (e: Throwable) {
            // mediacodec 纭В鎵€闇€鐨?JavaVM 娉ㄥ唽澶辫触锛氫笉鑷村懡锛宮pv 浼氳嚜鍔ㄥ洖閫€杞欢瑙ｇ爜銆?
            android.util.Log.e("MpvInitBridge", "nativeRegisterJavaVm failed: ${e.message}")
        }
    }
}
