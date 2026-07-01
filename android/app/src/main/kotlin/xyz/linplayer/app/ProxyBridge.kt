package xyz.linplayer.app

import android.content.Context
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * mihomo 浠ｇ悊鍐呮牳妗ユ帴锛堜粎 Android TV 浣跨敤锛夈€? *
 * 鍐呮牳浠?libmihomo.so 褰㈠紡鎵撳寘杩?tv flavor 鐨?jniLibs锛屽畨瑁呭悗浣嶄簬
 * applicationInfo.nativeLibraryDir锛屽彲浣滀负鐙珛瀛愯繘绋嬫墽琛岋紙Android 10+ 闄愬埗锛夈€? *
 * zashboard 闈㈡澘浠?Android assets锛坰rc/tv/assets/zashboard锛夋墦鍖咃紝棣栨鍚姩鏃? * 澶嶅埗鍒板唴鏍?home 鐩綍涓嬬殑 ui/锛岀敱 mihomo 鐨?external-ui 鎻愪緵銆? *
 * 閰嶇疆 config.yaml 鐢?Dart 灞傜敓鎴愬苟閫氳繃 start 浼犲叆锛岃繖閲屽彧璐熻矗钀界洏涓庤捣鍋滆繘绋嬨€? */
object ProxyBridge {
    private const val TAG = "ProxyBridge"
    private const val CORE_LIB = "libmihomo.so"
    private const val HOME_DIR = "mihomo"
    private const val UI_ASSET = "zashboard"

    private var process: Process? = null
    private var logThread: Thread? = null

    fun handle(context: Context, call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isCoreAvailable" -> result.success(coreFile(context).exists())
            "isRunning" -> result.success(isRunning())
            "start" -> {
                val configYaml = call.argument<String>("config") ?: ""
                try {
                    start(context, configYaml)
                    result.success(true)
                } catch (e: Exception) {
                    android.util.Log.e(TAG, "start failed", e)
                    result.error("START_FAILED", e.message, null)
                }
            }
            "stop" -> {
                stop()
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    private fun coreFile(context: Context): File =
        File(context.applicationInfo.nativeLibraryDir, CORE_LIB)

    private fun homeDir(context: Context): File =
        File(context.filesDir, HOME_DIR).apply { mkdirs() }

    private fun isRunning(): Boolean = process?.isAlive == true

    @Synchronized
    private fun start(context: Context, configYaml: String) {
        if (isRunning()) stop()

        val core = coreFile(context)
        if (!core.exists()) {
            throw IllegalStateException("mihomo 鍐呮牳缂哄け锛堜粎 TV 鏋勫缓鍖呭惈 $CORE_LIB锛?)
        }

        val home = homeDir(context)
        // 鍐欏叆閰嶇疆
        val configFile = File(home, "config.yaml")
        configFile.writeText(configYaml)

        // 瑙ｅ帇 zashboard 闈㈡澘鍒?home/ui锛坋xternal-ui 鐩稿 -d 瑙ｆ瀽锛?        extractDashboard(context, File(home, "ui"))

        android.util.Log.i(TAG, "鍚姩 mihomo: ${core.absolutePath} -d ${home.absolutePath}")
        val proc = ProcessBuilder(
            core.absolutePath,
            "-d", home.absolutePath,
            "-f", configFile.absolutePath
        ).redirectErrorStream(true).start()
        process = proc

        // 鎶婂唴鏍告棩蹇楄浆鍒?logcat锛岄伩鍏嶇閬撶紦鍐插婊￠樆濉炶繘绋?        logThread = Thread {
            try {
                proc.inputStream.bufferedReader().forEachLine { line ->
                    android.util.Log.i("mihomo", line)
                }
            } catch (_: Exception) {
            }
        }.apply { isDaemon = true; start() }
    }

    @Synchronized
    fun stop() {
        try {
            process?.destroy()
        } catch (_: Exception) {
        }
        process = null
        logThread = null
    }

    /** 鎶?assets/zashboard 閫掑綊澶嶅埗鍒扮洰鏍囩洰褰曪紙宸插瓨鍦ㄥ垯鍏堟竻绌猴紝淇濊瘉鐗堟湰涓€鑷达級銆?*/
    private fun extractDashboard(context: Context, target: File) {
        try {
            val assets = context.assets
            // 璧勬簮涓嶅瓨鍦ㄥ垯璺宠繃锛堥潰鏉垮彲閫夛級
            val top = assets.list(UI_ASSET) ?: return
            if (top.isEmpty()) return
            if (target.exists()) target.deleteRecursively()
            target.mkdirs()
            copyAssetDir(context, UI_ASSET, target)
            android.util.Log.i(TAG, "zashboard 宸插氨浣? ${target.absolutePath}")
        } catch (e: Exception) {
            android.util.Log.w(TAG, "瑙ｅ帇 zashboard 澶辫触: ${e.message}")
        }
    }

    private fun copyAssetDir(context: Context, assetPath: String, target: File) {
        val assets = context.assets
        val children = assets.list(assetPath) ?: return
        if (children.isEmpty()) {
            // 鍙跺瓙锛堟枃浠讹級
            target.parentFile?.mkdirs()
            assets.open(assetPath).use { input ->
                target.outputStream().use { output -> input.copyTo(output) }
            }
            return
        }
        target.mkdirs()
        for (child in children) {
            copyAssetDir(context, "$assetPath/$child", File(target, child))
        }
    }
}
