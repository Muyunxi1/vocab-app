package com.vocab.vocab_app

import android.app.Application
import androidx.work.Configuration
import androidx.work.Configuration.Provider

/**
 * 数字墨水模型下载经 ML Kit model-downloader 调度到 WorkManager。
 * 启动期自动初始化的 WorkManagerInitializer 已在 Manifest 移除（规避 60 版启动闪退），
 * 这里由 Application 实现 Configuration.Provider，在首次 WorkManager.getInstance 时
 * 按需提供默认配置：既不会再抛 "WorkManager is not initialized properly"，
 * 也不在启动阶段主动建立后台调度。
 */
class AppApplication : Application(), Provider {
    override fun getWorkManagerConfiguration(): Configuration =
        Configuration.Builder().build()
}
