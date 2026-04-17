package org.tamx.termigate.data.network

private const val FALLBACK_PORT = 8888

private data class ServerUrlParts(
    val scheme: String,
    val host: String,
    val port: Int?,
    val path: String,
)

private fun parseServerUrl(input: String): ServerUrlParts {
    var s = input.trim().trimEnd('/')
    val schemeIdx = s.indexOf("://")
    val scheme: String
    if (schemeIdx >= 0) {
        scheme = s.substring(0, schemeIdx).lowercase()
        s = s.substring(schemeIdx + 3)
    } else {
        scheme = "http"
    }
    val pathIdx = s.indexOf('/')
    val authority: String
    val path: String
    if (pathIdx >= 0) {
        authority = s.substring(0, pathIdx)
        path = s.substring(pathIdx)
    } else {
        authority = s
        path = ""
    }
    val host: String
    val port: Int?
    if (authority.startsWith("[")) {
        val bracketEnd = authority.indexOf(']')
        if (bracketEnd >= 0 && bracketEnd + 1 < authority.length && authority[bracketEnd + 1] == ':') {
            host = authority.substring(0, bracketEnd + 1)
            port = authority.substring(bracketEnd + 2).toIntOrNull()
        } else {
            host = authority
            port = null
        }
    } else {
        val colonIdx = authority.lastIndexOf(':')
        val parsedPort = if (colonIdx >= 0) authority.substring(colonIdx + 1).toIntOrNull() else null
        if (parsedPort != null) {
            host = authority.substring(0, colonIdx)
            port = parsedPort
        } else {
            host = authority
            port = null
        }
    }
    return ServerUrlParts(scheme, host, port, path)
}

/**
 * Returns the ordered list of base URLs to try for a user-entered server URL.
 *
 * If a port is specified, the single URL is returned verbatim. If no port is
 * specified, the scheme-default port is tried first, then port 8888 as a
 * fallback so users can reach the dev server without typing a port.
 */
fun candidateServerUrls(input: String): List<String> {
    val parts = parseServerUrl(input)
    if (parts.port != null) {
        return listOf("${parts.scheme}://${parts.host}:${parts.port}${parts.path}")
    }
    return listOf(
        "${parts.scheme}://${parts.host}${parts.path}",
        "${parts.scheme}://${parts.host}:$FALLBACK_PORT${parts.path}",
    )
}
