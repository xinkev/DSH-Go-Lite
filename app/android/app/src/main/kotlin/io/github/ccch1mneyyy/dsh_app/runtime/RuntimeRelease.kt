package io.github.ccch1mneyyy.dsh_app.runtime

import java.io.File
import org.json.JSONArray
import org.json.JSONObject

/**
 * The manifest the runtime repository publishes next to its two layer archives
 * (runtime-release/README.md in the dsh-Go checkout). It is the only network
 * input of the on-demand installer, and it names the bytes installation trusts.
 */
internal class RuntimeReleaseRejected(val code: String, message: String) : IllegalStateException(message)

internal data class RuntimeLayer(
    val name: String,
    val file: String,
    val sha256: String,
    val bytes: Long,
    val uncompressedBytes: Long,
)

/** A layer the release declares but the install unit does not require yet (office, python). */
internal data class RuntimeOptionalLayer(
    val name: String,
    val available: Boolean,
    val file: String?,
    val sha256: String?,
    val bytes: Long,
    val note: String?,
)

/** One runtime version as published: base and engine are separate files, one install unit. */
internal data class RuntimeRelease(
    val runtimeVersion: String,
    val runtimeMajor: String,
    val abi: String,
    val layers: List<RuntimeLayer>,
    val optionalLayers: List<RuntimeOptionalLayer>,
    val baseId: String?,
    val totalBytes: Long,
    val prunedModules: List<String>,
    val raw: JSONObject,
) {
    fun plan(installed: InstalledRuntime?): RuntimeInstallPlan {
        if (installed?.runtimeVersion == runtimeVersion) {
            return RuntimeInstallPlan(RuntimeInstallPlan.CURRENT, emptyList(), false)
        }
        // Same base bytes: an engine-only update may keep the installed Linux system.
        val reuse = installed?.baseId != null && installed.baseId == baseId
        return RuntimeInstallPlan(
            if (reuse) RuntimeInstallPlan.ENGINE_UPDATE else RuntimeInstallPlan.FIRST_INSTALL,
            if (reuse) layers.filter { it.name != "base" } else layers,
            reuse,
        )
    }

    /**
     * What the app launches with. Install layout, launch argv and direct engine are app
     * contracts for one runtime major (runtime-release/README.md: rNN changes when the app
     * must branch on them), so they are not read from the release.
     */
    fun appManifest(): JSONObject {
        val manifest = JSONObject(raw.toString())
        val components = manifest.optJSONObject("components")
        manifest.put("launch", RuntimeLaunchTemplate.launch())
        manifest.put("directEngine", RuntimeLaunchTemplate.directEngine(abi))
        manifest.put("dshVersion", components?.optString("dshVersion").orEmpty())
        manifest.put("nodeVersion", components?.optString("nodeVersion").orEmpty())
        return manifest
    }

    companion object {
        const val DEFAULT_MANIFEST_URL =
            "https://github.com/xinkev/DSH-Go-Lite-Runtime/releases/latest/download/manifest.json"
        const val SCHEMA = 2
        const val RUNTIME_MAJOR = "r15"
        const val MAX_MANIFEST_BYTES = 256 * 1024

        fun layerUrl(manifestUrl: String, file: String): String =
            manifestUrl.substringBeforeLast('/') + "/" + file

        /** Refuses anything this app cannot install, before a byte is downloaded. */
        fun parse(text: String): RuntimeRelease {
            val json = try {
                JSONObject(text)
            } catch (_: Exception) {
                throw RuntimeReleaseRejected("release_invalid", "runtime release manifest is not JSON")
            }
            val schema = json.optInt("schema", 0)
            val compatibility = json.optJSONObject("compatibility")
            val minAppSchema = compatibility?.optInt("minAppSchema", Int.MAX_VALUE) ?: Int.MAX_VALUE
            if (schema != SCHEMA || minAppSchema > SCHEMA) {
                throw RuntimeReleaseRejected(
                    "release_schema",
                    "this app needs runtime manifest schema " + SCHEMA + " (got " + schema + ", min " + minAppSchema + ")",
                )
            }
            val major = compatibility?.optString("runtimeMajor").orEmpty()
            if (major != RUNTIME_MAJOR) {
                throw RuntimeReleaseRejected("release_major", "this app runs " + RUNTIME_MAJOR + ", the release is " + major)
            }
            val version = json.optString("runtimeVersion").trim()
            if (!version.matches(Regex("[A-Za-z0-9._-]{1,120}")) || runtimeMajorOf(version) != major) {
                throw RuntimeReleaseRejected("release_invalid", "invalid runtimeVersion '" + version + "'")
            }
            val abi = json.optString("abi")
            if (abi != "arm64-v8a" && abi != "x86_64") {
                throw RuntimeReleaseRejected("release_invalid", "unsupported ABI '" + abi + "'")
            }
            val unit = json.optJSONObject("installUnit")
                ?: throw RuntimeReleaseRejected("release_invalid", "runtime release has no installUnit")
            val required = unit.optJSONArray("requiredLayers")
                ?: throw RuntimeReleaseRejected("release_invalid", "runtime release has no requiredLayers")
            val layersJson = json.optJSONObject("layers")
                ?: throw RuntimeReleaseRejected("release_invalid", "runtime release has no layers")
            val layers = List(required.length()) { index ->
                val name = required.optString(index)
                parseLayer(name, layersJson.optJSONObject(name))
            }
            if (layers.map { it.name }.distinct() != layers.map { it.name }) {
                throw RuntimeReleaseRejected("release_invalid", "runtime release repeats a layer")
            }
            if (layers.none { it.name == "base" } || layers.none { it.name == "engine" }) {
                throw RuntimeReleaseRejected("release_invalid", "runtime release needs base and engine layers")
            }
            val upgrade = json.optJSONObject("upgrade")
            val baseId = upgrade?.optString("baseId").orEmpty()
            val base = json.optJSONObject("baseCompatibility")
            if (baseId.length != 64 || upgrade?.optInt("schema", 0) != 1 || upgrade.optJSONArray("paths") == null ||
                base?.optInt("schema", 0) != 1 || !base.has("osRelease")
            ) {
                throw RuntimeReleaseRejected("release_invalid", "runtime release is missing its upgrade contract")
            }
            // Optional layers are placeholders: shown as declared, installed only once a
            // future release makes them part of the install unit (available + required).
            val optionalLayers = layersJson.keys().asSequence()
                .filter { name -> layers.none { it.name == name } }
                .sorted()
                .map { name -> parseOptionalLayer(name, layersJson.optJSONObject(name)) }
                .toList()
            val pruned = json.optJSONArray("prunedModules")
            val prunedModules = if (pruned == null) emptyList() else List(pruned.length()) { index ->
                val entry = pruned.opt(index)
                if (entry is JSONObject) entry.optString("name") else entry?.toString().orEmpty()
            }.filter { it.isNotBlank() }
            return RuntimeRelease(
                runtimeVersion = version,
                runtimeMajor = major,
                abi = abi,
                layers = layers,
                optionalLayers = optionalLayers,
                baseId = baseId,
                totalBytes = layers.sumOf { it.bytes },
                prunedModules = prunedModules,
                raw = json,
            )
        }

        private fun parseOptionalLayer(name: String, json: JSONObject?): RuntimeOptionalLayer {
            if (json == null) throw RuntimeReleaseRejected("release_invalid", "runtime release has no '" + name + "' layer")
            if (json.optString("role") != "optional") {
                throw RuntimeReleaseRejected("release_invalid", "runtime layer '" + name + "' is neither required nor optional")
            }
            val available = json.optBoolean("available", false)
            val file = json.optString("file").ifEmpty { null }
            val digest = json.optString("sha256").ifEmpty { null }
            if (!available) {
                if (file != null || digest != null || json.optLong("bytes", 0) != 0L) {
                    throw RuntimeReleaseRejected("release_invalid", "unavailable runtime layer '" + name + "' carries a file")
                }
                return RuntimeOptionalLayer(name, false, null, null, 0, json.optString("note").ifEmpty { null })
            }
            if (file == null || file.contains('/') || file.contains('\\') || !file.endsWith(".tar.xz") ||
                digest == null || !digest.matches(Regex("[0-9a-f]{64}")) ||
                json.optLong("bytes", -1) <= 0 || json.optLong("uncompressedBytes", -1) <= 0
            ) {
                throw RuntimeReleaseRejected("release_invalid", "available runtime layer '" + name + "' is incomplete")
            }
            return RuntimeOptionalLayer(
                name, true, file, digest, json.optLong("bytes"),
                json.optString("note").ifEmpty { null },
            )
        }

        private fun parseLayer(name: String, json: JSONObject?): RuntimeLayer {
            if (name != "base" && name != "engine") {
                throw RuntimeReleaseRejected("release_invalid", "unknown runtime layer '" + name + "'")
            }
            if (json == null) throw RuntimeReleaseRejected("release_invalid", "runtime release has no '" + name + "' layer")
            val file = json.optString("file")
            val digest = json.optString("sha256")
            val bytes = json.optLong("bytes", -1)
            val uncompressed = json.optLong("uncompressedBytes", -1)
            if (json.optString("role") != "required") {
                throw RuntimeReleaseRejected("release_invalid", "runtime layer '" + name + "' is not required")
            }
            if (name != "base" && name != "engine" || file.contains('/') || file.contains('\\') ||
                !file.startsWith(name + "-") || !(file.endsWith(".tar.xz") || file.endsWith(".tar.gz"))
            ) {
                throw RuntimeReleaseRejected("release_invalid", "invalid runtime layer file '" + file + "'")
            }
            if (!digest.matches(Regex("[0-9a-f]{64}"))) {
                throw RuntimeReleaseRejected("release_invalid", "invalid sha256 for runtime layer '" + name + "'")
            }
            if (bytes <= 0 || uncompressed <= 0) {
                throw RuntimeReleaseRejected("release_invalid", "invalid byte counts for runtime layer '" + name + "'")
            }
            return RuntimeLayer(name, file, digest, bytes, uncompressed)
        }
    }
}

