fn main() {
    println!("cargo:rerun-if-changed=i18n");

    #[cfg(target_os = "macos")]
    {
        println!("cargo:rerun-if-changed=src/connection_backend/macos/native.h");
        println!("cargo:rerun-if-changed=src/connection_backend/macos/native.m");
        println!("cargo:rustc-link-lib=framework=Foundation");
        println!("cargo:rustc-link-lib=framework=IOBluetooth");

        cc::Build::new()
            .file("src/connection_backend/macos/native.m")
            .flag("-fobjc-arc")
            .flag("-fmodules")
            .compile("openscq30_macos_bluetooth");
    }
}
