package io.github.ccch1mneyyy.dsh_app.runtime

import java.io.File
import java.nio.file.Files
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Test

class RuntimeReleaseTest {
    private val version = "r15-dsh0.2.2-rc.1-node24.22.1-ubuntu24.04.5-1a2b3c4d5e6f"
    private val baseId = "a".repeat(64)
    private val base = Files.createTempDirectory("runtime-release").toFile()

    @After fun cleanup() {
        base.deleteRecursively()
    }

    private fun layer(name: String, bytes: Long = 100): JSONObject = JSONObject()
        .put("file", name + "-arm64-v8a.tar.xz")
        .put("sha256", "b".repeat(64))
        .put("bytes", bytes)
        .put("uncompressedBytes", bytes * 10)
        .put("role", "required")

    private fun office(): JSONObject = JSONObject()
        .put("file", "office-arm64-v8a.tar.xz")
        .put("sha256", "c".repeat(64))
        .put("bytes", 60)
        .put("uncompressedBytes", 600)
        .put("role", "optional")
        .put("available", true)
        .put("installsInto", "/opt/dsh")
        .put("requires", JSONArray(listOf("base", "engine")))
        .put("paths", JSONArray(listOf("/opt/dsh/node_modules/@deepseek-ai/libreoffice-kit-wasm")))
        .put("note", "downloaded only when enabled")

    private fun release(
        schema: Int = 2,
        minAppSchema: Int = 2,
        major: String = "r15",
        abi: String = "arm64-v8a",
        runtimeVersion: String = version,
        baseId: String = this.baseId,
        layers: JSONObject = JSONObject()
            .put("base", layer("base")).put("engine", layer("engine", 50))
            .put("office", office())
            .put("python", JSONObject().put("file", JSONObject.NULL).put("sha256", JSONObject.NULL)
                .put("bytes", 0).put("uncompressedBytes", 0).put("role", "optional")
                .put("available", false)),
        requiredLayers: JSONArray = JSONArray(listOf("base", "engine")),
        upgrade: JSONObject? = JSONObject().put("schema", 1).put("baseId", baseId)
            .put("ubuntuVersion", "24.04.5").put("paths", JSONArray(ENGINE_PATHS)),
        baseCompatibility: JSONObject? = JSONObject().put("schema", 1)
            .put("osRelease", JSONObject().put("ID", "ubuntu").put("VERSION_ID", "24.04"))
            .put("python3Sha256", JSONObject.NULL),
        pruned: JSONArray = JSONArray(listOf(JSONObject().put("name", "sherpa"))),
    ): JSONObject = JSONObject()
        .put("schema", schema)
        .put("runtimeVersion", runtimeVersion)
        .put("abi", abi)
        .put("installUnit", JSONObject()
            .put("name", "dsh-runtime-arm64-v8a")
            .put("atomic", true)
            .put("requiredLayers", requiredLayers)
            .put("reuseInstalledBase", true)
            .put("totalBytes", 150))
        .put("totalBytes", 150)
        .put("layers", layers)
        .put("upgrade", upgrade)
        .put("baseCompatibility", baseCompatibility)
        .put("prunedModules", pruned)
        .put("components", JSONObject().put("dshVersion", "0.2.2-rc.1").put("nodeVersion", "24.22.1"))
        .put("compatibility", JSONObject()
            .put("minAppSchema", minAppSchema)
            .put("runtimeMajor", major))

    private fun parse(json: JSONObject): RuntimeRelease = RuntimeRelease.parse(json.toString())

    private fun rejected(json: JSONObject): RuntimeReleaseRejected =
        assertThrows(RuntimeReleaseRejected::class.java) { parse(json) }

    @Test fun readsThePublishedLayersAndTheirContract() {
        val release = parse(release())
        assertEquals(version, release.runtimeVersion)
        assertEquals("r15", release.runtimeMajor)
        assertEquals("arm64-v8a", release.abi)
        assertEquals(listOf("base", "engine"), release.layers.map { it.name })
        assertEquals(listOf("office", "python"), release.optionalLayers.map { it.name })
        val office = release.optionalLayers.first { it.name == "office" }
        assertTrue(office.available)
        assertEquals("/opt/dsh", office.installsInto)
        assertEquals(listOf("base", "engine"), office.requires)
        assertEquals(listOf("/opt/dsh/node_modules/@deepseek-ai/libreoffice-kit-wasm"), office.paths)
        assertFalse(release.optionalLayers.first { it.name == "python" }.available)
        assertEquals(150L, release.totalBytes)
        assertEquals(baseId, release.baseId)
        assertEquals(listOf("sherpa"), release.prunedModules)
        assertEquals(
            "https://example.test/releases/latest/download/base-arm64-v8a.tar.xz",
            RuntimeRelease.layerUrl("https://example.test/releases/latest/download/manifest.json", "base-arm64-v8a.tar.xz"),
        )
    }

    @Test fun refusesManifestsThisAppCannotInstall() {
        assertEquals("release_schema", rejected(release(schema = 1)).code)
        assertEquals("release_schema", rejected(release(minAppSchema = 3)).code)
        assertEquals("release_major", rejected(release(major = "r16")).code)
        assertEquals("release_invalid", rejected(release(runtimeVersion = "r15-dsh-bad version")).code)
        assertEquals("release_invalid", rejected(release(abi = "armeabi-v7a")).code)
        assertEquals("release_invalid", rejected(release(upgrade = null)).code)
        assertEquals("release_invalid", rejected(release(baseCompatibility = null)).code)
        assertEquals("release_invalid", rejected(release(baseId = "short")).code)
        assertEquals(
            "release_invalid",
            rejected(release(requiredLayers = JSONArray(listOf("base", "engine", "office")))).code,
        )
        assertEquals(
            "release_invalid",
            rejected(release(requiredLayers = JSONArray(listOf("base", "base")))).code,
        )
    }

