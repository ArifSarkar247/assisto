// itag-proof: COMPILE-ONLY stand-ins for the few Flutter embedding classes
// ItagChannel.kt uses, so itag-proof.yml can compile the real adapter against
// the real android.jar in ~1 minute (the full APK build compiles it against
// the real Flutter embedding). Never shipped, never run.
package io.flutter.plugin.common

interface BinaryMessenger

class MethodCall(@JvmField val method: String, @JvmField val arguments: Any?) {
    fun <T> argument(key: String): T? = null
}

class MethodChannel(messenger: BinaryMessenger, name: String) {
    interface Result {
        fun success(result: Any?)
        fun error(errorCode: String, errorMessage: String?, errorDetails: Any?)
        fun notImplemented()
    }

    fun interface MethodCallHandler {
        fun onMethodCall(call: MethodCall, result: Result)
    }

    fun setMethodCallHandler(handler: MethodCallHandler?) {}
    fun invokeMethod(method: String, arguments: Any?) {}
}
