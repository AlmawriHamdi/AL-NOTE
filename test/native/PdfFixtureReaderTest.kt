// SPDX-License-Identifier: GPL-3.0-or-later
package io.github.almawrihamdi.alnote

import java.io.InputStream
import java.util.concurrent.CountDownLatch
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit

private class Reply {
    var calls = 0
    var value: Any? = null
    var error: String? = null
    val callback: PdfFixtureReply = { v, e -> calls++; check(calls == 1); value = v; error = e }
}
private class Harness {
    val posts = LinkedBlockingQueue<() -> Unit>()
    var launches = 0
    val core = PdfFixtureTransfer({ launches++ }, { posts.add(it) })
    val owner = "owner"
    fun select(stream: () -> InputStream): String {
        val result = Reply(); core.select(owner, result.callback)
        core.selected(stream)
        check(result.calls == 1 && result.error == null)
        return result.value as String
    }
    fun drainUntil(done: () -> Boolean) {
        val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5)
        while (!done()) {
            check(System.nanoTime() < deadline) { "Timed out" }
            posts.poll(100, TimeUnit.MILLISECONDS)?.invoke()
        }
    }
    fun read(id: String, budget: Int, seq: Int): Reply {
        val result = Reply(); core.read(owner, id, budget, seq, result.callback)
        drainUntil { result.calls == 1 }; return result
    }
}
private class Source(var remaining: Int, val short: Int = Int.MAX_VALUE, val throws: Boolean = false) : InputStream() {
    var closes = 0
    var maximumRequest = 0
    var reads = 0
    var readThread: Thread? = null
    override fun read(): Int = error("No single-byte path")
    override fun read(b: ByteArray, off: Int, len: Int): Int {
        reads++; maximumRequest = maxOf(maximumRequest, len); readThread = Thread.currentThread()
        if (throws) error("private provider failure")
        if (remaining == 0) return -1
        val n = minOf(remaining, len, short)
        b.fill(37, off, off+n); remaining -= n; return n
    }
    override fun close() { closes++ }
}
fun main() {
    var cases = 0
    for ((length, budget, short) in listOf(Triple(0,4,4), Triple(4,4,4), Triple(5,4,4), Triple(131072,131072,65536), Triple(19,19,3))) {
        val h = Harness(); val source = Source(length, short)
        val id = h.select { source }
        var total = 0; var seq = 0; var last: Reply
        do {
            last = h.read(id, budget, seq++)
            val bytes = last.value as? ByteArray
            check(bytes == null || bytes.size <= PdfFixtureTransfer.CHUNK_BYTES)
            total += bytes?.size ?: 0
        } while (last.error == null && (last.value as ByteArray).isNotEmpty())
        check(total <= budget)
        check(last.error == if (length > budget) "limit" else null)
        check(source.closes == 1 && source.maximumRequest <= 65536)
        check(source.readThread != Thread.currentThread())
        check(h.read(id,budget,seq).error == "stale")
        h.core.dispose(); cases++
    }
    run {
        val h = Harness(); val source = Source(4, throws=true); val id = h.select { source }
        check(h.read(id,4,0).error == "unavailable"); check(source.closes == 1)
        h.core.dispose(); cases++
    }
    run {
        val h = Harness(); var opens = 0
        val id = h.select { opens++; Source(4) }
        check(h.read(id,0,0).error == "arguments")
        check(h.read(id,50_000_001,0).error == "arguments")
        check(h.read(id,4,1).error == "arguments")
        val wrong = Reply(); h.core.read("another",id,4,0,wrong.callback); check(wrong.error == "stale")
        check(opens == 0)
        check((h.read(id,4,0).value as ByteArray).size == 4)
        check(h.read(id,4,0).error == "arguments")
        check(h.read(id,5,1).error == "arguments")
        h.read(id,4,1); h.core.dispose(); cases++
    }
    run {
        val h = Harness(); val first = Reply(); h.core.select(h.owner, first.callback)
        val cancel = Reply(); h.core.cancel(h.owner, cancel.callback)
        check(first.calls == 1 && first.value == null)
        val blocked = Reply(); h.core.select("next", blocked.callback); check(blocked.error == "busy")
        var opens = 0; h.core.selected { opens++; Source(10) }; check(opens == 0)
        val next = Reply(); h.core.select("next", next.callback); check(h.launches == 2)
        h.core.selected(null); check(next.calls == 1 && next.value == null)
        h.core.dispose(); cases++
    }
    for (dispose in listOf(false, true)) {
        val h = Harness(); val entered = CountDownLatch(1); val released = CountDownLatch(1)
        var closes = 0; var closeThread: Thread? = null
        val source = object : InputStream() {
            override fun read(): Int = error("unused")
            override fun read(b: ByteArray, off: Int, len: Int): Int {
                entered.countDown(); check(released.await(5,TimeUnit.SECONDS)); b[0] = 9; return 1
            }
            override fun close() { closes++; closeThread = Thread.currentThread(); released.countDown() }
        }
        val id = h.select { source }; val result = Reply(); h.core.read(h.owner,id,4,0,result.callback)
        check(entered.await(5,TimeUnit.SECONDS))
        val duplicate = Reply(); h.core.read(h.owner,id,4,1,duplicate.callback); check(duplicate.error == "busy")
        if (dispose) h.core.dispose() else h.core.cancel(h.owner,Reply().callback)
        check(result.calls == 1 && result.error == "cancelled")
        h.drainUntil { h.posts.isEmpty() && released.count == 0L && closes == 1 }
        // Consume both physical completion posts before allowing another selection.
        repeat(2) { h.posts.poll(1,TimeUnit.SECONDS)?.invoke() }
        check(result.calls == 1 && result.value == null && closes == 1)
        check(closeThread != Thread.currentThread())
        h.core.dispose(); cases++
    }
    run {
        val h = Harness(); val entered = CountDownLatch(1); val released = CountDownLatch(1); val source = Source(4)
        val id = h.select { entered.countDown(); check(released.await(5,TimeUnit.SECONDS)); source }
        val result = Reply(); h.core.read(h.owner,id,4,0,result.callback); check(entered.await(5,TimeUnit.SECONDS))
        h.core.cancel(h.owner,Reply().callback); check(result.error == "cancelled")
        released.countDown(); h.drainUntil { source.closes == 1 }
        check(source.reads == 0 && result.calls == 1)
        h.drainUntil { h.core.isIdle }
        h.core.dispose(); cases++
    }
    run {
        val h = Harness()
        val owner = "00000000-0000-4000-8000-000000000001"
        for (args in listOf(null, 1, mapOf("owner" to 1), mapOf("owner" to "bad"), mapOf("owner" to owner, "uri" to "private"))) {
            val reply = Reply(); h.core.handle("select",args,reply.callback); check(reply.error == "arguments")
        }
        check(h.launches == 0)
        val selected = Reply(); h.core.handle("select", mapOf("owner" to owner), selected.callback)
        h.core.selected { Source(1) }
        for (bad in listOf(1L, 1.0, "4", null)) {
            val reply = Reply(); h.core.handle("read", mapOf("owner" to owner, "session" to selected.value, "budget" to bad, "sequence" to 0),reply.callback)
            check(reply.error == "arguments")
        }
        val stale = Reply(); h.core.handle("close", mapOf("owner" to "00000000-0000-4000-8000-000000000002"),stale.callback)
        check(stale.error == "stale")
        h.core.dispose(); cases++
    }
    run {
        val h = Harness(); val entered = CountDownLatch(1); val released = CountDownLatch(1)
        val closeEntered = CountDownLatch(1); val closeReleased = CountDownLatch(1)
        var closes = 0
        val source = object : InputStream() {
            override fun read(): Int = error("unused")
            override fun read(b: ByteArray, off: Int, len: Int): Int {
                entered.countDown(); check(released.await(5,TimeUnit.SECONDS)); return -1
            }
            override fun close() { closes++; closeEntered.countDown(); check(closeReleased.await(5,TimeUnit.SECONDS)) }
        }
        val id = h.select { source }; val result = Reply(); h.core.read(h.owner,id,4,0,result.callback)
        check(entered.await(5,TimeUnit.SECONDS)); h.core.cancel(h.owner,Reply().callback)
        check(closeEntered.await(5,TimeUnit.SECONDS))
        repeat(100) {
            val blocked = Reply(); h.core.select("next",blocked.callback); check(blocked.error == "busy")
        }
        check(h.launches == 1)
        released.countDown(); h.posts.poll(5,TimeUnit.SECONDS)!!.invoke()
        val stillBlocked = Reply(); h.core.select("next",stillBlocked.callback); check(stillBlocked.error == "busy")
        closeReleased.countDown(); h.posts.poll(5,TimeUnit.SECONDS)!!.invoke()
        val next = Reply(); h.core.select("next",next.callback); check(h.launches == 2)
        check(result.calls == 1 && result.error == "cancelled" && closes == 1)
        h.core.selected(null); h.core.dispose(); cases++
    }
    run {
        val h = Harness(); val source = Source(4)
        val id = h.select { source }; h.read(id,4,0)
        h.core.dispose(); h.drainUntil { h.core.isIdle }
        check(source.closes == 1); cases++
    }
    run {
        val old = PdfFixtureActivitySelection(); val oldCode = old.begin(); old.dispose()
        val next = PdfFixtureActivitySelection(); val nextCode = next.begin()
        check(nextCode != oldCode && !next.consume(oldCode))
        check(next.consume(nextCode) && !next.consume(nextCode))
        val cancelled = next.begin(); check(!next.consume(oldCode)); check(next.consume(cancelled))
        cases++
    }
    run {
        val old = Harness(); val next = Harness()
        val entered = CountDownLatch(1); val released = CountDownLatch(1)
        val source = object : InputStream() {
            override fun read(): Int = error("unused")
            override fun read(b: ByteArray, off: Int, len: Int): Int {
                entered.countDown(); check(released.await(5,TimeUnit.SECONDS)); return -1
            }
            override fun close() { /* This controlled provider ignores cancellation. */ }
        }
        val id = old.select { source }; val reply = Reply(); old.core.read(old.owner,id,4,0,reply.callback)
        check(entered.await(5,TimeUnit.SECONDS)); old.core.dispose()
        repeat(100) {
            val blocked = Reply(); next.core.select(next.owner,blocked.callback); check(blocked.error == "busy")
        }
        check(next.launches == 0 && reply.error == "cancelled")
        released.countDown(); old.drainUntil { old.core.isIdle }
        next.select { Source(1) }; check(next.launches == 1)
        next.core.dispose(); cases++
    }
    run {
        val posts = LinkedBlockingQueue<() -> Unit>()
        val unavailable = PdfFixtureTransfer({ throw IllegalStateException("no activity") }, { posts.add(it) })
        repeat(2) { val reply = Reply(); unavailable.select("owner",reply.callback); check(reply.error == "unavailable") }
        val next = Harness(); next.select { Source(1) }; next.core.dispose(); unavailable.dispose()
        cases++
    }
    println("PASS: $cases native JVM cases; bounded production transfer core, no Android device/provider execution")
}
