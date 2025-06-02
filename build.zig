const std = @import("std");

const version: std.SemanticVersion = .{ .major = 4, .minor = 0, .patch = 2 };

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const upstream = b.dependency("monocypher", .{});

    const linkage = b.option(std.builtin.LinkMode, "linkage", "Link mode") orelse .static;
    const strip = b.option(bool, "strip", "Omit debug information");
    const pic = b.option(bool, "pie", "Produce Position Independent Code");

    const enable_ed25519 = b.option(bool, "enable_ed25519", "Enable monocypher-ed25519 (defaults to false)") orelse false;
    const disable_blake2_unrolling = b.option(bool, "disable_blake2_unrolling", "Disable blake2 loop unrolling") orelse switch (target.result.cpu.arch) {
        // This is a best-effort guess. If you see different results, then
        // free to send a patch :^)
        .x86_64, .x86, .aarch64, .arm, .mips64, .riscv64 => false,
        else => true,
    };

    const flags = &.{"-std=c99"};

    const monocypher_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .pic = pic,
    });
    if (disable_blake2_unrolling) {
        monocypher_mod.addCMacro("BLAKE2_NO_UNROLLING", "");
    }
    monocypher_mod.addIncludePath(upstream.path("src"));
    monocypher_mod.addCSourceFiles(.{
        .root = upstream.path("src"),
        .files = if (!enable_ed25519) &.{
            "monocypher.c",
        } else &.{
            "monocypher.c",
            "optional/monocypher-ed25519.c",
        },
        .flags = flags,
    });

    const monocypher = b.addLibrary(.{
        .linkage = linkage,
        .name = "monocypher",
        .root_module = monocypher_mod,
        .version = version,
    });
    b.installArtifact(monocypher);
    monocypher.installHeader(upstream.path("src/monocypher.h"), "monocypher.h");
    if (enable_ed25519) {
        monocypher.installHeader(upstream.path("src/optional/monocypher-ed25519.h"), "monocypher-ed25519.h");
    }

    {
        const test_step = b.step("test", "Run tests");
        if (!enable_ed25519) {
            try test_step.addError("-Denable_ed25519 is required to run tests", .{});
        }

        const mod_options: std.Build.Module.CreateOptions = .{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        };

        const utils_mod = b.createModule(mod_options);
        utils_mod.addIncludePath(upstream.path("tests"));
        utils_mod.addCSourceFile(.{
            .file = upstream.path("tests/utils.c"),
            .flags = flags,
        });

        const utils = b.addLibrary(.{
            .name = "utils",
            .root_module = utils_mod,
        });

        const test_sources: []const []const u8 = &.{
            "test.c",
            "tis-ci.c",
            "ctgrind.c",
        };

        for (test_sources) |test_source| {
            const test_mod = b.createModule(mod_options);
            test_mod.linkLibrary(monocypher);
            test_mod.linkLibrary(utils);
            test_mod.addIncludePath(upstream.path("tests"));
            test_mod.addCSourceFiles(.{
                .root = upstream.path("tests"),
                .files = &.{test_source},
                .flags = flags,
            });

            const test_exe = b.addExecutable(.{
                .name = std.fs.path.stem(test_source),
                .root_module = test_mod,
            });

            const run_test = b.addRunArtifact(test_exe);
            test_step.dependOn(&run_test.step);
            run_test.expectExitCode(0);
        }
    }
}
