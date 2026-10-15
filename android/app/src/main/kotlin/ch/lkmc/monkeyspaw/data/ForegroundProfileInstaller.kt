package ch.lkmc.monkeyspaw.data

import android.content.Context
import androidx.profileinstaller.ProfileInstallerInitializer
import androidx.startup.AppInitializer
import dagger.hilt.android.qualifiers.ApplicationContext
import javax.inject.Inject

/** Retain once-per-process profile installation for the launcher, without IME startup work. */
internal class ForegroundProfileInstaller @Inject constructor(@ApplicationContext private val context: Context) {
    fun initialize() {
        AppInitializer.getInstance(context).initializeComponent(ProfileInstallerInitializer::class.java)
    }
}
