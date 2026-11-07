fn main() {
    let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    if target_os != "windows" && target_os != "ios" {
        return;
    }
    let sources = [
        "crypto_core/sp_error.c",
        "crypto_core/sp_stream.c",
        "crypto_core/mp4_cenc.c",
        "crypto_core/sp_aes.c",
        "third_party/tiny_aes/aes.c",
    ];
    let mut build = cc::Build::new();
    build
        .include("../native/crypto_core")
        .std("c11")
        .define("CBC", "0")
        .define("CTR", "0")
        .define("ECB", "1");
    if target_os == "windows" {
        build.flag_if_supported("/experimental:c11atomics");
    }
    for source in sources {
        let path = format!("../native/{source}");
        println!("cargo:rerun-if-changed={path}");
        build.file(path);
    }
    println!("cargo:rerun-if-changed=../native/crypto_core/sp_crypto.h");
    build.compile("sp_crypto_core");
}
