const std = @import("std");

const Config = @This();

arena: std.heap.ArenaAllocator,
source: []const u8,
interfaces: Interfaces,

pub fn parseFile(allocator: std.mem.Allocator, file_path: []const u8, environment: []const u8) !Config {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    var file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();
    const source = try file.readToEndAlloc(arena.allocator(), (try file.metadata()).size());
    return .{
        .arena = arena,
        .source = source,
        .interfaces = try parseInterfaces(arena.allocator(), source, environment),
    };
}

pub fn deinit(self: *Config) void {
    self.interfaces.deinit();
    self.arena.deinit();
}

fn NestedStringHashMap(comptime T: type) type {
    return struct {
        map: std.StringHashMap(T),

        pub fn init(allocator: std.mem.Allocator) @This() {
            return .{
                .map = std.StringHashMap(T).init(allocator),
            };
        }

        pub fn deinit(self: *@This()) void {
            var itr = self.map.valueIterator();
            while (itr.next()) |settings| {
                settings.deinit();
            }
            self.map.deinit();
        }

        pub fn contains(self: *@This(), key: []const u8) bool {
            return self.map.contains(key);
        }

        pub fn get(self: *@This(), key: []const u8) ?T {
            return self.map.get(key);
        }

        pub fn getPtr(self: *@This(), key: []const u8) ?*T {
            return self.map.getPtr(key);
        }

        pub fn put(self: *@This(), key: []const u8, value: T) !void {
            return self.map.put(key, value);
        }

        pub fn valueIterator(self: *@This()) std.StringHashMap(T).ValueIterator {
            return self.map.valueIterator();
        }
    };
}

const Settings = std.StringHashMap(std.json.Value);
const Interfaces = NestedStringHashMap(Interface);
const EnvSettings = NestedStringHashMap(Settings);

pub const Interface = struct {
    name: []const u8,
    module_path: []const u8,
    settings: Settings,
    node: Node,

    pub const Node = union(enum) {
        http_endpoint: HttpEndpoint,
        directory_poller: DirectoryPoller,
        http_poller: HttpPoller,
    };

    pub const HttpEndpoint = struct {
        path: []const u8,
        auth: std.StringHashMap([]const u8),

        pub fn jsonParse(
            allocator: std.mem.Allocator,
            source: anytype,
            options: std.json.ParseOptions,
        ) std.json.ParseError(@TypeOf(source.*))!HttpEndpoint {
            const HttpEndpointObject = struct {
                path: []const u8,
                auth: struct {
                    username: []const u8,
                    password: []const u8,
                },
            };
            const http_endpoint_object = try std.json.innerParse(HttpEndpointObject, allocator, source, options);
            var auth = std.StringHashMap([]const u8).init(allocator);
            errdefer auth.deinit();
            try auth.put(http_endpoint_object.auth.username, http_endpoint_object.auth.password);
            return .{
                .path = http_endpoint_object.path,
                .auth = auth,
            };
        }
    };

    pub const DirectoryPoller = struct {
        path: []const u8,
    };

    pub const HttpPoller = struct {
        url: []const u8,
    };

    pub fn deinit(self: *Interface) void {
        self.settings.deinit();
        switch (self.node) {
            .http_endpoint => |*http_endpoint| http_endpoint.auth.deinit(),
            else => {},
        }
    }
};

