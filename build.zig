//! gameport build graph.
//!
//! Targets:
//!   gameport-agent           headless debugging host (shared game + AgentBackend), never links SDL
//!   gameport-sdl             SDL interactive host (Linux, Windows)
//!   gameport-test            scenario and comparison runner
//!   gameport-sdl-standalone  the SDL host with the game's files built in (needs -Dembed-assets)
//!   web/                     the browser build: gameport.wasm, index.html, gameport.js
//! Steps: `zig build` installs the first three binaries; `agent`, `sdl` and `test-runner` install
//! one of them; `standalone` installs the fourth with its manifest; `web` installs the browser
//! build and checks its module's imports; `web-check` checks the page's helper functions against
//! compiler-rt (it needs Node.js); `test` runs the unit tests of every module; `test-public` and
//! `test-reference` run the two scenario suites; `smoke` runs the agent host over a short synthetic
//! script; `verify` checks that the agent binary has no SDL dependency.
const std = @import("std");
const builtin = @import("builtin");

/// The SDL2 release that the Linux host is built and tested against.
pub const pinned_sdl_version = "2.32.4";

/// The SDL2 release that a Windows build links: the `sdl2` package of build.zig.zon,
/// allyourcodebase's SDL2 built from source by Zig. Keep it with the package's version.
pub const package_sdl_version = "2.32.10";

