package io.github.ccch1mneyyy.dsh_app.runtime

import org.json.JSONArray
import org.json.JSONObject

/**
 * How a downloaded runtime is launched. This is the app's side of the runtime contract for
 * one runtime major (r15): the runtime repository only ships the rootfs bytes. Change it
 * together with runtime/lib/rtbuild.py's launch_template() and bump the runtime major the
 * app accepts (RuntimeRelease.RUNTIME_MAJOR) when the layout changes.
 */
internal object RuntimeLaunchTemplate {
    private val GUEST_ENV = listOf(
        "HOME=/root", "USER=root", "LOGNAME=root", "SHELL=/bin/bash",
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "LANG=C.UTF-8", "TERM=xterm-256color", "TMPDIR=/tmp",
        "DSH_HOME=/root/.dsh",
        // Linux font discovery appends /fonts; Android's fonts are in the bound /system.
        "XDG_DATA_DIRS=/usr/local/share:/usr/share:/system",
        // pnpm 11 reads its registry from here (not from any npmrc outside $HOME).
        "pnpm_config_registry=https://registry.npmmirror.com",
        "UV_USE_IO_URING=0",
        "NARB_DISABLE_NATIVE_CACHE=1",
        "NODE_OPTIONS=--dns-result-order=ipv4first",
    )

    private val ARGV = listOf(
        "{NATIVE_LIB_DIR}/libproot.so",
        "--kill-on-exit", "--link2symlink", "--sysvipc", "-L", "-0",
        "--rootfs={ROOTFS}", "--cwd=/root",
        "-b", "/dev",
        "-b", "/dev/urandom:/dev/random",
        "-b", "/proc",
        "-b", "/proc/self/fd:/dev/fd",
        "-b", "/proc/self/fd/0:/dev/stdin",
        "-b", "/proc/self/fd/1:/dev/stdout",
        "-b", "/proc/self/fd/2:/dev/stderr",
        "-b", "/sys",
        "-b", "{ROOTFS}/var/lib/dsh-app/empty:/sys/fs/selinux",
        "-b", "{ROOTFS}/var/lib/dsh-app/shm:/dev/shm",
        "-b", "/system",
        "-b", "/apex",
        "/usr/bin/env", "-i",
    ) + GUEST_ENV + listOf(
        "{GUEST_ENV}",
        "/bin/sh", "-c",
        "echo $$ > /tmp/dsh-web.pid; exec /usr/local/bin/dsh web --patch /etc/dsh-app/dsh-web.patch.yml" +
            " --host 127.0.0.1 --port {PORT} --no-open",
    )

    private val ENV = linkedMapOf(
        "PROOT_LOADER" to "{NATIVE_LIB_DIR}/libproot-loader.so",
        "PROOT_TMP_DIR" to "{TMP}",
        "PROOT_L2S_DIR" to "{ROOTFS}/root/.l2s",
        "LD_LIBRARY_PATH" to "{NATIVE_LIB_DIR}",
    )

    fun launch(): JSONObject = JSONObject()
        .put("argv", JSONArray(ARGV))
        .put("env", JSONObject(ENV))

    fun directEngine(abi: String): JSONObject = JSONObject()
        .put("schema", 2)
        .put("defaultEnabled", false)
        .put("preload", "/opt/dsh-go/direct/preload.mjs")
        .put(
            "loader",
            if (abi == "x86_64") "/usr/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2"
            else "/usr/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1",
        )
}
