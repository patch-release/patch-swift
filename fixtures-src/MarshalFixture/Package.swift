// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MarshalFixture",
    targets: [
        .executableTarget(
            name: "MarshalFixture",
            linkerSettings: [
                .unsafeFlags([
                    "-Xclang-linker", "-mexec-model=reactor",
                    "-Xlinker", "--export-if-defined=patch_malloc",
                    "-Xlinker", "--export-if-defined=patch_free",
                    "-Xlinker", "--export-if-defined=echo_len",
                    "-Xlinker", "--export-if-defined=sum_bytes",
                    "-Xlinker", "--export-if-defined=add_i64",
                    "-Xlinker", "--export-if-defined=mul_f64",
                    "-Xlinker", "--export-if-defined=not_bool",
                    "-Xlinker", "--export-if-defined=store_result",
                    "-Xlinker", "--export-if-defined=last_result_ptr",
                    "-Xlinker", "--export-if-defined=last_result_len",
                    "-Xlinker", "--export-if-defined=reverse_packed",
                    "-Xlinker", "--export-if-defined=identity_packed",
                    "-Xlinker", "--export-if-defined=_pv_ProfileCard_primaryFontSize",
                    "-Xlinker", "--export-if-defined=_pv_ProfileCard_greeting",
                    "-Xlinker", "--export-if-defined=_pv_ProfileCard_rowHeight",
                ])
            ]
        )
    ]
)
