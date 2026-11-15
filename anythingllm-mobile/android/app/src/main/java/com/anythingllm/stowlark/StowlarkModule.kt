package com.anythingllm.stowlark

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import com.facebook.react.bridge.Promise
import com.facebook.react.bridge.ReactApplicationContext
import com.facebook.react.bridge.ReactContextBaseJavaModule
import com.facebook.react.bridge.ReactMethod
import java.util.UUID

class StowlarkModule(private val reactContext: ReactApplicationContext) :
    ReactContextBaseJavaModule(reactContext) {

    override fun getName(): String = "Stowlark"

    override fun getConstants(): Map<String, Any> = mapOf("supported" to isSupported())

    @ReactMethod
    fun check(promise: Promise) {
        launch(arrayOf("doctor"), null, 15_000, promise)
    }

    @ReactMethod
    fun run(script: String, promise: Promise) {
        // Termux adds a final newline when it sends stdin to the executable.
        val stdin = script.removeSuffix("\n")
        if (stdin.isBlank() || '\u0000' in stdin || stdin.toByteArray(Charsets.UTF_8).size >= MAX_SCRIPT_BYTES) {
            promise.reject("stowlark_invalid_script", "Enter a nonblank UTF-8 script of up to 65536 bytes including its final newline, with no NUL characters.")
            return
        }
        // Omit the workspace name to discard files after this run. The script goes straight to
        // the Stowlark launcher on stdin. Only the Linux guest interprets it as shell source.
        launch(arrayOf("run", "--timeout", RUN_TIMEOUT_SECONDS.toString()), stdin, RUN_CALLBACK_TIMEOUT_MS, promise)
    }

    private fun launch(arguments: Array<String>, script: String?, timeoutMs: Long, promise: Promise) {
        handler.post {
            if (!isSupported()) {
                promise.reject("stowlark_unsupported", "Stowlark requires an ARM64 device running Android 8 or later.")
                return@post
            }
            if (request != null) {
                promise.reject("stowlark_busy", "Stowlark is already handling a request.")
                return@post
            }

            val intent = Intent("com.termux.RUN_COMMAND")
                .setClassName("com.termux", "com.termux.app.RunCommandService")
                .putExtra("com.termux.RUN_COMMAND_PATH", LAUNCHER_PATH)
                .putExtra("com.termux.RUN_COMMAND_ARGUMENTS", arguments)
                .putExtra("com.termux.RUN_COMMAND_BACKGROUND", true)
            if (script != null) intent.putExtra("com.termux.RUN_COMMAND_STDIN", script)

            if (reactContext.packageManager.resolveService(intent, 0) == null) {
                promise.reject("stowlark_termux_missing", "Install and open a current version of Termux to use Stowlark.")
                return@post
            }
            if (reactContext.checkSelfPermission(TERMUX_PERMISSION) != PackageManager.PERMISSION_GRANTED) {
                rejectPermission(promise)
                return@post
            }

            val id = UUID.randomUUID().toString()
            val callbackIntent = Intent(reactContext, StowlarkResultReceiver::class.java)
                .setData(Uri.fromParts("anythingllm-stowlark", id, null))
            // Termux fills in the result extras. A unique, explicit one-shot callback keeps it
            // private to this app and prevents a late result from resolving a later request.
            val mutable = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0
            val callback = PendingIntent.getBroadcast(reactContext, 0, callbackIntent, PendingIntent.FLAG_ONE_SHOT or mutable)
            val timeout = Runnable {
                finish(id)?.promise?.reject("stowlark_callback_timeout", "Termux did not return a Stowlark result. Check that Termux is running and configured for external commands.")
            }
            request = Request(id, this, promise, callback, timeout)
            handler.postDelayed(timeout, timeoutMs)
            intent.putExtra("com.termux.RUN_COMMAND_PENDING_INTENT", callback)

            try {
                // Termux's RunCommandService promotes itself to a foreground service on
                // Android 8+, including when Termux has no running activity or terminal.
                if (reactContext.startForegroundService(intent) == null) {
                    finish(id)?.promise?.reject("stowlark_termux_missing", "Android could not start the Termux command service.")
                }
            } catch (_: SecurityException) {
                finish(id)?.let { rejectPermission(it.promise) }
            } catch (_: IllegalStateException) {
                finish(id)?.promise?.reject("stowlark_termux_start", "Open AnythingLLM in the foreground and try starting Stowlark again.")
            }
        }
    }

    override fun invalidate() {
        handler.post {
            request?.takeIf { it.owner === this }?.let { finish(it.id) }
        }
        super.invalidate()
    }

    private class Request(
        val id: String,
        val owner: StowlarkModule,
        val promise: Promise,
        val callback: PendingIntent,
        val timeout: Runnable,
    )

    companion object {
        private const val LAUNCHER_PATH = "~/.local/stowlark-android/bin/stowlark-android"
        private const val TERMUX_PERMISSION = "com.termux.permission.RUN_COMMAND"
        private const val MAX_SCRIPT_BYTES = 64 * 1024
        private const val RUN_TIMEOUT_SECONDS = 90
        private const val RUN_CALLBACK_TIMEOUT_MS = (RUN_TIMEOUT_SECONDS + 15) * 1_000L
        private val handler = Handler(Looper.getMainLooper())
        private var request: Request? = null

        private fun isSupported(): Boolean =
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && "arm64-v8a" in Build.SUPPORTED_64_BIT_ABIS

        private fun rejectPermission(promise: Promise) {
            promise.reject("stowlark_termux_permission", "Allow ‘Run commands in Termux environment’ in AnythingLLM’s Android app permissions.")
        }

        private fun finish(id: String): Request? {
            val active = request?.takeIf { it.id == id } ?: return null
            request = null
            handler.removeCallbacks(active.timeout)
            active.callback.cancel()
            return active
        }

        internal fun receiveResult(intent: Intent) {
            val id = intent.data?.schemeSpecificPart ?: return
            val promise = finish(id)?.promise ?: return
            val result = intent.getBundleExtra("result")
            if (result == null) {
                promise.reject("stowlark_invalid_result", "Termux returned an empty Stowlark result.")
                return
            }
            if (result.getInt("err", Activity.RESULT_OK) != Activity.RESULT_OK) {
                promise.reject("stowlark_termux_setup", "Termux could not launch Stowlark. Check that allow-external-apps=true is set and the launcher is installed at $LAUNCHER_PATH.")
                return
            }
            val stdout = result.getString("stdout").orEmpty()
            val originalLength = result.getString("stdout_original_length")?.toIntOrNull() ?: stdout.length
            if (stdout.length < originalLength) {
                promise.reject("stowlark_result_truncated", "The Linux result is too large to return through Termux. Run a script that gives a shorter result.")
                return
            }
            if (stdout.isBlank()) {
                promise.reject("stowlark_invalid_result", "The Stowlark launcher did not return a result. Run its doctor command from Termux to check the installation.")
                return
            }
            // The CLI reports guest failures in its JSON, including when it exits nonzero.
            promise.resolve(stdout)
        }
    }
}

class StowlarkResultReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        StowlarkModule.receiveResult(intent)
    }
}
