package io.github.ccch1mneyyy.dsh_app.runtime

import android.content.Context
import android.os.Build
import java.io.File
import org.json.JSONObject

data class RuntimeArchive(
    val asset: String,
    val bytes: Long,
    val sha256: String?,
    val uncompressedBytes: Long,
)

/**
 * How this runtime describes itself to the app: either the assets an APK flavor carries
 * (assets/runtime/manifest.json, written by runtime/build-runtime.sh) or the manifest of
 * the runtime the on-demand installer put in app storage (runtime/manifest.json).
 */
data class RuntimeManifest(
    val runtimeVersion: String,
    val abi: String,
    /** Legacy rootfs, or base followed by engine. Upgrades only need the final archive. */
    val archives: List<RuntimeArchive>,
    val dshVersion: String?,
    val nodeVersion: String?,
    /** proot argv template; placeholders are expanded by [LaunchSpec]. */
    val launchArgv: List<String>,
    val launchEnv: Map<String, String>,
    val raw: JSONObject,
    val origin: Origin = Origin.NONE,
) {
    enum class Origin(val wire: String) { BUNDLED("bundled"), INSTALLED("installed"), NONE("none") }

    fun archivesForInstall(hasRootfs: Boolean): List<RuntimeArchive> =
        if (hasRootfs) archives.takeLast(1) else archives

    companion object {
        const val ASSET_DIR = "runtime"
        private const val INSTALLED_MANIFEST = "runtime/manifest.json"
        private const val VERSION_FILE = "runtime/rootfs.version"

        /** The runtime this APK flavor carries, or null in a build that ships none. */
        fun bundled(context: Context): RuntimeManifest? = try {
            val text = context.assets.open(ASSET_DIR + "/manifest.json").bufferedReader().use { it.readText() }
            fromJson(JSONObject(text)).copy(origin = Origin.BUNDLED)
        } catch (_: Exception) {
            null
        }

        /**
         * The runtime the installer put on this phone. Its manifest only counts while the
         * version marker agrees, so a stale file never describes another runtime.
         */
        fun installed(context: Context): RuntimeManifest? = try {
            val manifest = fromInstalled(JSONObject(File(context.filesDir, INSTALLED_MANIFEST).readText()))
            val version = File(context.filesDir, VERSION_FILE).readText().trim()
            if (version.isNotEmpty() && version == manifest.runtimeVersion) manifest else null
        } catch (_: Exception) {
            null
        }

        /**
         * The runtime to launch and report: the installed one wins, a bundled one is the
         * fallback for a build that carries it, and neither is an empty description (the
         * app then says the local engine is not installed instead of failing to start).
         */
        fun resolve(context: Context): RuntimeManifest =
            installed(context) ?: bundled(context) ?: empty(Build.SUPPORTED_ABIS.firstOrNull() ?: "arm64-v8a")

        fun empty(abi: String): RuntimeManifest = RuntimeManifest(
            runtimeVersion = "",
            abi = abi,
            archives = emptyList(),
            dshVersion = null,
            nodeVersion = null,
            launchArgv = emptyList(),
            launchEnv = emptyMap(),
            raw = JSONObject().put("schema", 2).put("abi", abi),
        )

        fun load(context: Context): RuntimeManifest = resolve(context)

        internal fun fromJson(json: JSONObject): RuntimeManifest {
            val schema = try { if (json.has("schema")) json.getInt("schema") else 1 }
                catch (_: Exception) { throw RuntimeUpgradeBlocked("manifest") }
            if (schema == 1 && json.has("layers")) throw RuntimeUpgradeBlocked("manifest")
            val archives = when (schema) {
                1 -> listOf(RuntimeArchive(json.getString("rootfs"), json.optLong("rootfsBytes", -1L),
                    json.optString("rootfsSha256").ifEmpty { null }, json.optLong("uncompressedBytes", -1L)))
                2 -> try {
                    require(!json.has("rootfs") && !json.has("rootfsSha256") && !json.has("rootfsFormat"))
                    val abi = json.getString("abi")
                    require(abi in listOf("arm64-v8a", "x86_64"))
                    val layers = json.getJSONObject("layers")
                    listOf("base", "engine").map { name ->
                        val layer = layers.getJSONObject(name)
                        val digest = layer.getString("sha256")
                        val tarDigest = layer.getString("tarSha256")
                        RuntimeArchive(layer.getString("asset"), layer.getLong("bytes"),
                            digest, layer.getLong("uncompressedBytes")).also {
                            require(it.bytes > 0 && it.uncompressedBytes >= 0 &&
                                layer.getLong("tarBytes") >= 0 &&
                                it.asset in listOf("$name-$abi.tar.xz", "$name-$abi.tar.gz") &&
                                listOf(digest, tarDigest).all { hash -> hash.matches(Regex("[0-9a-f]{64}")) })
                        }
                    }
                } catch (_: Exception) {
                    throw RuntimeUpgradeBlocked("manifest")
                }
                else -> throw RuntimeUpgradeBlocked("manifest")
            }
            val launch = json.optJSONObject("launch") ?: JSONObject()
            val argvJson = launch.optJSONArray("argv")
            val argv = if (argvJson != null) List(argvJson.length()) { argvJson.getString(it) } else emptyList()
            val envJson = launch.optJSONObject("env") ?: JSONObject()
            val env = envJson.keys().asSequence().associateWith { envJson.getString(it) }
            return RuntimeManifest(
                runtimeVersion = json.getString("runtimeVersion"),
                abi = json.optString("abi"),
                archives = archives,
                dshVersion = json.optString("dshVersion").ifEmpty { null },
                nodeVersion = json.optString("nodeVersion").ifEmpty { null },
                launchArgv = argv,
                launchEnv = env,
                raw = json,
            )
        }

        /** The installed manifest is release-shaped; its layers are not an install source. */
        internal fun fromInstalled(json: JSONObject): RuntimeManifest {
            val launch = json.optJSONObject("launch") ?: JSONObject()
            val argvJson = launch.optJSONArray("argv")
            val argv = if (argvJson != null) List(argvJson.length()) { argvJson.getString(it) } else emptyList()
            val envJson = launch.optJSONObject("env") ?: JSONObject()
            val env = envJson.keys().asSequence().associateWith { envJson.getString(it) }
            return RuntimeManifest(
                runtimeVersion = json.getString("runtimeVersion"),
                abi = json.optString("abi"),
                archives = emptyList(),
                dshVersion = json.optString("dshVersion").ifEmpty { null },
                nodeVersion = json.optString("nodeVersion").ifEmpty { null },
                launchArgv = argv,
                launchEnv = env,
                raw = json,
                origin = Origin.INSTALLED,
            )
        }
    }
}
