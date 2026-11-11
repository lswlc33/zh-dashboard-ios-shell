import java.security.MessageDigest
import org.jetbrains.kotlin.gradle.dsl.JvmTarget
import org.jetbrains.kotlin.gradle.plugin.mpp.apple.XCFramework

plugins {
    kotlin("multiplatform") version "2.4.20"
    kotlin("plugin.serialization") version "2.4.20"
    `maven-publish`
}

group = "io.github.lswlc33"
version = "1.0.0"

val isMac = System.getProperty("os.name").startsWith("Mac", ignoreCase = true)

kotlin {
    jvm {
        compilerOptions.jvmTarget.set(JvmTarget.JVM_17)
    }
    // Apple SDK / linker 只能来自 macOS 的 Xcode；Windows JVM 构建不下载或冒充 Apple 产物。
    if (isMac) {
        val framework = XCFramework("ZeehoShared")
        listOf(iosArm64(), iosSimulatorArm64()).forEach { target ->
            target.binaries.framework {
                baseName = "ZeehoShared"
                isStatic = true
                framework.add(this)
            }
        }
    }
    sourceSets {
        commonMain.dependencies {
            implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.11.0")
            implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.12.0")
            implementation("io.ktor:ktor-client-core:3.6.1")
        }
        commonTest.dependencies { implementation(kotlin("test")) }
        jvmMain.dependencies { implementation("io.ktor:ktor-client-okhttp:3.6.1") }
        jvmTest.dependencies {
            implementation(kotlin("test-junit"))
            implementation("io.ktor:ktor-client-mock:3.6.1")
            implementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.11.0")
        }
        if (isMac) {
            iosMain.dependencies { implementation("io.ktor:ktor-client-darwin:3.6.1") }
        }
    }
}

// Android includeBuild("../native-shared") 可按 group + rootProject.name 替换并选择 JVM jar，完全不依赖 AGP/SDK。
publishing.publications.withType<MavenPublication>().configureEach {
    if (name == "jvm") artifactId = "zeeho-native-shared"
    // 根 metadata 与 JVM 发布不能占同一个 GAV；Android 需要的是上面的纯 JVM 模块。
    if (name == "kotlinMultiplatform") artifactId = "zeeho-native-shared-kmp"
}

val jvmTarget = kotlin.targets.getByName("jvm") as org.jetbrains.kotlin.gradle.targets.jvm.KotlinJvmTarget
val mainRuntimeFiles = jvmTarget.compilations.getByName("main").runtimeDependencyFiles
val sharedJvmJar = tasks.named<Jar>("jvmJar")
tasks.register("writeNativeTestClasspath") {
    dependsOn(sharedJvmJar)
    val output = layout.buildDirectory.file("native-test-runtime-classpath.txt")
    val manifest = layout.buildDirectory.file("native-test-inputs.json")
    val sourceInputs = fileTree("src") { include("commonMain/**/*.kt", "jvmMain/**/*.kt") } + files(
        "build.gradle.kts", "settings.gradle.kts", "gradle.properties",
        "gradle/wrapper/gradle-wrapper.properties", "gradle/wrapper/gradle-wrapper.jar", "gradlew", "gradlew.bat"
    )
    inputs.files(mainRuntimeFiles, sharedJvmJar.flatMap { it.archiveFile }, sourceInputs)
    outputs.files(output, manifest)
    doLast {
        val jar = sharedJvmJar.get().archiveFile.get().asFile
        val entries = (listOf(jar) + mainRuntimeFiles.files).distinctBy { it.absolutePath }
        check(entries.all { it.exists() }) { "Native test runtime input missing; build the real JVM artifact first." }
        output.get().asFile.apply {
            parentFile.mkdirs()
            writeText(entries.joinToString("\n", postfix = "\n") { it.absolutePath }, Charsets.UTF_8)
        }
        fun hash(file: File): String = MessageDigest.getInstance("SHA-256").digest(file.readBytes()).joinToString("") { "%02x".format(it) }
        fun quote(text: String): String = "\"" + text.replace("\\", "\\\\").replace("\"", "\\\"") + "\""
        fun record(file: File): String = "{\"path\":" + quote(file.absolutePath) + ",\"sha256\":" + quote(hash(file)) + ",\"mtimeMs\":" + file.lastModified() + "}"
        manifest.get().asFile.writeText("{\"version\":1,\"jar\":" + record(jar) + ",\"sources\":[" + sourceInputs.files.sortedBy { it.absolutePath }.joinToString(",") { record(it) } + "]}\n", Charsets.UTF_8)
    }
}

tasks.withType<Test>().configureEach {
    testLogging { events("failed", "skipped"); exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL }
}

if (!isMac) {
    logger.lifecycle("ZeehoShared: JVM available; iOS arm64/simulator frameworks require macOS + Xcode (not built on this host).")
    listOf(
        "linkDebugFrameworkIosArm64", "linkReleaseFrameworkIosArm64",
        "linkDebugFrameworkIosSimulatorArm64", "linkReleaseFrameworkIosSimulatorArm64",
        "assembleZeehoSharedDebugXCFramework", "assembleZeehoSharedReleaseXCFramework",
        "embedAndSignAppleFrameworkForXcode"
    ).forEach { taskName ->
        tasks.register(taskName) {
            group = "build"
            doLast { throw GradleException("ZeehoShared iOS framework NOT built: macOS with Xcode is required. Run $taskName on a Mac.") }
        }
    }
}
