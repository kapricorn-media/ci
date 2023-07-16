const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;

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
    allocator: Allocator,
    port: u16,

    const Self = @This();

    fn init(allocator: Allocator, port: u16) !Self
    {
        return Self {
            .allocator = allocator,
            .port = port,
        };
    }

    fn deinit(self: *Self) void
    {
        _ = self;
    }
};

const BuildEntry = struct {
    project: []const u8,
    name: []const u8,
    timestamp: u64,

    const Self = @This();

    fn init(path: []const u8, allocator: Allocator) !Self
    {
        const dirName = std.fs.path.dirname(path) orelse return error.BadPath;
        const project = std.fs.path.basename(dirName);

        const fileName = std.fs.path.basename(path);
        const extIndex = std.mem.indexOf(u8, fileName, ".tar.gz") orelse return error.BadPath;
        const fileNameNoExt = fileName[0..extIndex];
        const dotIndex = std.mem.lastIndexOfScalar(u8, fileNameNoExt, '.') orelse return error.NoDot;
        if (dotIndex == fileNameNoExt.len) {
            return error.BadDot;
        }
        const timestampString = fileNameNoExt[dotIndex+1..];
        const timestamp = try std.fmt.parseUnsigned(u64, timestampString, 10);

        return Self {
            .project = try allocator.dupe(u8, project),
            .name = try allocator.dupe(u8, fileName),
            .timestamp = timestamp,
        };
    }

    fn greaterThan(_: void, lhs: Self, rhs: Self) bool
    {
        return lhs.timestamp > rhs.timestamp;
    }
};

fn timestampToString(timestamp: u64, allocator: Allocator) ![]const u8
{
    const epochSeconds = std.time.epoch.EpochSeconds{ .secs = timestamp };
    const epochDay = epochSeconds.getEpochDay();
    const daySeconds = epochSeconds.getDaySeconds();
    const yearDay = epochDay.calculateYearDay();
    const monthDay = yearDay.calculateMonthDay();
    const hours = daySeconds.getHoursIntoDay();
    const minutes = daySeconds.getMinutesIntoHour();
    const seconds = daySeconds.getSecondsIntoMinute();

    return std.fmt.allocPrint(allocator, "{d:0>4}/{d:0>2}/{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} UTC", .{yearDay.year, @enumToInt(monthDay.month), monthDay.day_index + 1, hours, minutes, seconds});
}

fn serverCallback(
    state: *ServerState,
    request: server.Request,
    writer: server.Writer) !void
{
    var arenaAllocator = std.heap.ArenaAllocator.init(state.allocator);
    defer arenaAllocator.deinit();
    const allocator = arenaAllocator.allocator();

    if (std.mem.eql(u8, request.uri, "/")) {
        var entries = std.ArrayList(BuildEntry).init(allocator);
        defer entries.deinit();

        const cwd = std.fs.cwd();
        var dirIterable = try cwd.openIterableDir(PATH_BUILDS, .{});
        defer dirIterable.close();
        var walker = try dirIterable.walk(allocator);
        defer walker.deinit();
        while (try walker.next()) |entry| {
            if (entry.kind != .File) {
                continue;
            }

            const e = try BuildEntry.init(entry.path, allocator);
            try entries.append(e);
        }

        const SortFunc = struct {
            fn lessThan(_: void, lhs: BuildEntry, rhs: BuildEntry) bool
            {
                const projectOrder = std.mem.order(u8, lhs.project, rhs.project);
                switch (projectOrder) {
                    .lt => return true,
                    .gt => return false,
                    .eq => {},
                }
                return lhs.timestamp > rhs.timestamp;
            }
        };

        std.sort.sort(BuildEntry, entries.items, {}, SortFunc.lessThan);

        try server.writeCode(writer, ._200);
        try server.writeEndHeader(writer);

        var lastProject: []const u8 = "";
        for (entries.items) |e| {
            if (!std.mem.eql(u8, lastProject, e.project)) {
                try std.fmt.format(writer, "<h2>{s}</h2>", .{e.project});
                lastProject = e.project;
            }

            const timestampString = try timestampToString(e.timestamp, allocator);
            try std.fmt.format(writer, "<p><a href=\"{s}/{s}\"><em>[{s}]</em>&nbsp;&nbsp;&nbsp;&nbsp;{s}</a></p>", .{e.project, e.name, timestampString, e.name});
        }
    } else {
        try server.serveStatic(writer, request.uri, PATH_BUILDS, state.allocator);
    }
}

fn serverCallbackWrapper(
    state: *ServerState,
    request: server.Request,
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

fn httpRedirectCallback(_: void, request: server.Request, writer: server.Writer) !void
{
    // TODO we don't have an allocator... but it's ok, I guess
    var buf: [2048]u8 = undefined;
    const host = http.getHeader(request, "Host") orelse return error.NoHost;
    const redirectUrl = try std.fmt.bufPrint(&buf, "https://{s}{s}", .{host, request.uriFull});

    try server.writeRedirectResponse(writer, redirectUrl);
}

fn httpRedirectEntrypoint(allocator: std.mem.Allocator) !void
{
    var s = try server.Server(void).init(httpRedirectCallback, {}, null, allocator);
    const port = 80;

    std.log.info("Listening on {s}:{} (HTTP -> HTTPS redirect)", .{SERVER_IP, port});
    s.listen(SERVER_IP, port) catch |err| {
        std.log.err("server listen error {}", .{err});
        return err;
    };
    s.stop();
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
    if (args.len < 2) {
        std.log.err("Expected arguments: port [<https-chain-path> <https-key-path>]", .{});
        return error.BadArgs;
    }

    const port = try std.fmt.parseUnsigned(u16, args[1], 10);
    const HttpsArgs = struct {
        chainPath: []const u8,
        keyPath: []const u8,
    };
    var httpsArgs: ?HttpsArgs = null;
    if (args.len > 2) {
        if (args.len != 4) {
            std.log.err("Expected arguments: port [<https-chain-path> <https-key-path>]", .{});
            return error.BadArgs;
        }
        httpsArgs = HttpsArgs {
            .chainPath = args[2],
            .keyPath = args[3],
        };
    }

    var state = try ServerState.init(allocator, port);
    defer state.deinit();

    var s: server.Server(*ServerState) = undefined;
    var httpRedirectThread: ?std.Thread = undefined;
    {
        if (httpsArgs) |ha| {
            const cwd = std.fs.cwd();
            const chainFile = try cwd.openFile(ha.chainPath, .{});
            defer chainFile.close();
            const chainFileData = try chainFile.readToEndAlloc(allocator, 1024 * 1024 * 1024);
            defer allocator.free(chainFileData);

            const keyFile = try cwd.openFile(ha.keyPath, .{});
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
            httpRedirectThread = try std.Thread.spawn(.{}, httpRedirectEntrypoint, .{allocator});
        } else {
            s = try server.Server(*ServerState).init(
                serverCallbackWrapper, &state, null, allocator
            );
            httpRedirectThread = null;
        }
    }
    defer s.deinit();

    std.log.info("Listening on {s}:{} (HTTPS {})", .{SERVER_IP, port, httpsArgs != null});
    s.listen(SERVER_IP, port) catch |err| {
        std.log.err("server listen error {}", .{err});
        return err;
    };
    s.stop();

    if (httpRedirectThread) |t| {
        t.detach(); // TODO we don't really care for now
    }
}
