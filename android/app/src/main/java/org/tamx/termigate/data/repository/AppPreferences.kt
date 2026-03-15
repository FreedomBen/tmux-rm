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
        private const val KEY_FONT_SIZE = "font_size"
        private const val KEY_KEEP_SCREEN_ON = "keep_screen_on"
        private const val KEY_VIBRATE_ON_KEY = "vibrate_on_key"
        private const val KEY_QUICK_ACTIONS_CACHE = "quick_actions_cache"
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
        set(value) {
            val normalized = value?.trimEnd('/')?.let { url ->
                if (url.isNotEmpty() && !url.startsWith("http://") && !url.startsWith("https://")) {
                    "http://$url"
                } else {
                    url
                }
            }
            prefs.edit().putString(KEY_SERVER_URL, normalized).apply()
        }

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

    var fontSize: Int
        get() = prefs.getInt(KEY_FONT_SIZE, 14)
        set(value) = prefs.edit().putInt(KEY_FONT_SIZE, value).apply()

    var keepScreenOn: Boolean
        get() = prefs.getBoolean(KEY_KEEP_SCREEN_ON, true)
        set(value) = prefs.edit().putBoolean(KEY_KEEP_SCREEN_ON, value).apply()

    var vibrateOnKey: Boolean
        get() = prefs.getBoolean(KEY_VIBRATE_ON_KEY, true)
        set(value) = prefs.edit().putBoolean(KEY_VIBRATE_ON_KEY, value).apply()

    var quickActionsCache: String?
        get() = prefs.getString(KEY_QUICK_ACTIONS_CACHE, null)
        set(value) = prefs.edit().putString(KEY_QUICK_ACTIONS_CACHE, value).apply()
}
