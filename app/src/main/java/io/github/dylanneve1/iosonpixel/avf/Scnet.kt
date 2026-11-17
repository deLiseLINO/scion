package io.github.dylanneve1.iosonpixel.avf

import android.system.Os
import io.github.dylanneve1.iosonpixel.QemuNet
import io.github.dylanneve1.iosonpixel.VmState
import java.io.File

/**
 * The guest's network with the AVF backend (the Network setting, docs/NETWORKING.md). The phone's
 * crosvm can't be given a network card (`--net` is refused), but every AVF guest has a virtio
 * socket device. So the guest kernel listens on [PORT] (boot-arg `virtio_net_vsock=`, scion-kernel
 * hakios.virtio_net.c) and puts en0's frames on that stream; this connects to it
 * ([AvfApi.Vm.connectVsock]) and hands the socket to libslirp (native/scnet.c), which gives the
 * guest DHCP, DNS and NAT through this app's own sockets. The frames on the stream: a 32-bit
 * big-endian length, then the Ethernet frame, both ways.
 *
 * The guest listens only once its kernel is up, and a stream ends with the VM (or if the guest
 * resets it), so connecting is tried again every [RETRY_MS] until [stop].
 */
class Scnet(private val resolver: QemuNet.Resolver, private val resolvConf: File, private val log: (String) -> Unit) {
    @Volatile private var stopping = false
    private var thread: Thread? = null

    /** Follows the phone's DNS servers and keeps the guest connected; returns at once. */
    fun start(vm: AvfApi.Vm) {
        unavailable?.let { log("error: avf: network: no network for the guest: $it"); return }
        // libslirp reads the variable once, at its first DNS query (docs/NETWORKING.md, "libslirp on Android").
        Os.setenv(QemuNet.ENV_RESOLV_CONF, resolvConf.absolutePath, true)
        resolver.start()
        VmState.network("Network: waiting for the guest")
        thread = Thread({ serve(vm) }, "avf-scnet").apply { isDaemon = true; start() }
    }

    fun stop() {
        val t = thread ?: return
        stopping = true
        ScnetNative.stop()
        t.interrupt()
        t.join(STOP_WAIT_MS)
        resolver.stop()
        VmState.network(null)
    }

    private fun serve(vm: AvfApi.Vm) {
        var failures = 0
        try {
            while (!stopping) {
                val socket = try {
                    vm.connectVsock(PORT.toLong())
                } catch (e: AvfException) {
                    // Expected until the guest's kernel listens; said once, then every minute or so.
                    if (failures++ % 60 == 0) log("avf: network: the guest isn't listening on vsock port $PORT yet (${e.message})")
                    Thread.sleep(RETRY_MS)
                    continue
                }
                if (stopping) { socket.close(); break }
                failures = 0
                log("avf: network: connected to the guest on vsock port $PORT; slirp serves it (10.0.2.15, DNS through the phone's)")
                VmState.network("Network: guest connected")
                val why = ScnetNative.run(socket.detachFd())
                log("avf: network: the guest's stream ended: $why")
                VmState.network("Network: waiting for the guest")
                if (!stopping) Thread.sleep(RETRY_MS)
            }
        } catch (_: InterruptedException) {
        }
    }

    companion object {
        /** The guest's port (any number works; the boot-arg names it). */
        const val PORT = 5601
        val BOOT_ARG = "virtio_net_vsock=$PORT"
        private const val RETRY_MS = 1000L
        private const val STOP_WAIT_MS = 3000L

        /** libscnet.so is in this build (native/build-android.sh builds it with QEMU); else why not. */
        val unavailable: String? by lazy {
            runCatching { System.loadLibrary("scnet") }.exceptionOrNull()?.let { "libscnet.so: ${it.message}" }
        }
    }
}

/** native/scnet.c: one libslirp session at a time. */
internal object ScnetNative {
    /** Serves the guest on [fd] (taken: closed on return) until its stream ends or [stop]; why it ended, with counts. */
    @JvmStatic external fun run(fd: Int): String

    @JvmStatic external fun stop()
}
