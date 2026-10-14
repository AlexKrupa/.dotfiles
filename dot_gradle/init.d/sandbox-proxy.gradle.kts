// Java ignores HTTPS_PROXY. The Claude Code sandbox sets HTTPS_PROXY with a new port and password
// for each session, so this script gives the proxy of the current build to Java.
// A daemon can run builds for different sessions. Thus the script also removes the properties when
// HTTPS_PROXY is not set.
val proxyKeys = listOf("proxyHost", "proxyPort", "proxyUser", "proxyPassword")
val proxy = System.getenv("HTTPS_PROXY")?.let(java.net.URI::create)

for (scheme in listOf("http", "https")) {
    if (proxy == null) {
        proxyKeys.forEach { System.clearProperty("$scheme.$it") }
        continue
    }
    val (user, password) = proxy.userInfo?.split(":", limit = 2) ?: listOf(null, null)
    System.setProperty("$scheme.proxyHost", proxy.host)
    System.setProperty("$scheme.proxyPort", proxy.port.toString())
    if (user != null) System.setProperty("$scheme.proxyUser", user) else System.clearProperty("$scheme.proxyUser")
    if (password != null) {
        System.setProperty("$scheme.proxyPassword", password)
    } else {
        System.clearProperty("$scheme.proxyPassword")
    }
}
