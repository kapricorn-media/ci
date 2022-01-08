const std = @import("std");

const zig_bearssl_build = @import("deps/zig-http/deps/zig-bearssl/build.zig");
const zig_http_build = @import("deps/zig-http/build.zig");

const PROJECT_NAME = "ci";

pub fn build(b: *std.build.Builder) void
{
    const mode = b.standardReleaseOptions();
    const target = b.standardTargetOptions(.{});

    const server = b.addExecutable(PROJECT_NAME, "src/server_main.zig");
    server.setBuildMode(mode);
    server.setTarget(target);
    zig_bearssl_build.addLib(server, target, "deps/zig-http/deps/zig-bearssl");
    zig_http_build.addLibClient(server, target, "deps/zig-http");
    zig_http_build.addLibCommon(server, target, "deps/zig-http");
    zig_http_build.addLibServer(server, target, "deps/zig-http");
    server.linkLibC();
    const installDirRoot = std.build.InstallDir {
        .custom = "",
    };
    server.override_dest_dir = installDirRoot;
    server.install();

    const installDirScripts = std.build.InstallDir {
        .custom = "scripts",
    };
    b.installDirectory(.{
        .source_dir = "scripts",
        .install_dir = installDirScripts,
        .install_subdir = "",
    });

    const runTests = b.step("test", "Run tests");

    const testSrcs = [_][]const u8 {
        "src/server_main.zig",
    };
    for (testSrcs) |src| {
        const tests = b.addTest(src);
        tests.setBuildMode(mode);
        tests.setTarget(target);
        runTests.dependOn(&tests.step);
    }
}