/** What installing this release means for the runtime already on the phone. */
internal data class RuntimeInstallPlan(
    val kind: String,
    val layers: List<RuntimeLayer>,
    val reuseBase: Boolean,
) {
    companion object {
        const val CURRENT = "current"
        const val FIRST_INSTALL = "firstInstall"
        const val ENGINE_UPDATE = "engineUpdate"
    }
}

internal fun runtimeMajorOf(version: String): String? = Regex("^r[0-9]+").find(version)?.value

internal enum class RuntimeVersionRelation { SAME, UPDATE, DIFFERENT_MAJOR, UNKNOWN }

/** Equality is the update test; the runtime repository never republishes a tag. */
internal fun runtimeVersionRelation(installed: String?, available: String?): RuntimeVersionRelation = when {
    installed.isNullOrBlank() || available.isNullOrBlank() -> RuntimeVersionRelation.UNKNOWN
    installed == available -> RuntimeVersionRelation.SAME
    runtimeMajorOf(installed) != runtimeMajorOf(available) -> RuntimeVersionRelation.DIFFERENT_MAJOR
    else -> RuntimeVersionRelation.UPDATE
}

/** What an install left on the device, beside the rootfs itself. */
internal data class InstalledRuntime(
    val runtimeVersion: String,
    val abi: String,
    val baseId: String?,
    val prunedModules: List<String>,
    val manifestUrl: String?,
    val installedAt: Long,
)

