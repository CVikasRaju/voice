package com.example.voice

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "itantra/audio_override"
    private var audioManager: AudioManager? = null
    private var focusRequest: AudioFocusRequest? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setMaxVolume" -> {
                        try {
                            val am = audioManager
                            if (am == null) {
                                result.error("NO_AM", "AudioManager unavailable", null)
                                return@setMethodCallHandler
                            }
                            // Seize transient audio focus so other apps duck.
                            requestAudioFocus(am)
                            // Force the media stream to maximum volume.
                            val max = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                            am.setStreamVolume(AudioManager.STREAM_MUSIC, max, 0)
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("ERR", e.message, null)
                        }
                    }
                    "restoreAudio" -> {
                        try {
                            abandonAudioFocus()
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("ERR", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun requestAudioFocus(am: AudioManager) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val attrs = AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                .build()
            val request = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT)
                .setAudioAttributes(attrs)
                .setWillPauseWhenDucked(false)
                .build()
            focusRequest = request
            am.requestAudioFocus(request)
        } else {
            @Suppress("DEPRECATION")
            am.requestAudioFocus(
                null,
                AudioManager.STREAM_MUSIC,
                AudioManager.AUDIOFOCUS_GAIN_TRANSIENT,
            )
        }
    }

    private fun abandonAudioFocus() {
        val am = audioManager ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            focusRequest?.let { am.abandonAudioFocusRequest(it) }
        } else {
            @Suppress("DEPRECATION")
            am.abandonAudioFocus(null)
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        abandonAudioFocus()
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
