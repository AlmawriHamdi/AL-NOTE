// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.almawrihamdi.alnote

import android.app.Activity
import android.content.Intent
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.InputStream
import java.util.UUID
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/** Private ephemeral SAF route. URI and provider metadata never cross the channel. */
internal class PdfFixtureReader(private val activity: Activity, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, "alnote/pdf_fixture_reader")
    private val main = Handler(Looper.getMainLooper())
    private val selection = PdfFixtureActivitySelection()
    private val transfer = PdfFixtureTransfer(
        launch = {
            val requestCode = selection.begin()
            try {
                activity.startActivityForResult(
                    Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        type = "application/pdf"
                        addCategory(Intent.CATEGORY_OPENABLE)
                        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    }, requestCode,
                )
            } catch (error: Exception) {
                selection.dispose()
                throw error
            }
        },
        post = { main.post(it) },
    )

    init { channel.setMethodCallHandler(this) }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        transfer.handle(call.method, call.arguments) { value, error ->
            if (error == null) result.success(value) else result.error(error, "PDF fixture operation failed", null)
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (!selection.consume(requestCode)) return false
        val uri = if (resultCode == Activity.RESULT_OK) data?.data else null
        transfer.selected(if (uri == null) null else {
            { activity.contentResolver.openInputStream(uri) ?: throw IllegalStateException("unavailable") }
        })
        return true
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        selection.dispose()
        transfer.dispose()
    }

}

/** No request-code reuse across Activity recreation; exhaustion fails closed. */
internal class PdfFixtureActivitySelection {
    private var pending: Int? = null
    fun begin(): Int {
        check(pending == null)
        val code = synchronized(lock) {
            check(next <= 0xffff)
            next++
        }
        pending = code
        return code
    }
    fun consume(code: Int): Boolean {
        if (pending != code) return false
        pending = null
        return true
    }
    fun dispose() { pending = null }
    companion object {
        private val lock = Any()
        private var next = 0x5046
    }
}

internal typealias PdfFixtureReply = (Any?, String?) -> Unit

/** Same core exercised by JVM tests. Only fixed-size arrays, one slot and two workers.
 * A cancelled picker keeps its slot until its late activity result is consumed.
 * A blocked provider keeps its slot until both the read and close finish.
 */
