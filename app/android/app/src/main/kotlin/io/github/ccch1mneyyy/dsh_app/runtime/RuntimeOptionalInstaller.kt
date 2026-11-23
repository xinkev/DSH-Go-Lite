package io.github.ccch1mneyyy.dsh_app.runtime

import android.content.Context
import java.io.File
import org.json.JSONArray
import org.json.JSONObject
import org.tukaani.xz.SeekableFileInputStream

/**
 * Installs and removes one optional runtime layer (office today, python later) without
 * touching the required runtime. The release names the file, its digest and the guest paths
 * the layer owns; this class only knows how to fetch, verify, unpack and swap those paths.
 *
 * All-or-nothing: a failed install restores the paths it already replaced and leaves the
 * runtime usable. Removal deletes exactly the recorded paths; the engine starts without them.
 */
internal class OptionalLayerInstaller(
    private val context: Context,
    private val manifestUrl: String = RuntimeRelease.DEFAULT_MANIFEST_URL,
    private val downloader: RuntimeDownloader = RuntimeDownloader(),
    private val onLog: (String) -> Unit = {},
) {
    /** One installed optional layer, as recorded after a successful swap. */
    internal data class Installed(
        val runtimeVersion: String,
        val installedAt: Long,
        val paths: List<String>,
    )

    private val base = File(context.filesDir, "runtime")
    private val rootfs = File(base, "rootfs")
    private val downloads = File(base, "downloads")
    private val staging = File(base, "optional-staging")
    private val backup = File(base, "optional-backup")
    // Inside the rootfs, so the engine's dsh-go-bridge tools see the same state: an agent
    // that installs a module writes here, and this installer keeps the UI in step with it.
    private val stateDir = File(rootfs, "opt/dsh/runtime/optional")

    fun installed(name: String): Installed? {
        val json = try {
            JSONObject(File(stateDir, name + ".json").readText())
        } catch (_: Exception) {
            return null
        }
        val paths = json.optJSONArray("paths") ?: return null
        val owned = List(paths.length()) { paths.optString(it) }.filter { it.isNotBlank() }
        if (owned.isEmpty()) return null
        // An engine update replaces its own prefix; a layer whose files are gone is not installed.
        if (owned.none { File(rootfs, relative(it)).exists() }) return null
        // The bridge writes "version"; this installer has always written "runtimeVersion".
        val version = json.optString("version").ifEmpty { json.optString("runtimeVersion") }
        return Installed(version, json.optLong("installedAt", 0L), owned)
    }

    /** Module names recorded under the installed rootfs, whoever installed them. */
    fun installedNames(): List<String> = (stateDir.listFiles() ?: emptyArray())
        .map { it.name }
        .filter { it.endsWith(".json") }
        .map { it.removeSuffix(".json") }
        .sorted()

    fun install(
        runtimeVersion: String,
        layer: RuntimeOptionalLayer,
        onProgress: (done: Long, total: Long) -> Unit,
    ) {
        val file = layer.file ?: throw RuntimeReleaseRejected("release_invalid", "optional layer " + layer.name + " has no file")
        val digest = layer.sha256 ?: throw RuntimeReleaseRejected("release_invalid", "optional layer " + layer.name + " has no digest")
        check(rootfs.isDirectory) { "runtime not installed" }
        downloader.reset()
        downloads.mkdirs()
        staging.deleteRecursivelySafely()
        backup.deleteRecursivelySafely()
        staging.mkdirs()
        val archive = File(downloads, file)
        try {
            onLog("[dsh-app] optional " + layer.name + ": downloading " + layer.bytes + " bytes")
            downloader.download(
                RuntimeRelease.layerUrl(manifestUrl, file), archive, layer.bytes, digest,
            ) { read -> onProgress(read, layer.bytes) }
            onProgress(layer.bytes, layer.bytes)
            onLog("[dsh-app] optional " + layer.name + ": unpacking")
            val extractor = TarExtractor(staging) { }
            if (file.endsWith(".gz")) {
                archive.inputStream().use { extractor.extract(it, file) }
            } else {
                ParallelXZInputStream.open({ SeekableFileInputStream(archive) }).use { extractor.extractDecoded(it) }
            }
            validateStaged(layer)
            swapIn(layer)
            val owned = JSONArray()
            layer.paths.forEach { owned.put(it) }
            stateDir.mkdirs()
            File(stateDir, layer.name + ".json").writeText(
                JSONObject()
                    .put("schema", 1)
                    .put("name", layer.name)
                    .put("version", runtimeVersion)
                    .put("runtimeVersion", runtimeVersion)
                    .put("installedAt", System.currentTimeMillis())
                    .put("paths", owned)
                    .put("source", "app")
                    .toString(2) + "\n",
            )
            onLog("[dsh-app] optional " + layer.name + ": installed")
        } catch (e: Throwable) {
            staging.deleteRecursivelySafely()
            backup.deleteRecursivelySafely()
            archive.delete()
            throw e
        }
        staging.deleteRecursivelySafely()
        backup.deleteRecursivelySafely()
        archive.delete()
    }

    fun remove(name: String) {
        val record = installed(name) ?: run {
            File(stateDir, name + ".json").delete()
            return
        }
        for (path in record.paths) {
            val target = File(rootfs, relative(path))
            if (!isInside(target, rootfs)) {
                throw RuntimeReleaseRejected("release_invalid", "optional layer " + name + " owns an unsafe path")
            }
            target.deleteRecursivelySafely()
        }
        File(stateDir, name + ".json").delete()
        onLog("[dsh-app] optional " + name + ": removed")
    }

    /** The layer archive may only carry the paths the release says it owns. */
    private fun validateStaged(layer: RuntimeOptionalLayer) {
        val owned = layer.paths.map { relative(it) }
        for (entry in staging.walkTopDown()) {
            if (entry.isDirectory) continue
            val rel = entry.relativeTo(staging).invariantSeparatorsPath
            if (owned.none { rel == it || rel.startsWith(it + "/") }) {
                throw RuntimeReleaseRejected("release_invalid", "optional layer " + layer.name + " carries " + rel)
            }
        }
        for (path in layer.paths) {
            if (!File(staging, relative(path)).exists()) {
                throw RuntimeReleaseRejected("release_invalid", "optional layer " + layer.name + " is missing " + path)
            }
        }
    }

    /** Replaces exactly the owned paths, one at a time, and rolls back on any failure. */
    private fun swapIn(layer: RuntimeOptionalLayer) {
        val moved = ArrayList<Pair<String, Boolean>>() // relative path -> had an old copy
        try {
            for (path in layer.paths) {
                val rel = relative(path)
                val next = File(staging, rel)
                val target = File(rootfs, rel)
                if (!isInside(target, rootfs)) throw RuntimeReleaseRejected("release_invalid", "optional layer owns an unsafe path")
                val hadOld = target.exists() || isSymlink(target)
                if (hadOld) {
                    val old = File(backup, rel)
                    old.parentFile?.mkdirs()
                    check(target.renameTo(old)) { "could not set the previous " + path + " aside" }
                }
                target.parentFile?.mkdirs()
                if (!next.renameTo(target)) {
                    if (hadOld) File(backup, rel).renameTo(target)
                    throw IllegalStateException("could not install " + path)
                }
                moved += rel to hadOld
            }
        } catch (e: Throwable) {
            for ((rel, hadOld) in moved.asReversed()) {
                File(rootfs, rel).deleteRecursivelySafely()
                if (hadOld) {
                    val old = File(backup, rel)
                    File(rootfs, rel).parentFile?.mkdirs()
                    old.renameTo(File(rootfs, rel))
                }
            }
            throw e
        }
    }

    private fun relative(guest: String): String = guest.trimStart('/')

    private fun isInside(file: File, root: File): Boolean {
        val canonRoot = root.canonicalPath
        val canon = file.canonicalPath
        return canon == canonRoot || canon.startsWith(canonRoot + "/")
    }

    private fun isSymlink(file: File): Boolean = try {
        android.system.OsConstants.S_ISLNK(android.system.Os.lstat(file.path).st_mode)
    } catch (_: Exception) {
        runCatching { java.nio.file.Files.isSymbolicLink(file.toPath()) }.getOrDefault(false)
    }
}
