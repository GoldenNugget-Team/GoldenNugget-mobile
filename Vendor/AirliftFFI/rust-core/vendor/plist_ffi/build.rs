// Jackson Coxson

use std::env;

fn main() {
    println!("cargo::rerun-if-changed=src/");
    println!("cargo::rerun-if-changed=plist.h");
    let crate_dir = env::var("CARGO_MANIFEST_DIR").unwrap();

    cbindgen::Builder::new()
        .with_crate(crate_dir)
        .with_header("// Jackson Coxson\n// Bindings to plist_ffi")
        .with_language(cbindgen::Language::C)
        .with_sys_include("stdio.h")
        .generate()
        .expect("Unable to generate bindings")
        .write_to_file("plist.h");

    #[cfg(feature = "danger")]
    cc::Build::new().file("src/shims.c").compile("plist_shims");
}
