const std = @import("std");
const zap = @import("zap");
const ziglua = @import("ziglua");

const Config = @import("Config.zig");

const InterfaceEndpoint = @This();

const MAX_PATH_LEN = 256;

allocator: std.mem.Allocator,
interface: *Config.Interface,
path: []const u8,
internal_endpoint: zap.Endpoint,

pub fn init(allocator: std.mem.Allocator, path: []const u8, interface: *Config.Interface) !InterfaceEndpoint {
    std.debug.assert(interface.node == .http_endpoint);
    const full_path = try std.fmt.allocPrint(allocator, "/{s}/{s}", .{ std.mem.trim(u8, path, "/"), std.mem.trim(u8, interface.node.http_endpoint.path, "/") });
    std.debug.print("Registered endpont {s}, listening at path {s}\n", .{ interface.name, full_path });
    return .{
        .allocator = allocator,
        .interface = interface,
        .path = full_path,
        .internal_endpoint = zap.Endpoint.init(.{
            .path = full_path,
            .get = handleRequest,
            .post = handleRequest,
            .put = handleRequest,
            .delete = handleRequest,
            .patch = handleRequest,
            .options = handleRequest,
            .unauthorized = unauthorizedRequestHandler,
        }),
    };
}

pub fn deinit(self: *InterfaceEndpoint) void {
    self.allocator.free(self.path);
}

pub fn endpoint(self: *InterfaceEndpoint) *zap.Endpoint {
    return &self.internal_endpoint;
}

fn unauthorizedRequestHandler(_: *zap.Endpoint, request: zap.Request) void {
    request.sendError(error.Unauthorized, if (@errorReturnTrace()) |trace| trace.* else null, 401);
}

fn handleRequest(_endpoint: *zap.Endpoint, request: zap.Request) void {
    const self: *InterfaceEndpoint = @fieldParentPtr("internal_endpoint", _endpoint);
    self._handleRequest(_endpoint, request) catch |err| {
        request.sendError(err, if (@errorReturnTrace()) |trace| trace.* else null, 500);
    };
}

fn _handleRequest(self: *InterfaceEndpoint, _endpoint: *zap.Endpoint, request: zap.Request) !void {
    _ = _endpoint;
    const lua = ziglua.Lua.init(&self.allocator) catch |err| {
        std.debug.print("Error starting lua: {}\n", .{err});
        return;
    };
    defer lua.deinit();
    try self._runLua(request, lua);
    try request.setContentType(.TEXT);
    try request.sendBody("Success...\n");
}

fn _runLua(self: *InterfaceEndpoint, request: zap.Request, lua: *ziglua.Lua) !void {
    lua.openLibs();

    try lua.loadFile("runtime/lua/enenue/init.lua");
    try lua.protectedCall(0, ziglua.mult_return, 0);
    lua.setGlobal("enu");
    lua.setTop(0);

    _ = try lua.getGlobal("enu");
    _ = lua.getField(-1, "log");
    _ = lua.pushString("test");
    lua.pushInteger(123);

    lua.protectedCall(2, 0, 0) catch |err| {
        std.debug.print("Error: {s}\n", .{try lua.toString(-1)});
        return err;
    };

    if (request.path) |path| {
        if (path.len > self.path.len + 1) {
            const seconds = try std.fmt.parseUnsigned(u64, path[self.path.len + 1 ..], 10);
            std.time.sleep(seconds * std.time.ns_per_s);
            if (seconds == 4) {
                std.debug.panic("Murdered...\n", .{});
            }
        }
    }
}
