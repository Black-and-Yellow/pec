plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseSigningValues = mapOf(
    "storeFile" to providers.environmentVariable("FINGUARD_KEYSTORE_PATH").orNull,
    "storePassword" to providers.environmentVariable("FINGUARD_KEYSTORE_PASSWORD").orNull,
    "keyAlias" to providers.environmentVariable("FINGUARD_KEY_ALIAS").orNull,
    "keyPassword" to providers.environmentVariable("FINGUARD_KEY_PASSWORD").orNull,
)
val suppliedReleaseSigningValues = releaseSigningValues.values.count { !it.isNullOrBlank() }
if (suppliedReleaseSigningValues != 0 && suppliedReleaseSigningValues != releaseSigningValues.size) {
    throw GradleException(
        "Set all FINGUARD_KEYSTORE_PATH, FINGUARD_KEYSTORE_PASSWORD, " +
            "FINGUARD_KEY_ALIAS and FINGUARD_KEY_PASSWORD values together.",
    )
}
val hasReleaseSigning = suppliedReleaseSigningValues == releaseSigningValues.size

android {
    namespace = "org.pec.finguard"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "org.pec.finguard"
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseSigning) {
            create("release") {
                storeFile = file(releaseSigningValues.getValue("storeFile")!!)
                storePassword = releaseSigningValues.getValue("storePassword")
                keyAlias = releaseSigningValues.getValue("keyAlias")
                keyPassword = releaseSigningValues.getValue("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // Debug signing keeps local hackathon APK builds installable. CI/release
            // builds use the environment-backed release config when supplied.
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}
