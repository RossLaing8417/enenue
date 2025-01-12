const std = @import("std");
const zap = @import("zap");

const InterfaceEndpoint = @import("InterfaceEndpoint.zig");
const Config = @import("Config.zig");

const Authenticator = zap.Auth.Basic(std.StringHashMap([]const u8), .UserPass);
const AuthEndpoint = zap.Endpoint.Authenticating(Authenticator);

const EndpointData = struct {
    endpoint: InterfaceEndpoint,
    auth: Authenticator,
    auth_endpoint: AuthEndpoint,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer std.debug.assert(gpa.deinit() == .ok);

    const allocator = gpa.allocator();

    zap.enableDebugLog();
    zap.Log.fio_set_log_level(zap.Log.fio_log_level_info);

    var config = try Config.parseFile(allocator, "runtime/example.json", "dev");
    defer config.deinit();

    var endpoints = std.ArrayList(EndpointData).init(allocator);
    defer {
        for (endpoints.items) |*item| {
            item.endpoint.deinit();
        }
        endpoints.deinit();
    }

    var listener = zap.Endpoint.Listener.init(
        allocator,
        .{
            .port = 42069,
            .on_request = null,
            .log = true,
            // .max_clients = ?,
        },
    );
    defer listener.deinit();

    var itr = config.interfaces.valueIterator();
    while (itr.next()) |interface| {
        switch (interface.node) {
            .http_endpoint => |*http_endpoint| {
                try endpoints.append(.{
                    .endpoint = try InterfaceEndpoint.init(allocator, "eip", interface),
                    .auth = try Authenticator.init(allocator, &http_endpoint.auth, null),
                    .auth_endpoint = undefined,
                });
                const item = &endpoints.items[endpoints.items.len - 1];
                item.auth_endpoint = AuthEndpoint.init(
                    item.endpoint.endpoint(),
                    &item.auth,
                );
                try listener.register(item.auth_endpoint.endpoint());
            },
            else => {},
        }
        if (interface.node == .http_endpoint) {}
    }

    try listener.listen();

    // var int: usize = 0;
    // _ = fio_run_every(1000, 5, task, &int, null);

    zap.start(.{
        .threads = 1,
        .workers = 1,
    });
}

fn onRequest(_: *zap.Endpoint, request: zap.Request) void {
    request.setContentType(.TEXT) catch {};
    request.sendBody("EISH!\n") catch {};
}

fn task(arg: ?*anyopaque) callconv(.C) void {
    const int: *usize = @ptrCast(@alignCast(arg));
    std.debug.print("TASK {d} !!!\n", .{int.*});
    int.* += 1;
}

pub extern fn fio_run_every(
    milliseconds: usize,
    repetitions: usize,
    task: ?*const fn (?*anyopaque) callconv(.C) void,
    arg: ?*anyopaque,
    on_finish: ?*const fn (?*anyopaque) callconv(.C) void,
) c_int;

test {
    std.testing.refAllDecls(@This());
}
