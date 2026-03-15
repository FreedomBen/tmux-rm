package org.tamx.termigate.data.repository

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject
import javax.inject.Singleton

@Singleton
class AppPreferences @Inject constructor(
    @ApplicationContext private val context: Context
) {
    companion object {
        private const val PREFS_NAME = "termigate_prefs"
        private const val ENCRYPTED_PREFS_NAME = "termigate_secure_prefs"
        private const val KEY_SERVER_URL = "server_url"
        private const val KEY_LAST_USERNAME = "last_username"
        private const val KEY_AUTH_TOKEN = "auth_token"
    }

    private val prefs: SharedPreferences by lazy {
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    }

    private val encryptedPrefs: SharedPreferences by lazy {
        val masterKey = MasterKey.Builder(context)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        EncryptedSharedPreferences.create(
            context,
            ENCRYPTED_PREFS_NAME,
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
        )
    }

    var serverUrl: String?
        get() = prefs.getString(KEY_SERVER_URL, null)
        set(value) = prefs.edit().putString(KEY_SERVER_URL, value).apply()

    var lastUsername: String?
        get() = prefs.getString(KEY_LAST_USERNAME, null)
        set(value) = prefs.edit().putString(KEY_LAST_USERNAME, value).apply()

    var authToken: String?
        get() = encryptedPrefs.getString(KEY_AUTH_TOKEN, null)
        set(value) {
            if (value != null) {
                encryptedPrefs.edit().putString(KEY_AUTH_TOKEN, value).apply()
            } else {
                encryptedPrefs.edit().remove(KEY_AUTH_TOKEN).apply()
            }
        }
}
