allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

// Toolchain shim: camera_android_camerax (camera-core 1.5.x) exposes
// androidx.concurrent.futures.CallbackToFutureAdapter in its public API, but
// only depends on it transitively at runtime. Under AGP 9 javac must see that
// class to attach its @NonNull type annotations, or the plugin fails to compile
// ("class file for ...CallbackToFutureAdapter not found"). Put it on that
// module's compile classpath explicitly.
subprojects {
    if (name == "camera_android_camerax") {
        // Defer until the Android library plugin creates the `implementation`
        // configuration, then add the dependency (afterEvaluate is too late here
        // because of the evaluationDependsOn above).
        plugins.withId("com.android.library") {
            dependencies.add("implementation", "androidx.concurrent:concurrent-futures:1.2.0")
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
