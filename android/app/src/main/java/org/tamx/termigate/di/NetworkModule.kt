package org.tamx.termigate.di

import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import io.ktor.client.HttpClient
import io.ktor.client.engine.okhttp.OkHttp
import io.ktor.client.plugins.contentnegotiation.ContentNegotiation
import io.ktor.serialization.kotlinx.json.json
import kotlinx.serialization.json.Json
import okhttp3.OkHttpClient
import org.tamx.termigate.data.network.ApiClient
import org.tamx.termigate.data.network.AuthPlugin
import org.tamx.termigate.data.network.AuthPluginConfig
import org.tamx.termigate.data.repository.AppPreferences
import java.util.concurrent.TimeUnit
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
object NetworkModule {

    @Provides
    @Singleton
    fun provideOkHttpClient(): OkHttpClient {
        return OkHttpClient.Builder()
            .connectTimeout(15, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .writeTimeout(15, TimeUnit.SECONDS)
            .pingInterval(30, TimeUnit.SECONDS)
            .build()
    }

    @Provides
    @Singleton
    fun provideAuthPluginConfig(prefs: AppPreferences): AuthPluginConfig {
        return AuthPluginConfig().apply {
            tokenProvider = { prefs.authToken }
        }
    }

    @Provides
    @Singleton
    fun provideHttpClient(
        okhttp: OkHttpClient,
        authPluginConfig: AuthPluginConfig
    ): HttpClient {
        return HttpClient(OkHttp) {
            engine {
                preconfigured = okhttp
            }
            install(ContentNegotiation) {
                json(Json {
                    ignoreUnknownKeys = true
                    isLenient = true
                    encodeDefaults = true
                })
            }
            install(AuthPlugin) {
                tokenProvider = authPluginConfig.tokenProvider
            }
        }
    }

    @Provides
    @Singleton
    fun provideApiClient(
        httpClient: HttpClient,
        prefs: AppPreferences
    ): ApiClient {
        return ApiClient(
            client = httpClient,
            serverUrl = { prefs.serverUrl ?: "" }
        )
    }
}
