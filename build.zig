// SPDX-License-Identifier: BSD-2-Clause

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("fluxion_net", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The page's half, for a program that runs in a browser: installed beside
    // its module as `fluxion-net.js`. Taken by name:
    //   dep.namedLazyPath("fluxion-net.js")
    b.addNamedLazyPath("fluxion-net.js", b.path("src/fluxion-net.js"));

    const tests = b.addTest(.{ .name = "fluxion-net-tests", .root_module = mod });
    b.step("test", "Run the tests").dependOn(&b.addRunArtifact(tests).step);
}
