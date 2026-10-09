//! gameport build graph.
//!
//! Targets:
//!   gameport-agent  headless debugging host (shared game + AgentBackend), never links SDL
//!   gameport-sdl    SDL interactive host (Linux, Windows)
//!   web/            the browser build: gameport.wasm, index.html, gameport.js
//! Steps: `zig build` installs the two binaries; `agent` and `sdl` install one of them; `web`
//! installs the browser build and checks its module's imports; `web-check` checks the page's
//! helper functions against compiler-rt (it needs Node.js); `test` runs the unit tests of every
//! module; `smoke` runs the agent host for a few frames; `verify` checks that the agent binary has
//! no SDL dependency; `compile` checks formatting and compiles every binary and test binary
//! without running anything (every commit); `check` runs compile, test, smoke, verify and web
//! (every batch handed over); `all` installs every binary of the target and of Windows (under
//! <prefix>/windows) and the browser build.
const std = @import("std");
const builtin = @import("builtin");

/// The Zig this build is written for, `minimum_zig_version` in build.zig.zon. Another release, or a
/// development snapshot of this one, fails here with both versions named, before a confusing
/// error from a changed standard library.
const required_zig = @import("build.zig.zon").minimum_zig_version;

comptime {
    const required = std.SemanticVersion.parse(required_zig) catch unreachable;
    const found = builtin.zig_version;
    if (found.major != required.major or found.minor != required.minor or found.order(required) == .lt)
        @compileError("this build needs Zig " ++ required_zig ++ "; this is Zig " ++ builtin.zig_version_string);
}

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

    const versions = b.addOptions();

    // Shared code: the platform contract, in-memory providers, the game. No host library, no libc.
    const shared = b.addModule("gameport", .{
        .root_source_file = b.path("src/shared/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    shared.addOptions("build_versions", versions);

    // Agent platform: injected events, controlled time, captured output.
    const agent = b.addModule("agent", .{
        .root_source_file = b.path("src/agent/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "gameport", .module = shared }},
    });

    // Native I/O: the directory asset source and the directory storage over std.Io. The executables import it; `gameport` never does.
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
            },
        }),
    });

    b.installArtifact(agent_exe);
    b.installArtifact(sdl_exe);

    b.step("agent", "Build and install only the headless agent host").dependOn(&b.addInstallArtifact(agent_exe, .{}).step);
    b.step("sdl", "Build and install only the SDL host").dependOn(&b.addInstallArtifact(sdl_exe, .{}).step);
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

    // `compile`: the check of every commit. Formatting, and every binary and test binary
    // compiled, the browser module included; nothing runs. Plain `zig build` compiles no test
    // block, so a commit could build while its tests no longer compile.
    const compile_step = b.step("compile", "Check formatting and compile every binary and test binary, running nothing");
    // `zig fmt --check` itself: the build's Fmt step let a misformatted file through in 0.17.0.
    const fmt = b.addSystemCommand(&.{ b.graph.zig_exe, "fmt", "--check" });
    fmt.addFileArg(b.path("build.zig"));
    fmt.addFileArg(b.path("build.zig.zon"));
    fmt.addDirectoryArg(b.path("src"));
    fmt.expectExitCode(0);
    fmt.has_side_effects = true;
    compile_step.dependOn(&fmt.step);
    compile_step.dependOn(&agent_exe.step);
    compile_step.dependOn(&sdl_exe.step);
    compile_step.dependOn(&web_module.step);

    // Unit tests of every module. The tests of the SDL module link SDL2 as the host does.
    const test_step = b.step("test", "Run the unit tests of every module");
    const unit_modules = [_]*std.Build.Module{ shared, agent, native, sdl, web_parts, agent_exe.root_module };
    for (unit_modules) |m| {
        const t = b.addTest(.{ .root_module = m });
        compile_step.dependOn(&t.step);
        test_step.dependOn(&b.addRunArtifact(t).step);
    }

    // The agent host for a few frames, with a save and a load. It needs no game files and no
    // display.
    const smoke = b.addRunArtifact(agent_exe);
    smoke.addArgs(&.{ "--frames", "60", "--key", "10:f2", "--key", "20:f3" });
    smoke.expectExitCode(0);
    b.step("smoke", "Run the agent host for a few frames").dependOn(&smoke.step);

    // The agent binary must have no SDL dependency.
    const no_sdl = b.addSystemCommand(&.{ "sh", "tools/check_no_sdl.sh" });
    no_sdl.addArtifactArg(agent_exe);
    no_sdl.expectExitCode(0);
    b.step("verify", "Check the agent host binary links no SDL library").dependOn(&no_sdl.step);

    // `check`: everything above, once per batch of work handed over.
    const check_step = b.step("check", "compile, test, smoke, verify and web: before handing over a batch");
    for ([_]*std.Build.Step{ compile_step, test_step, &smoke.step, &no_sdl.step, web_step }) |s| check_step.dependOn(s);

    // `all`: every binary of the target and of Windows, and the browser build. The Windows binaries come from a second build for the
    // Windows target, run by this step alone, into <prefix>/windows: a build of any other step
    // never asks for the SDL2 package, which only a Windows build fetches.
    const all_step = b.step("all", "Build and install every binary: the target's, Windows's under <prefix>/windows, and the browser build");
    all_step.dependOn(b.getInstallStep());
    all_step.dependOn(web_step);
    if (target.result.os.tag != .windows) {
        const windows = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "install", "-Dtarget=x86_64-windows-gnu" });
        windows.addArg(b.fmt("-Doptimize={s}", .{@tagName(optimize)}));
        // The paths of this build, which only the make phase knows: its prefix and its cache. The
        // global cache comes with the environment.
        const absolute: std.Build.Step.Run.PathArgOptions = .{ .make_absolute = true };
        windows.addArg("--prefix");
        windows.addDirectoryArg2(.{ .relative = .{ .base = .install_prefix, .sub_path = "windows" } }, absolute);
        windows.addArg("--cache-dir");
        windows.addDirectoryArg2(.{ .relative = .{ .base = .local_cache } }, absolute);
        windows.setCwd(b.path("."));
        windows.has_side_effects = true;
        all_step.dependOn(&windows.step);
    }
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
