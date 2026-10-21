package com.assisto.assisto.voice

import android.content.ComponentName
import android.content.Intent
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognitionService
import android.speech.SpeechRecognizer

/**
 * Part 3 — the RecognitionService the platform REQUIRES in a
 * voice-interaction-service declaration (VoiceInteractionServiceInfo rejects a
 * VIS without `android:recognitionService`).
 *
 * The catch: when the user picks Assisto as the digital assistant, Android
 * also makes this service the phone's DEFAULT speech recognizer. A stub would
 * break speech-to-text for Assisto (speech_to_text uses the default
 * recognizer) and for other apps. So this is a transparent PROXY: every
 * request is forwarded to the best real recognizer installed (Google first),
 * and its callbacks are relayed back unchanged. We never record or keep audio.
 *
 * Honest limit: requests from OTHER apps run with Assisto's mic permission;
 * if Assisto's mic permission is off they get ERROR_INSUFFICIENT_PERMISSIONS.
 */
class AssistoRecognitionService : RecognitionService() {

    private var inner: SpeechRecognizer? = null

    private fun target(): ComponentName? {
        return try {
            val list = packageManager.queryIntentServices(
                Intent(RecognitionService.SERVICE_INTERFACE), 0
            ).map { ComponentName(it.serviceInfo.packageName, it.serviceInfo.name) }
                .filter { it.packageName != packageName }
            val prefer = listOf(
                "com.google.android.tts",                 // Speech Services by Google
                "com.google.android.googlequicksearchbox", // Google app
                "com.google.android.as"
            )
            prefer.firstNotNullOfOrNull { p -> list.firstOrNull { it.packageName == p } }
                ?: list.firstOrNull()
        } catch (ignored: Throwable) {
            null
        }
    }

    override fun onStartListening(recognizerIntent: Intent?, listener: Callback?) {
        val cb = listener ?: return
        try {
            val t = target()
            if (t == null) {
                cb.error(SpeechRecognizer.ERROR_CLIENT)
                return
            }
            inner?.destroy()
            val r = SpeechRecognizer.createSpeechRecognizer(this, t)
            inner = r
            r.setRecognitionListener(object : RecognitionListener {
                override fun onReadyForSpeech(params: Bundle?) = safe { cb.readyForSpeech(params ?: Bundle()) }
                override fun onBeginningOfSpeech() = safe { cb.beginningOfSpeech() }
                override fun onRmsChanged(rmsdB: Float) = safe { cb.rmsChanged(rmsdB) }
                override fun onBufferReceived(buffer: ByteArray?) = safe { if (buffer != null) cb.bufferReceived(buffer) }
                override fun onEndOfSpeech() = safe { cb.endOfSpeech() }
                override fun onError(error: Int) = safe { cb.error(error) }
                override fun onResults(results: Bundle?) = safe { cb.results(results ?: Bundle()) }
                override fun onPartialResults(partialResults: Bundle?) = safe { cb.partialResults(partialResults ?: Bundle()) }
                override fun onEvent(eventType: Int, params: Bundle?) {}
            })
            r.startListening(recognizerIntent ?: Intent())
        } catch (ignored: Throwable) {
            safe { cb.error(SpeechRecognizer.ERROR_CLIENT) }
        }
    }

    override fun onStopListening(listener: Callback?) {
        try { inner?.stopListening() } catch (ignored: Throwable) {}
    }

    override fun onCancel(listener: Callback?) {
        try { inner?.cancel() } catch (ignored: Throwable) {}
    }

    override fun onDestroy() {
        try { inner?.destroy() } catch (ignored: Throwable) {}
        inner = null
        super.onDestroy()
    }

    private inline fun safe(block: () -> Unit) {
        try { block() } catch (ignored: Throwable) {}
    }
}