const SdlLinkage = enum { static, dynamic };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const sdl_linkage = b.option(SdlLinkage, "sdl-linkage", "Link the system SDL2 as a static archive or as a shared library (default: static). A Windows build always links its SDL2 statically") orelse .static;
    const embed_assets = b.option([]const u8, "embed-assets", "CD image or game directory to build into the standalone executable");

    const versions = b.addOptions();
    versions.addOption([]const u8, "zig", builtin.zig_version_string);

    // Shared code: platform contracts, workflows, providers, the game. No host library, no libc.
    const shared = b.addModule("gameport", .{
        .root_source_file = b.path("src/shared/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    shared.addOptions("build_versions", versions);

    // Test kit: fixtures, comparison, verdicts, reports. It depends only on std.
    const testkit = b.addModule("testkit", .{
        .root_source_file = b.path("src/testkit/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Agent platform: scripted devices, controlled time, captured output, JSON host protocol.
    const agent = b.addModule("agent", .{
        .root_source_file = b.path("src/agent/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "gameport", .module = shared }},
    });

    // Native I/O: directory and ISO asset sources, directory storage, the workflow executor over
    // std.Io. The executables import it; `gameport` never does.
    const native = b.addModule("native", .{
        .root_source_file = b.path("src/native/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "gameport", .module = shared }},
    });

    // SDL platform: the only module that links SDL2, and thus libc. It imports `native` for the
    // asset and save providers of the host, which link nothing.
    const sdl = b.addModule("sdl", .{
        .root_source_file = b.path("src/sdl/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "gameport", .module = shared },
            .{ .name = "native", .module = native },
        },
    });
    if (target.result.os.tag == .windows)
        linkPackagedSdl(b, sdl, target, versions)
    else
        linkSdl(b, sdl, sdl_linkage, versions);

    const agent_exe = b.addExecutable(.{
        .name = "gameport-agent",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/agent/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gameport", .module = shared },
                .{ .name = "agent", .module = agent },
                .{ .name = "native", .module = native },
            },
        }),
    });

    const sdl_exe = b.addExecutable(.{
        .name = "gameport-sdl",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sdl/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "gameport", .module = shared },
                .{ .name = "sdl", .module = sdl },
                .{ .name = "native", .module = native },
                .{ .name = "game_assets", .module = b.createModule(.{
                    .root_source_file = b.path("src/sdl/external_assets.zig"),
                }) },
            },
        }),
    });

    const runner_exe = b.addExecutable(.{
        .name = "gameport-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/testrunner/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "gameport", .module = shared },
                .{ .name = "agent", .module = agent },
                .{ .name = "native", .module = native },
                .{ .name = "testkit", .module = testkit },
            },
        }),
    });

    b.installArtifact(agent_exe);
    b.installArtifact(sdl_exe);
    b.installArtifact(runner_exe);

    b.step("agent", "Build and install only the headless agent host").dependOn(&b.addInstallArtifact(agent_exe, .{}).step);
    b.step("sdl", "Build and install only the SDL host").dependOn(&b.addInstallArtifact(sdl_exe, .{}).step);
    b.step("test-runner", "Build and install only the scenario runner").dependOn(&b.addInstallArtifact(runner_exe, .{}).step);

    // The standalone executable: the SDL host with the game's files built in. The files come from
    // a CD image or a game directory at build time, and only those listed in
    // tools/embedded-assets.txt. This is the one step that reads the original's files.
    const standalone_step = b.step("standalone", "Build and install the SDL host with the game's files built in (requires -Dembed-assets)");
    if (embed_assets) |source| {
        // The packer runs on the build machine even when the game targets another platform.
        const pack_shared = b.createModule(.{
            .root_source_file = b.path("src/shared/root.zig"),
            .target = b.graph.host,
            .optimize = .safe,
        });
        pack_shared.addOptions("build_versions", versions);
        const pack_native = b.createModule(.{
            .root_source_file = b.path("src/native/root.zig"),
            .target = b.graph.host,
            .optimize = .safe,
            .imports = &.{.{ .name = "gameport", .module = pack_shared }},
        });
        const packer = b.addExecutable(.{
            .name = "gameport-embed-assets",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/embed_assets.zig"),
                .target = b.graph.host,
                .optimize = .safe,
                .imports = &.{
                    .{ .name = "gameport", .module = pack_shared },
                    .{ .name = "native", .module = pack_native },
                },
            }),
        });
        const pack = b.addRunArtifact(packer);
        pack.addArg(source);
        pack.setCwd(b.path("."));
        // The source is an external input. The packer always reads it again, so an edited or
        // removed file cannot reuse an earlier bundle.
        pack.has_side_effects = true;
        const bundle = pack.addOutputDirectoryArg("embedded-files");
        const standalone = b.addExecutable(.{
            .name = "gameport-sdl-standalone",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/sdl/main.zig"),
                .target = target,
                .optimize = optimize,
                .strip = optimize != .debug,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "sdl", .module = sdl },
                    .{ .name = "game_assets", .module = b.createModule(.{
                        .root_source_file = bundle.path(b, "assets.zig"),
                        .imports = &.{.{ .name = "gameport", .module = shared }},
                    }) },
                },
            }),
        });
        standalone_step.dependOn(&b.addInstallArtifact(standalone, .{}).step);
        standalone_step.dependOn(&b.addInstallFile(bundle.path(b, "manifest.json"), "share/gameport/embedded-manifest.json").step);
    } else {
        standalone_step.dependOn(&b.addFail("standalone requires -Dembed-assets=PATH (a CD image or a game directory)").step);
    }

    // The browser build (src/web): the shared game as a WebAssembly module for a page, with the
    // page and its script. The module links no libc, and the script gives it its memory. Every
    // game file is in memory before the game starts, so the module needs no Asyncify pass.
    const web_step = b.step("web", "Build the browser build into <prefix>/web and check the module's imports");
    const web_optimize = b.option(std.builtin.OptimizeMode, "web-optimize", "Optimization mode of the WebAssembly module (default: small)") orelse .small;
    const web_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const web_shared = b.createModule(.{
        .root_source_file = b.path("src/shared/root.zig"),
        .target = web_target,
        .optimize = web_optimize,
    });
    web_shared.addOptions("build_versions", versions);
    const web_module = b.addExecutable(.{
        .name = "gameport",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/web/main.zig"),
            .target = web_target,
            .optimize = web_optimize,
            .imports = &.{.{ .name = "gameport", .module = web_shared }},
        }),
    });
    web_module.entry = .disabled;
    web_module.rdynamic = true;
    web_module.import_memory = true;
    // No compiler-rt (DESIGN.md 5.3): the functions of it that the game calls are imports, which
    // the script gives. The placeholder game calls one, `__multi3`, the 128-bit product in
    // `std.hash.Wyhash`. `web-check` checks the script's helpers against compiler-rt, and
    // `src/web/module_check.zig` checks the list of imports.
    web_module.bundle_compiler_rt = false;
    web_module.import_symbols = true;
    // The script reads these limits from the module's import. The stack is the size of a native
    // main thread's, because a game's values can be large.
    web_module.stack_size = 8 * 1024 * 1024;
    web_module.initial_memory = 16 * 1024 * 1024;
    web_module.max_memory = 1024 * 1024 * 1024;
    web_step.dependOn(&b.addInstallFileWithDir(web_module.getEmittedBin(), .prefix, "web/gameport.wasm").step);
    web_step.dependOn(&b.addInstallFileWithDir(b.path("src/web/index.html"), .prefix, "web/index.html").step);
    web_step.dependOn(&b.addInstallFileWithDir(b.path("src/web/gameport.js"), .prefix, "web/gameport.js").step);

    // The module's imports: its memory, the page's functions and the helpers, and nothing else.
    // The script and the module are copied next to a generated root, so `@embedFile` reaches
    // them.
    const web_files = b.addWriteFiles();
    _ = web_files.addCopyFile(b.path("src/web/gameport.js"), "gameport.js");
    _ = web_files.addCopyFile(web_module.getEmittedBin(), "gameport.wasm");
    const web_output = b.createModule(.{
        .root_source_file = web_files.add("web_output.zig",
            \\//! The browser build's script and module, for the check of the module's imports
            \\//! (generated by build.zig).
            \\pub const script_js: []const u8 = @embedFile("gameport.js");
            \\pub const module_wasm: []const u8 = @embedFile("gameport.wasm");
            \\
        ),
    });
    const module_check = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/web/module_check.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "web_output", .module = web_output }},
    }) });
    web_step.dependOn(&b.addRunArtifact(module_check).step);

    // `web-check`: the script's helpers against compiler-rt. A probe of the operations is built
    // with compiler-rt and without it, and Node runs both over the same inputs, the second with
    // the helpers of `gameport.js`.
    const web_check_step = b.step("web-check", "Check the browser build's helper functions against compiler-rt (needs Node.js)");
    const helpers_check = b.addSystemCommand(&.{"node"});
    helpers_check.addFileArg(b.path("src/web/helpers_check.cjs"));
    helpers_check.addFileArg(b.path("src/web/gameport.js"));
    for ([_]bool{ true, false }) |with_compiler_rt| {
        const probe = b.addExecutable(.{
            .name = if (with_compiler_rt) "probe-compiler-rt" else "probe-helpers",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/web/helpers_probe.zig"),
                .target = web_target,
                .optimize = web_optimize,
            }),
        });
        probe.entry = .disabled;
        probe.rdynamic = true;
        probe.import_memory = true;
        probe.bundle_compiler_rt = with_compiler_rt;
        probe.import_symbols = !with_compiler_rt;
        probe.initial_memory = 2 * 1024 * 1024;
        probe.max_memory = 2 * 1024 * 1024;
        helpers_check.addFileArg(probe.getEmittedBin());
    }
    web_check_step.dependOn(&helpers_check.step);

    // The parts of the browser build that run without a browser, for the unit tests.
    const web_parts = b.createModule(.{
        .root_source_file = b.path("src/web/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "gameport", .module = shared }},
    });

    // Unit tests of every module, the drivers of the runner included. The tests of the SDL module
    // link SDL2 as the host does.
    //
    // The runs have side effects, so the build never caches them: tests read committed data under
    // `tests/`, and the build graph does not know this. Without the flag, a cached success stays a
    // pass after one of those files changes.
    const test_step = b.step("test", "Run the unit tests of every module");
    const unit_modules = [_]*std.Build.Module{ shared, testkit, agent, native, sdl, runner_exe.root_module, web_parts };
    for (unit_modules) |m| {
        const t = b.addTest(.{ .root_module = m });
        const run = b.addRunArtifact(t);
        run.has_side_effects = true;
        test_step.dependOn(&run.step);
    }

    // A synthetic scenario through the agent host. It needs no game files and no display.
    const smoke = b.addRunArtifact(agent_exe);
    smoke.addArgs(&.{ "--script", "tests/public/scripts/smoke.jsonl", "--strict" });
    smoke.setCwd(b.path("."));
    smoke.expectExitCode(0);
    b.step("smoke", "Run the agent host over a short synthetic script").dependOn(&smoke.step);

    // The scenario suites. `test-public` uses only synthetic and redistributable fixtures.
    // `test-reference` compares against recordings of the original's behaviour, which are
    // committed under `tests/reference/data`.
    const public_run = b.addRunArtifact(runner_exe);
    public_run.addArgs(&.{ "run", "tests/public", "--root", "." });
    public_run.setCwd(b.path("."));
    public_run.has_side_effects = true;
    b.step("test-public", "Run the public scenario suite (synthetic and redistributable fixtures)").dependOn(&public_run.step);

    const reference_run = b.addRunArtifact(runner_exe);
    reference_run.addArgs(&.{ "run", "tests/reference", "--root", "." });
    reference_run.setCwd(b.path("."));
    reference_run.has_side_effects = true;
    b.step("test-reference", "Run the reference suite (recordings of the original's behaviour)").dependOn(&reference_run.step);

    // The agent binary must have no SDL dependency.
    const no_sdl = b.addSystemCommand(&.{ "sh", "tools/check_no_sdl.sh" });
    no_sdl.addArtifactArg(agent_exe);
    no_sdl.expectExitCode(0);
    b.step("verify", "Check the agent host binary links no SDL library").dependOn(&no_sdl.step);
}

