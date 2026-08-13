import java.net.URI
import java.util.Base64

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

val allowDemoRelease = providers.environmentVariable("FINGUARD_ALLOW_DEMO_RELEASE")
    .orNull
    ?.equals("true", ignoreCase = true) == true
val dartDefines = providers.gradleProperty("dart-defines").orNull
    ?.split(',')
    ?.mapNotNull { encoded ->
        runCatching {
            String(Base64.getDecoder().decode(encoded), Charsets.UTF_8)
        }.getOrNull()
    }
    ?.associate { value -> value.substringBefore('=') to value.substringAfter('=', "") }
    .orEmpty()
val releaseApiBaseUrl = dartDefines["API_BASE_URL"]?.trim().orEmpty()

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

fun requireReleaseConfiguration() {
    val releaseApiUri = runCatching { URI(releaseApiBaseUrl) }.getOrNull()
    if (
        releaseApiUri == null ||
        releaseApiUri.scheme?.lowercase() != "https" ||
        releaseApiUri.host.isNullOrBlank() ||
        releaseApiUri.userInfo != null ||
        releaseApiUri.query != null ||
        releaseApiUri.fragment != null
    ) {
        throw GradleException(
            "Android release builds require --dart-define=API_BASE_URL=https://<host>[/base-path].",
        )
    }
    if (!hasReleaseSigning && !allowDemoRelease) {
        throw GradleException(
            "Android release signing is not configured. Set all FINGUARD_KEY* variables, " +
                "or set FINGUARD_ALLOW_DEMO_RELEASE=true only for a non-distributable CI/local build.",
        )
    }
}

// Aggregate tasks such as `assemble` do not contain "release" in the requested
// name even though their resolved graph includes assembleRelease. Validate the
// graph before any release-producing task can execute.
gradle.taskGraph.whenReady {
    if (allTasks.any { task -> task.name.contains("release", ignoreCase = true) }) {
        requireReleaseConfiguration()
    }
}

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
            // A debug-signed release is permitted only when the caller explicitly
            // opts into the non-distributable CI/local demo path above.
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