/** runtime/installed.json: the version, what the build pruned, and where it came from. */
internal class InstalledRuntimeStore(private val base: File) {
    private val file = File(base, "installed.json")

    fun read(): InstalledRuntime? = try {
        val json = JSONObject(file.readText())
        val version = json.optString("runtimeVersion")
        if (version.isEmpty()) return null
        val pruned = json.optJSONArray("prunedModules")
        InstalledRuntime(
            runtimeVersion = version,
            abi = json.optString("abi"),
            baseId = json.optString("baseId").ifEmpty { null },
            prunedModules = if (pruned == null) emptyList()
                else List(pruned.length()) { pruned.optString(it) }.filter { it.isNotEmpty() },
            manifestUrl = json.optString("manifestUrl").ifEmpty { null },
            installedAt = json.optLong("installedAt", 0L),
        )
    } catch (_: Exception) {
        null
    }

    fun write(installed: InstalledRuntime) {
        base.mkdirs()
        val pruned = JSONArray()
        installed.prunedModules.forEach { pruned.put(it) }
        val json = JSONObject()
            .put("schema", 1)
            .put("runtimeVersion", installed.runtimeVersion)
            .put("abi", installed.abi)
            .put("baseId", installed.baseId)
            .put("prunedModules", pruned)
            .put("manifestUrl", installed.manifestUrl)
            .put("installedAt", installed.installedAt)
        val temporary = File(base, "installed.json.tmp")
        temporary.writeText(json.toString(2) + "\n")
        java.nio.file.Files.move(
            temporary.toPath(), file.toPath(),
            java.nio.file.StandardCopyOption.ATOMIC_MOVE,
            java.nio.file.StandardCopyOption.REPLACE_EXISTING,
        )
    }
}
