package org.tamx.termigate.data.network

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Codex security review (archived-docs/15_CODEX_SECURITY_REVIEW.md):
 * bare hostnames must default to `https://` so credentials and terminal
 * traffic are not silently sent in cleartext. Explicit `http://` URLs
 * are preserved verbatim — the LoginViewModel surfaces a confirmation
 * dialog before the request actually runs.
 */
class ServerUrlTest {

    @Test
    fun bare_host_defaults_to_https() {
        assertEquals(
            listOf("https://example.com", "https://example.com:8888"),
            candidateServerUrls("example.com")
        )
    }

    @Test
    fun bare_host_with_port_does_not_add_fallback() {
        assertEquals(
            listOf("https://example.com:8443"),
            candidateServerUrls("example.com:8443")
        )
    }

    @Test
    fun explicit_http_scheme_is_preserved() {
        assertEquals(
            listOf("http://example.com", "http://example.com:8888"),
            candidateServerUrls("http://example.com")
        )
    }

    @Test
    fun explicit_https_scheme_is_preserved() {
        assertEquals(
            listOf("https://example.com", "https://example.com:8888"),
            candidateServerUrls("https://example.com")
        )
    }

    @Test
    fun trailing_slash_is_trimmed() {
        assertEquals(
            listOf("https://example.com", "https://example.com:8888"),
            candidateServerUrls("example.com/")
        )
    }

    @Test
    fun bare_localhost_defaults_to_https() {
        // The release-build network security config still permits cleartext
        // for `localhost`, but defaulting to https keeps the policy
        // consistent: users targeting plain HTTP must type the scheme
        // explicitly so the cleartext warning fires.
        assertEquals(
            listOf("https://localhost", "https://localhost:8888"),
            candidateServerUrls("localhost")
        )
    }
}