/// Links SDL2 into `m`, and records the SDL2 version that pkg-config reports as the `sdl` build
/// option. Static linkage uses the archive that pkg-config names and the system libraries of its
/// static link line. Those libraries stay dynamic, because static builds of X11, Wayland or
/// PulseAudio are not practical. Dynamic linkage uses the shared library.
fn linkSdl(b: *std.Build, m: *std.Build.Module, linkage: SdlLinkage, versions: *std.Build.Step.Options) void {
    var code: u8 = 0;
    if (b.runAllowFail(&.{ "pkg-config", "--modversion", "sdl2" }, &code, .ignore)) |out| {
        const found = std.mem.trim(u8, out, " \t\r\n");
        versions.addOption([]const u8, "sdl", found);
    } else |_| {
        std.log.warn("pkg-config could not report the SDL2 version; the pin ({s}) is checked at run time only", .{pinned_sdl_version});
        versions.addOption([]const u8, "sdl", "unknown");
    }

    switch (linkage) {
        .dynamic => m.linkSystemLibrary("SDL2", .{}),
        .static => {
            const libdir_out = b.runAllowFail(&.{ "pkg-config", "--variable=libdir", "sdl2" }, &code, .ignore) catch {
                std.log.err("static SDL2 linkage needs pkg-config to locate libSDL2.a; use -Dsdl-linkage=dynamic", .{});
                std.process.exit(1);
            };
            const libdir = std.mem.trim(u8, libdir_out, " \t\r\n");
            m.addObjectFile(.{ .cwd_relative = b.fmt("{s}/libSDL2.a", .{libdir}) });
            const libs_out = b.runAllowFail(&.{ "pkg-config", "--static", "--libs", "sdl2" }, &code, .ignore) catch {
                std.log.err("pkg-config --static --libs sdl2 failed; use -Dsdl-linkage=dynamic", .{});
                std.process.exit(1);
            };
            var it = std.mem.tokenizeAny(u8, libs_out, " \t\r\n");
            while (it.next()) |flag| {
                if (std.mem.eql(u8, flag, "-lSDL2")) continue;
                if (std.mem.eql(u8, flag, "-pthread")) continue;
                if (std.mem.startsWith(u8, flag, "-l")) {
                    m.linkSystemLibrary(flag[2..], .{ .use_pkg_config = .no });
                } else if (std.mem.startsWith(u8, flag, "-L")) {
                    m.addLibraryPath(.{ .cwd_relative = b.dupe(flag[2..]) });
                }
            }
        },
    }
}

/// A Windows build: SDL2 compiled from source by Zig for the target (the `sdl2` package), linked
/// statically with the Windows libraries that it needs. The package is fetched on the first Windows
/// build; Linux builds never fetch it. SDL is optimised whatever the game's mode, as the system
/// library of a Linux build is.
fn linkPackagedSdl(b: *std.Build, m: *std.Build.Module, target: std.Build.ResolvedTarget, versions: *std.Build.Step.Options) void {
    versions.addOption([]const u8, "sdl", package_sdl_version);
    const dep = b.lazyDependency("sdl2", .{ .target = target, .optimize = .ReleaseFast }) orelse return;
    m.linkLibrary(dep.artifact("SDL2"));
}
