package io.github.ccch1mneyyy.dsh_app.runtime

import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.InterruptedIOException
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest

/** A download that failed for a reason the UI can name; nothing is kept. */
internal class RuntimeDownloadFailed(val code: String, message: String, cause: Throwable? = null) :
    IOException(message, cause)

internal class RuntimeInstallCancelled : InterruptedIOException("runtime install cancelled")

/**
 * The one network client of the on-demand runtime: a manifest and its layer files.
 * Cancellation disconnects the active request; callers delete whatever was written.
 */
internal class RuntimeDownloader(
    private val connectTimeoutMs: Int = 30_000,
    private val readTimeoutMs: Int = 60_000,
) {
    @Volatile private var cancelled = false
    @Volatile private var active: HttpURLConnection? = null

    fun cancel() {
        cancelled = true
        active?.disconnect()
    }

    fun reset() {
        cancelled = false
    }

    fun text(url: String, maxBytes: Int): String {
        check(!cancelled) { "runtime install cancelled" }
        val connection = open(url)
        try {
            val code = connection.responseCode
            if (code != HttpURLConnection.HTTP_OK) throw RuntimeDownloadFailed("release_http_$code", "runtime release returned HTTP " + code)
            val length = connection.contentLengthLong
            if (length > maxBytes) throw RuntimeDownloadFailed("release_invalid", "runtime manifest is too large")
            val bytes = connection.inputStream.use { input ->
                val out = java.io.ByteArrayOutputStream()
                val buffer = ByteArray(16 * 1024)
                while (true) {
                    if (cancelled) throw RuntimeInstallCancelled()
                    val read = input.read(buffer)
                    if (read < 0) break
                    out.write(buffer, 0, read)
                    if (out.size() > maxBytes) throw RuntimeDownloadFailed("release_invalid", "runtime manifest is too large")
                }
                out.toByteArray()
            }
            return String(bytes, Charsets.UTF_8)
        } catch (e: RuntimeDownloadFailed) {
            throw e
        } catch (e: InterruptedIOException) {
            throw RuntimeInstallCancelled()
        } catch (e: IOException) {
            if (cancelled) throw RuntimeInstallCancelled()
            throw RuntimeDownloadFailed("release_unreachable", "could not reach the runtime release", e)
        } finally {
            active = null
            connection.disconnect()
        }
    }

    /**
     * Downloads [url] to [target], checking the declared byte count and sha256 before it
     * returns. A mismatch deletes the file and fails; cancellation deletes it too.
     */
    fun download(
        url: String,
        target: File,
        expectedBytes: Long,
        expectedSha256: String,
        onProgress: (Long) -> Unit = {},
    ) {
        check(!cancelled) { "runtime install cancelled" }
        target.parentFile?.mkdirs()
        val digest = MessageDigest.getInstance("SHA-256")
        var total = 0L
        var lastReported = 0L
        val connection = open(url)
        try {
            val code = connection.responseCode
            if (code != HttpURLConnection.HTTP_OK) throw RuntimeDownloadFailed("release_http_$code", "runtime layer returned HTTP " + code)
            val declared = connection.contentLengthLong
            if (declared > 0 && declared != expectedBytes) {
                throw RuntimeDownloadFailed("release_truncated", "runtime layer declares " + declared + " bytes, the manifest " + expectedBytes)
            }
            connection.inputStream.use { input ->
                FileOutputStream(target).use { out ->
                    val buffer = ByteArray(64 * 1024)
                    while (true) {
                        if (cancelled) throw RuntimeInstallCancelled()
                        val read = input.read(buffer)
                        if (read < 0) break
                        out.write(buffer, 0, read)
                        digest.update(buffer, 0, read)
                        total += read
                        if (total > expectedBytes) {
                            throw RuntimeDownloadFailed("release_truncated", "runtime layer is larger than the manifest says")
                        }
                        if (total - lastReported >= 256 * 1024) {
                            lastReported = total
                            onProgress(total)
                        }
                    }
                }
            }
            if (total != expectedBytes) {
                throw RuntimeDownloadFailed("release_truncated", "runtime layer stopped at " + total + " of " + expectedBytes + " bytes")
            }
            val actual = digest.digest().joinToString("") { "%02x".format(it) }
            if (!actual.equals(expectedSha256, ignoreCase = true)) {
                throw RuntimeDownloadFailed("release_checksum", "runtime layer does not match its sha256")
            }
            onProgress(total)
        } catch (e: RuntimeDownloadFailed) {
            target.delete()
            throw e
        } catch (e: InterruptedIOException) {
            target.delete()
            throw RuntimeInstallCancelled()
        } catch (e: IOException) {
            target.delete()
            if (cancelled) throw RuntimeInstallCancelled()
            throw RuntimeDownloadFailed("release_unreachable", "runtime layer download failed", e)
        } finally {
            active = null
            connection.disconnect()
        }
    }

    private fun open(url: String): HttpURLConnection {
        if (cancelled) throw RuntimeInstallCancelled()
        val connection = try {
            URL(url).openConnection() as HttpURLConnection
        } catch (e: Exception) {
            throw RuntimeDownloadFailed("release_unreachable", "invalid runtime release URL", e)
        }
        connection.instanceFollowRedirects = true
        connection.connectTimeout = connectTimeoutMs
        connection.readTimeout = readTimeoutMs
        connection.setRequestProperty("User-Agent", "dsh-go-android")
        connection.setRequestProperty("Accept", "application/octet-stream, application/json")
        active = connection
        return connection
    }
}
