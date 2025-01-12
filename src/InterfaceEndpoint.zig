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
    self._handleRequest(request) catch |err| {
        request.sendError(err, if (@errorReturnTrace()) |trace| trace.* else null, 500);
    };
}

fn _handleRequest(self: *InterfaceEndpoint, request: zap.Request) !void {
    const lua = try self.initLuaState();
    defer lua.deinit();
    try self.executeScript(request, lua);
    try request.setContentType(.TEXT);
    try request.sendBody("Success...\n");
}

fn initLuaState(self: *InterfaceEndpoint) !*ziglua.Lua {
    const lua = try ziglua.Lua.init(&self.allocator);
    errdefer lua.deinit();

    // TODO: Only enable explicit libs
    lua.openLibs();

    _ = try lua.getGlobal("package");
    _ = lua.pushString("./runtime/lua/?.lua;./runtime/lua/?/init.lua");
    lua.setField(-2, "path");
    lua.pop(1);

    try lua.loadFile("runtime/lua/enenue/init.lua");
    lua.protectedCall(0, ziglua.mult_return, 0) catch |err| return printLuaError(lua, err);
    lua.setGlobal("enenue");

    std.debug.assert(lua.getTop() == 0);

    return lua;
}

fn executeScript(self: *InterfaceEndpoint, request: zap.Request, lua: *ziglua.Lua) !void {
    var buffer = std.ArrayList(u8).init(self.allocator);
    defer buffer.deinit();
    try buffer.appendSlice(self.interface.module_path);
    try buffer.appendSlice("/init.lua");
    const module_path = try buffer.toOwnedSliceSentinel(0);
    defer self.allocator.free(module_path);
    std.debug.print("Running: {s}\n", .{module_path});
    try lua.loadFile(module_path);
    lua.protectedCall(0, ziglua.mult_return, 0) catch |err| return printLuaError(lua, err);

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

fn printLuaError(lua: *ziglua.Lua, err: anyerror) anyerror {
    const err_string = lua.toString(-1) catch "unknown";
    std.debug.print("Lua error: {s}\n", .{err_string});
    return err;
}
