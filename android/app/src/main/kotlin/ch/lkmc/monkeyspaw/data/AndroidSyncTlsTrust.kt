package ch.lkmc.monkeyspaw.data

import ch.lkmc.monkeyspaw.core.ports.HttpTransportError
import kotlinx.coroutines.CancellationException
import java.security.KeyStore
import javax.net.ssl.TrustManagerFactory
import javax.net.ssl.X509TrustManager

/** An explicit AndroidCAStore includes enabled system and user anchors without changing app-wide trust. */
internal class AndroidSyncTlsTrust(
    private val caStore: () -> KeyStore = { KeyStore.getInstance("AndroidCAStore").apply { load(null) } },
) : SyncTlsTrustFactory {
    override fun create(): X509TrustManager = try {
        val factory = TrustManagerFactory.getInstance(TrustManagerFactory.getDefaultAlgorithm())
        factory.init(caStore())
        factory.trustManagers.single() as X509TrustManager
    } catch (cancelled: CancellationException) {
        throw cancelled
    } catch (_: Exception) {
        throw HttpTransportError.NetworkFailure
    }
}
