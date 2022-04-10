const builtin = @import("builtin");
const std = @import("std");

const http = @import("http-common");
const server = @import("http-server");

const SERVER_IP = "0.0.0.0";
const PATH_BUILDS = "builds";

pub const log_level: std.log.Level = switch (builtin.mode) {
    .Debug => .debug,
    .ReleaseSafe => .info,
    .ReleaseFast => .info,
    .ReleaseSmall => .info,
};

const ServerCallbackError = server.Writer.Error || error {InternalServerError};

const ServerState = struct {
    allocator: std.mem.Allocator,
};

fn onBadFile(writer: server.Writer, fileName: []const u8, err: anyerror) !void
{
    try std.fmt.format(writer, "<p>ERROR <b>{}</b>, BAD FILE <b>{s}</b></p>", .{err, fileName});
}

fn serverCallback(
    state: *ServerState,
    request: *const server.Request,
    writer: server.Writer) !void
{
    const allocator = state.allocator;

    if (std.mem.eql(u8, request.uri, "/")) {
        try server.writeCode(writer, ._200);
        try server.writeEndHeader(writer);

        const BuildEntry = struct {
            fileName: []const u8,
            timestamp: u64,

            const Self = @This();

            fn greaterThan(_: void, lhs: Self, rhs: Self) bool
            {
                return lhs.timestamp > rhs.timestamp;
            }
        };
        var entries = std.ArrayList(BuildEntry).init(allocator);
        defer entries.deinit();

        var dir = try std.fs.cwd().openDir(PATH_BUILDS, .{.iterate = true});
        defer dir.close();
        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .Directory) {
                continue;
            }

            try std.fmt.format(writer, "<h2>{s}</h2>", .{entry.name});
            var dir2 = try dir.openDir(entry.name, .{.iterate = true});
            defer dir2.close();
            var it2 = dir2.iterate();

            for (entries.items) |e| {
                allocator.free(e.fileName);
            }
            entries.clearRetainingCapacity();

            while (try it2.next()) |entry2| {
                if (entry2.kind != .File) {
                    continue;
                }
                var nameSplit = std.mem.split(u8, entry2.name, ".");
                _ = nameSplit.next() orelse {
                    try onBadFile(writer, entry2.name, error.NoSplitFirst);
                    continue;
                };
                const timestampString = nameSplit.next() orelse {
                    try onBadFile(writer, entry2.name, error.NoSplitSecond);
                    continue;
                };
                const timestamp = std.fmt.parseUnsigned(u64, timestampString, 10) catch |err| {
                    try onBadFile(writer, entry2.name, err);
                    continue;
                };

                const buildEntry = BuildEntry {
                    .fileName = try allocator.dupe(u8, entry2.name),
                    .timestamp = timestamp,
                };
                try entries.append(buildEntry);
            }

            std.sort.sort(BuildEntry, entries.items, {}, BuildEntry.greaterThan);
            for (entries.items) |e| {
                try std.fmt.format(writer, "<p><a href=\"{s}/{s}\">{s}</a></p>", .{entry.name, e.fileName, e.fileName});
            }
        }
    } else {
        try server.serveStatic(writer, request.uri, PATH_BUILDS, state.allocator);
    }
}

fn serverCallbackWrapper(
    state: *ServerState,
    request: *const server.Request,
    writer: server.Writer) ServerCallbackError!void
{
    serverCallback(state, request, writer) catch |err| {
        std.log.err("serverCallback failed, error {}", .{err});
        const code = http.Code._500;
        try server.writeCode(writer, code);
        try server.writeEndHeader(writer);
        return error.InternalServerError;
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        if (gpa.deinit()) {
            std.log.err("GPA detected leaks", .{});
        }
    }
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer allocator.free(args);
    if (args.len != 4) {
        std.log.err("Expected arguments: port https-chain-path https-key-path", .{});
        return error.BadArgs;
    }

    const port = try std.fmt.parseUnsigned(u16, args[1], 10);
    const HttpsArgs = struct {
        chainPath: []const u8,
        keyPath: []const u8,
    };
    var httpsArgs = HttpsArgs {
        .chainPath = args[2],
        .keyPath = args[3],
    };

    var state = ServerState {
        .allocator = allocator,
    };
    var s: server.Server(*ServerState) = undefined;
    {
        const cwd = std.fs.cwd();
        const chainFile = try cwd.openFile(httpsArgs.chainPath, .{});
        defer chainFile.close();
        const chainFileData = try chainFile.readToEndAlloc(allocator, 1024 * 1024 * 1024);
        defer allocator.free(chainFileData);

        const keyFile = try cwd.openFile(httpsArgs.keyPath, .{});
        defer keyFile.close();
        const keyFileData = try keyFile.readToEndAlloc(allocator, 1024 * 1024 * 1024);
        defer allocator.free(keyFileData);

        const httpsOptions = server.HttpsOptions {
            .certChainFileData = chainFileData,
            .privateKeyFileData = keyFileData,
        };
        s = try server.Server(*ServerState).init(
            serverCallbackWrapper, &state, httpsOptions, allocator
        );
    }
    defer s.deinit();

    std.log.info("Listening on {s}:{}", .{SERVER_IP, port});
    s.listen(SERVER_IP, port) catch |err| {
        std.log.err("server listen error {}", .{err});
        return err;
    };
    s.stop();
}
