package io.github.ccch1mneyyy.dsh_app.runtime

import android.content.Context
import android.os.Build
import io.github.ccch1mneyyy.dsh_app.R
import io.github.ccch1mneyyy.dsh_app.i18n.AppStrings
import java.io.File
import org.json.JSONObject
import org.tukaani.xz.SeekableFileInputStream

/**
 * Installs the Linux runtime the app does not ship: it fetches the release manifest, then
 * the required layers, verifies every byte, unpacks them into the layout DshService and
 * DirectLaunch already use, and only then publishes the new runtime version.
 *
 * All-or-nothing: downloads and staging live outside the active rootfs; a failure or a
 * cancel deletes both, leaving the installed runtime untouched. An engine-only update
 * reuses the installed base when the release names the same baseId.
 */
internal class RuntimeReleaseInstaller(
    private val context: Context,
    val manifestUrl: String = RuntimeRelease.DEFAULT_MANIFEST_URL,
    private val downloader: RuntimeDownloader = RuntimeDownloader(),
    private val onLog: (String) -> Unit = {},
) {
    private val base = File(context.filesDir, "runtime")
    private val downloads = File(base, "downloads")
    private val staging = File(base, "staging")
    private val store = InstalledRuntimeStore(base)

    /** What the last install left; null when this phone never installed a runtime. */
    fun installed(): InstalledRuntime? {
        store.read()?.let { return it }
        // A runtime installed from APK assets has no installed.json: its version is the marker.
        val version = runCatching { File(base, "rootfs.version").readText().trim() }.getOrNull()
        if (version.isNullOrEmpty() || !File(base, "rootfs").isDirectory) return null
        val manifest = RuntimeManifest.installed(context)
        val upgrade = manifest?.raw?.optJSONObject("upgrade")
        return InstalledRuntime(
            runtimeVersion = version,
            abi = manifest?.abi.orEmpty(),
            baseId = upgrade?.optString("baseId")?.ifEmpty { null },
            prunedModules = emptyList(),
            manifestUrl = null,
            installedAt = 0L,
        )
    }

    fun check(): RuntimeRelease {
        downloader.reset()
        onLog("[dsh-app] checking runtime release: " + manifestUrl)
        return RuntimeRelease.parse(downloader.text(manifestUrl, RuntimeRelease.MAX_MANIFEST_BYTES))
    }

    fun cancel() = downloader.cancel()

    fun install(
        release: RuntimeRelease,
        dropKept: Boolean = false,
        onProgress: (step: String, done: Long, total: Long) -> Unit,
    ) {
        if (Build.SUPPORTED_ABIS.none { it == release.abi }) {
            throw RuntimeReleaseRejected("release_abi", "this phone cannot run the " + release.abi + " runtime")
        }
        val plan = release.plan(installed())
        if (plan.kind == RuntimeInstallPlan.CURRENT) return
        // Finish a transaction an earlier install or update left: this payload may
        // already be active, and staging is about to be reused.
        val appManifest = release.appManifest()
        if (EngineUpgrade(base, ::syncFilesystems).recover() == release.runtimeVersion) {
            writeManifest(appManifest)
            recordInstall(release)
            return
        }
        downloader.reset()
        downloads.deleteRecursivelySafely()
        staging.deleteRecursivelySafely()
        downloads.mkdirs()
        try {
            checkFreeSpace(plan)
            onLog(
                "[dsh-app] runtime " + release.runtimeVersion + " (" + release.abi + "): " +
                    plan.kind + ", " + plan.layers.joinToString { it.name } + ", " + plan.layers.sumOf { it.bytes } + " compressed bytes",
            )
            val total = plan.layers.sumOf { it.bytes }
            var done = 0L
            for (layer in plan.layers) {
                onProgress("download", done, total)
                val target = File(downloads, layer.file)
                downloader.download(
                    RuntimeRelease.layerUrl(manifestUrl, layer.file), target, layer.bytes, layer.sha256,
                ) { read -> onProgress("download", done + read, total) }
                done += layer.bytes
                onProgress("download", done, total)
            }
            staging.mkdirs()
            var extracted = 0L
            for (layer in plan.layers) {
                val archive = File(downloads, layer.file)
                val extractor = TarExtractor(staging) { read -> onProgress("extract", extracted + read, total) }
                ParallelXZInputStream.open({ SeekableFileInputStream(archive) }).use { extractor.extractDecoded(it) }
                extracted += layer.bytes
                onProgress("extract", extracted, total)
            }
            val groupNames = appendAndroidGroupNames(
                staging,
                runCatching { File("/proc/self/task/" + android.os.Process.myTid() + "/status").readText() }.getOrNull(),
            )
            onLog(
                "[dsh-app] install group names: " +
                    (groupNames.skipped?.let { "skipped (" + it + ")" } ?: "added " + groupNames.added),
            )
            // Written before activation: an interrupted switch then still leaves a launch
            // manifest for the version the rootfs marker ends up naming.
            writeManifest(appManifest)
            activateRuntimeUpdate(
                base, release.runtimeVersion, release.abi, appManifest,
                File(context.filesDir, "runtime-keep"), dropKept,
                sync = ::syncFilesystems, onLog = onLog,
            )
            recordInstall(release)
        } catch (e: Throwable) {
            staging.deleteRecursivelySafely()
            downloads.deleteRecursivelySafely()
            throw e
        }
        staging.deleteRecursivelySafely()
        downloads.deleteRecursivelySafely()
    }

    private fun recordInstall(release: RuntimeRelease) {
        store.write(
            InstalledRuntime(
                runtimeVersion = release.runtimeVersion,
                abi = release.abi,
                baseId = release.baseId,
                prunedModules = release.prunedModules,
                manifestUrl = manifestUrl,
                installedAt = System.currentTimeMillis(),
            ),
        )
    }

    /** The installed runtime's own launch manifest (RuntimeManifest.installed reads it). */
    private fun writeManifest(manifest: JSONObject) {
        val temporary = File(base, "manifest.json.tmp")
        temporary.writeText(manifest.toString(2) + "\n")
        java.nio.file.Files.move(
            temporary.toPath(), File(base, "manifest.json").toPath(),
            java.nio.file.StandardCopyOption.ATOMIC_MOVE,
            java.nio.file.StandardCopyOption.REPLACE_EXISTING,
        )
    }

    private fun checkFreeSpace(plan: RuntimeInstallPlan) {
        // Both the compressed downloads and the unpacked tree exist until activation.
        val need = plan.layers.sumOf { it.uncompressedBytes } * 115 / 100 + plan.layers.sumOf { it.bytes }
        val free = context.filesDir.usableSpace
        if (free < need) {
            val mb = { bytes: Long -> bytes / (1024 * 1024) }
            throw IllegalStateException(AppStrings.get(context, R.string.service_storage_insufficient, mb(need), mb(free)))
        }
    }
}