    @Test fun refusesLayersWithoutTrustworthyBytes() {
        val badDigest = release().put("layers", JSONObject()
            .put("base", layer("base").put("sha256", "xyz"))
            .put("engine", layer("engine")))
        assertEquals("release_invalid", rejected(badDigest).code)
        val zeroBytes = release().put("layers", JSONObject()
            .put("base", layer("base", bytes = 0))
            .put("engine", layer("engine")))
        assertEquals("release_invalid", rejected(zeroBytes).code)
        val optional = release().put("layers", JSONObject()
            .put("base", layer("base").put("role", "optional"))
            .put("engine", layer("engine")))
        assertEquals("release_invalid", rejected(optional).code)
        val escaping = release().put("layers", JSONObject()
            .put("base", layer("base").put("file", "../base.tar.xz"))
            .put("engine", layer("engine")))
        assertEquals("release_invalid", rejected(escaping).code)
    }

    @Test fun optionalLayersAreValidatedButStayOutOfTheInstallUnit() {
        // Available but without the install contract cannot be installed safely.
        val broken = office()
        broken.remove("installsInto")
        broken.remove("paths")
        val noContract = release().put("layers", release().getJSONObject("layers").apply {
            put("office", broken)
        })
        assertEquals("release_invalid", rejected(noContract).code)
        // A path outside installsInto would let the layer write elsewhere in the runtime.
        val escaping = release().put("layers", release().getJSONObject("layers").apply {
            put("office", office().put("paths", JSONArray(listOf("/opt/dsh/../../etc/passwd"))))
        })
        assertEquals("release_invalid", rejected(escaping).code)
        val outside = release().put("layers", release().getJSONObject("layers").apply {
            put("office", office().put("paths", JSONArray(listOf("/opt/node/bin/node"))))
        })
        assertEquals("release_invalid", rejected(outside).code)
        val bothRequired = release(requiredLayers = JSONArray(listOf("base", "engine", "office")))
        assertEquals("release_invalid", rejected(bothRequired).code)
    }

    @Test fun versionComparisonTreatsAChangedTagAsAnUpdate() {
        assertEquals(RuntimeVersionRelation.SAME, runtimeVersionRelation(version, version))
        assertEquals(
            RuntimeVersionRelation.UPDATE,
            runtimeVersionRelation(version, version.replace("1a2b3c4d5e6f", "ffffffffffff")),
        )
        assertEquals(
            RuntimeVersionRelation.DIFFERENT_MAJOR,
            runtimeVersionRelation(version, version.replaceFirst("r15", "r16")),
        )
        assertEquals(RuntimeVersionRelation.UNKNOWN, runtimeVersionRelation(null, version))
        assertEquals(RuntimeVersionRelation.UNKNOWN, runtimeVersionRelation(version, null))
        assertEquals("r15", runtimeMajorOf(version))
        assertNull(runtimeMajorOf("latest"))
    }

    @Test fun installationPlansReuseTheBaseOnlyForTheSameBaseId() {
        val release = parse(release())
        val fresh = release.plan(null)
        assertEquals(RuntimeInstallPlan.FIRST_INSTALL, fresh.kind)
        assertEquals(listOf("base", "engine"), fresh.layers.map { it.name })
        assertFalse(fresh.reuseBase)

        val installed = InstalledRuntime("r15-old", "arm64-v8a", baseId, listOf("sherpa"), "url", 1L)
        val update = release.plan(installed)
        assertEquals(RuntimeInstallPlan.ENGINE_UPDATE, update.kind)
        assertEquals(listOf("engine"), update.layers.map { it.name })
        assertTrue(update.reuseBase)

        val otherBase = release.plan(installed.copy(baseId = "c".repeat(64)))
        assertEquals(RuntimeInstallPlan.FIRST_INSTALL, otherBase.kind)
        assertEquals(listOf("base", "engine"), otherBase.layers.map { it.name })

        val same = release.plan(installed.copy(runtimeVersion = version))
        assertEquals(RuntimeInstallPlan.CURRENT, same.kind)
        assertTrue(same.layers.isEmpty())
    }

    @Test fun installedRecordSurvivesARoundTripAndDisappearsWithItsRuntime() {
        val store = InstalledRuntimeStore(base)
        assertNull(store.read())
        val installed = InstalledRuntime(version, "arm64-v8a", baseId, listOf("sherpa"), "https://example.test/manifest.json", 7L)
        store.write(installed)
        assertEquals(installed, store.read())
        File(base, "installed.json").writeText("{not json")
        assertNull(store.read())
    }

    @Test fun theInstalledManifestCarriesTheAppLaunchContractAndVersions() {
        val manifest = parse(release()).appManifest()
        assertEquals(version, manifest.getString("runtimeVersion"))
        assertEquals("0.2.2-rc.1", manifest.getString("dshVersion"))
        assertEquals("24.22.1", manifest.getString("nodeVersion"))
        val launch = manifest.getJSONObject("launch")
        assertTrue(launch.getJSONArray("argv").length() > 10)
        assertEquals(2, manifest.getJSONObject("directEngine").getInt("schema"))
        assertEquals(2, manifest.getInt("schema"))
    }
}