internal class PdfFixtureTransfer(
    private val launch: () -> Unit,
    private val post: (() -> Unit) -> Unit,
    private val reader: ExecutorService = Executors.newSingleThreadExecutor(),
    private val closer: ExecutorService = Executors.newSingleThreadExecutor(),
) {
    private class Slot(val owner: String, var selectedReply: PdfFixtureReply?) {
        val id = UUID.randomUUID().toString()
        var waiting = true
        var stopped = false
        var busy = false
        var closing = false
        var opener: (() -> InputStream)? = null
        var stream: InputStream? = null
        var readReply: PdfFixtureReply? = null
        var budget: Int? = null
        var sequence = 0
        var used = 0
    }
    private var slot: Slot? = null
    private var disposed = false

    fun handle(method: String, arguments: Any?, reply: PdfFixtureReply) {
        val args = arguments as? Map<*, *>
        val owner = args?.get("owner") as? String
        if (owner == null || !OWNER.matches(owner)) { reply(null, "arguments"); return }
        when (method) {
            "select" -> if (args.keys == setOf("owner")) select(owner, reply) else reply(null, "arguments")
            "read" -> {
                val session = args["session"] as? String
                val budget = args["budget"] as? Int
                val sequence = args["sequence"] as? Int
                if (args.keys != setOf("owner", "session", "budget", "sequence") || session == null ||
                    !OWNER.matches(session) || budget == null || sequence == null) reply(null, "arguments")
                else read(owner, session, budget, sequence, reply)
            }
            "close" -> if (args.keys == setOf("owner")) cancel(owner, reply) else reply(null, "arguments")
            else -> reply(null, "arguments")
        }
    }

    @Synchronized fun select(owner: String, reply: PdfFixtureReply) {
        if (disposed || slot != null) { reply(null, "busy"); return }
        val admitted = synchronized(leaseLock) {
            if (lease != null) false else { lease = this; true }
        }
        if (!admitted) { reply(null, "busy"); return }
        val s = Slot(owner, reply)
        slot = s
        try { launch() } catch (_: Exception) {
            s.waiting = false
            s.stopped = true
            release(s)
            s.selectedReply = null
            reply(null, "unavailable")
        }
    }

    @Synchronized fun selected(opener: (() -> InputStream)?) {
        val s = slot ?: return
        if (!s.waiting) return
        s.waiting = false
        val reply = s.selectedReply
        s.selectedReply = null
        if (s.stopped || disposed || opener == null) {
            s.stopped = true
            release(s)
            reply?.invoke(null, null)
            return
        }
        s.opener = opener
        reply?.invoke(s.id, null)
    }

    @Synchronized fun read(owner: String, id: String, budget: Int, sequence: Int, reply: PdfFixtureReply) {
        val s = slot
        if (disposed || s == null || s.owner != owner || s.id != id || s.stopped || s.waiting) {
            reply(null, "stale"); return
        }
        if (s.busy) { reply(null, "busy"); return }
        if (budget !in 1..MAX_BYTES || (s.budget != null && s.budget != budget) || sequence != s.sequence) {
            reply(null, "arguments"); return
        }
        s.budget = budget
        s.sequence++
        s.busy = true
        s.readReply = reply
        val count = minOf(CHUNK_BYTES, budget - s.used + 1)
        reader.execute { readChunk(s, count, budget - s.used) }
    }

    private fun readChunk(s: Slot, count: Int, remaining: Int) {
        var output: ByteArray? = null
        var error: String? = null
        try {
            var stream = synchronized(this) { s.stream }
            if (stream == null) {
                val opener = synchronized(this) { if (s.stopped) null else s.opener }
                if (opener == null) throw IllegalStateException("cancelled")
                val opened = opener()
                val accepted = synchronized(this) {
                    if (s.stopped) false else { s.stream = opened; s.opener = null; true }
                }
                if (!accepted) { opened.close(); throw IllegalStateException("cancelled") }
                stream = opened
            }
            val buffer = ByteArray(count)
            val n = stream.read(buffer, 0, count)
            when {
                n < 0 -> output = ByteArray(0)
                n == 0 || n > count -> error = "unavailable"
                n > remaining -> error = "limit"
                else -> output = if (n == buffer.size) buffer else buffer.copyOf(n)
            }
        } catch (_: Exception) { error = "unavailable" }
        // EOF/error closes on this worker before delivering the result. Cancellation
        // may already have detached the stream for the independent close worker.
        val detached = synchronized(this) {
            if (error != null || output?.isEmpty() == true || s.stopped) {
                s.stopped = true
                s.opener = null
                val stream = s.stream
                s.stream = null
                stream
            } else null
        }
        try { detached?.close() } catch (_: Exception) { error = "unavailable" }
        val bytes = output
        val failure = error
        post {
            synchronized(this) {
                s.busy = false
                val callback = s.readReply
                s.readReply = null
                if (!s.stopped && bytes != null) s.used += bytes.size
                release(s)
                // cancel/dispose removes the callback; late data cannot publish.
                callback?.invoke(bytes, failure)
            }
        }
    }

    @Synchronized fun cancel(owner: String, reply: PdfFixtureReply) {
        val s = slot
        if (s == null || s.owner != owner || s.stopped) { reply(null, "stale"); return }
        stop(s)
        reply(null, null)
    }

    private fun stop(s: Slot) {
        s.stopped = true
        s.opener = null
        val selected = s.selectedReply
        val reading = s.readReply
        s.selectedReply = null
        s.readReply = null
        val stream = s.stream
        s.stream = null
        if (stream != null) {
            s.closing = true
            closer.execute {
                try { stream.close() } catch (_: Exception) { /* fixed cancellation result */ }
                post { synchronized(this) { s.closing = false; release(s) } }
            }
        }
        release(s)
        selected?.invoke(null, null)
        reading?.invoke(null, "cancelled")
    }

    private fun release(s: Slot) {
        if (s.stopped && !s.waiting && !s.busy && !s.closing && slot === s) {
            slot = null
            synchronized(leaseLock) { if (lease === this) lease = null }
        }
    }

    // Read-only native test evidence; no handle/URI is exposed to Dart.
    internal val isIdle: Boolean get() = synchronized(this) { slot == null }

    @Synchronized fun dispose() {
        if (disposed) return
        disposed = true
        slot?.let { it.waiting = false; stop(it) }
        // Already queued close/read work is allowed to finish. No new work enters.
        reader.shutdown()
        closer.shutdown()
    }

    companion object {
        // Survives Activity/engine recreation while an old provider is blocked.
        private val leaseLock = Any()
        private var lease: PdfFixtureTransfer? = null
        private val OWNER = Regex("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
        const val CHUNK_BYTES = 64 * 1024
        const val MAX_BYTES = 50_000_000
    }
}