const InterfaceObject = struct {
    module_path: ?[]const u8 = null,
    settings: ?EnvSettings = null,
    http_endpoint: ?Interface.HttpEndpoint = null,
    directory_poller: ?Interface.DirectoryPoller = null,
    http_poller: ?Interface.HttpPoller = null,

    pub fn deinit(self: *InterfaceObject) void {
        if (self.settings) |*env_settings| {
            env_settings.deinit();
        }
    }

    pub fn parseField(
        comptime field: std.meta.FieldEnum(InterfaceObject),
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !std.meta.FieldType(InterfaceObject, field) {
        return switch (field) {
            .settings => try parseEnvSettings(allocator, source, options),
            else => try std.json.innerParse(std.meta.FieldType(InterfaceObject, field), allocator, source, options),
        };
    }

    pub fn toInterface(self: *InterfaceObject, allocator: std.mem.Allocator, name: []const u8, environment: []const u8) !Interface {
        const module_path = self.module_path orelse return error.MissingField;
        const node: Interface.Node = blk: {
            if (self.http_endpoint) |http_endpoint| {
                if (self.directory_poller != null or self.http_poller != null) {
                    return error.UnexpectedToken;
                }
                break :blk .{ .http_endpoint = http_endpoint };
            }
            if (self.directory_poller) |directory_poller| {
                if (self.http_endpoint != null or self.http_poller != null) {
                    return error.UnexpectedToken;
                }
                break :blk .{ .directory_poller = directory_poller };
            }
            if (self.http_poller) |http_poller| {
                if (self.http_endpoint != null or self.directory_poller != null) {
                    return error.UnexpectedToken;
                }
                break :blk .{ .http_poller = http_poller };
            }
            return error.MissingField;
        };
        var new_settings = Settings.init(allocator);
        if (self.settings) |*env_settings| {
            if (env_settings.get(environment)) |settings| {
                var itr = settings.iterator();
                while (itr.next()) |kv| {
                    try new_settings.put(kv.key_ptr.*, kv.value_ptr.*);
                }
            }
            if (env_settings.get("default")) |settings| {
                var itr = settings.iterator();
                while (itr.next()) |kv| {
                    if (!new_settings.contains(kv.key_ptr.*)) {
                        try new_settings.put(kv.key_ptr.*, kv.value_ptr.*);
                    }
                }
            }
        }
        return .{
            .name = name,
            .module_path = module_path,
            .settings = new_settings,
            .node = node,
        };
    }
};

fn parseInterfaces(
    allocator: std.mem.Allocator,
    source: []const u8,
    environment: []const u8,
) !Interfaces {
    const options = std.json.ParseOptions{
        .duplicate_field_behavior = .@"error",
        .ignore_unknown_fields = false,
        .max_value_len = source.len,
        .allocate = .alloc_if_needed,
    };
    var scanner = std.json.Scanner.initCompleteInput(allocator, source);
    defer scanner.deinit();
    std.debug.assert(scanner.is_end_of_input);
    if (try scanner.next() != .object_begin) {
        return error.UnexpectedToken;
    }
    var interfaces = Interfaces.init(allocator);
    while (true) {
        const field_name = switch (try scanner.next()) {
            .string, .allocated_string => |string| string,
            .object_end => break,
            else => return error.UnexpectedToken,
        };
        if (interfaces.contains(field_name)) {
            switch (options.duplicate_field_behavior) {
                .use_first => {
                    try scanner.skipValue();
                    continue;
                },
                .@"error" => return error.DuplicateField,
                .use_last => interfaces.getPtr(field_name).?.deinit(),
            }
        }
        var interface_object = try parseInterfaceObject(allocator, &scanner, options);
        defer interface_object.deinit();
        try interfaces.put(field_name, try interface_object.toInterface(allocator, field_name, environment));
    }
    return interfaces;
}

fn parseInterfaceObject(
    allocator: std.mem.Allocator,
    source: anytype,
    options: std.json.ParseOptions,
) !InterfaceObject {
    if (try source.next() != .object_begin) {
        return error.UnexpectedToken;
    }
    var interface_object = InterfaceObject{};
    while (true) {
        const field_name = blk: {
            const name_token = try source.next();
            const maybe_field_name = switch (name_token) {
                .string, .allocated_string => |string| std.meta.stringToEnum(std.meta.FieldEnum(InterfaceObject), string),
                .object_end => break,
                else => return error.UnexpectedToken,
            };
            break :blk maybe_field_name orelse {
                if (options.ignore_unknown_fields) {
                    try source.skipValue();
                    continue;
                }
                return error.UnknownField;
            };
        };
        switch (field_name) {
            inline else => |comptime_field_name| if (comptime_field_name == field_name) {
                if (@field(interface_object, @tagName(comptime_field_name))) |_| {
                    switch (options.duplicate_field_behavior) {
                        .use_first => {
                            try source.skipValue();
                            continue;
                        },
                        .@"error" => return error.DuplicateField,
                        .use_last => {},
                    }
                }
                @field(interface_object, @tagName(comptime_field_name)) = try InterfaceObject.parseField(comptime_field_name, allocator, source, options);
            },
        }
    }
    return interface_object;
}

fn parseEnvSettings(
    allocator: std.mem.Allocator,
    source: anytype,
    options: std.json.ParseOptions,
) !EnvSettings {
    if (try source.next() != .object_begin) {
        return error.UnexpectedToken;
    }
    var env_settings = EnvSettings.init(allocator);
    while (true) {
        const field_name = switch (try source.next()) {
            .string, .allocated_string => |string| string,
            .object_end => break,
            else => return error.UnexpectedToken,
        };
        if (env_settings.contains(field_name)) {
            switch (options.duplicate_field_behavior) {
                .use_first => {
                    try source.skipValue();
                    continue;
                },
                .@"error" => return error.DuplicateField,
                .use_last => env_settings.getPtr(field_name).?.deinit(),
            }
        }
        try env_settings.put(field_name, try parseSettings(allocator, source, options));
    }
    return env_settings;
}

fn parseSettings(
    allocator: std.mem.Allocator,
    source: anytype,
    options: std.json.ParseOptions,
) !Settings {
    if (try source.next() != .object_begin) {
        return error.UnexpectedToken;
    }
    var settings = Settings.init(allocator);
    while (true) {
        const field_name = switch (try source.next()) {
            .string, .allocated_string => |string| string,
            .object_end => break,
            else => return error.UnexpectedToken,
        };
        if (settings.contains(field_name)) {
            switch (options.duplicate_field_behavior) {
                .use_first => {
                    try source.skipValue();
                    continue;
                },
                .@"error" => return error.DuplicateField,
                .use_last => {},
            }
        }
        try settings.put(field_name, try std.json.innerParse(std.json.Value, allocator, source, options));
    }
    return settings;
}

test "http_endpoint interface" {
    const source =
        \\{
        \\    "test_http_endpoint": {
        \\        "module_path": "./runtime/test_http_endpoint",
        \\        "settings": {
        \\            "dev": {
        \\                "url_value": "dev_value"
        \\            },
        \\            "test": {
        \\                "url_value": "test_value"
        \\            },
        \\            "prod": {
        \\                "url_value": "prod_value"
        \\            },
        \\            "default": {
        \\                "url_value": "default_value"
        \\            }
        \\        },
        \\        "http_endpoint": {
        \\            "path": "test-http-endpoint",
        \\            "auth": {
        \\                "username": "test",
        \\                "password": "test"
        \\            }
        \\        }
        \\    }
        \\}
    ;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var interfaces = try parseInterfaces(allocator, source, "test");
    defer interfaces.deinit();
    try std.testing.expect(interfaces.get("test_http_endpoint") != null);
    const interface = interfaces.get("test_http_endpoint").?;
    var settings = interface.settings;
    try std.testing.expectEqualDeep(@as(?std.json.Value, .{ .string = "test_value" }), settings.get("url_value"));
}
