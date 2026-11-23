fn main() {
    // napi v2 resolves Windows symbols from the Electron process at runtime.
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("windows") {
        napi_build::setup();
    }
}
