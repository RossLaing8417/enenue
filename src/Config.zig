const std = @import("std");

const Config = @This();

const Interfaces = std.StringHashMap(Interface);
const Settings = std.StringHashMap(std.json.Value);

source: []const u8,
interfaces: *Interfaces,

pub const Interface = struct {
    name: []const u8,
    environment: []const u8,
    module: ?[]const u8,
    settings: *Settings,
    node: Node,
    auth: std.StringHashMap([]const u8),

    pub const Node = union(enum) {
        http_endpoint: HttpEndpoint,
        directory_poller: DirectoryPoller,
        http_poller: HttpPoller,

        pub const HttpEndpoint = struct {
            path: []const u8,
        };

        pub const DirectoryPoller = struct {
            path: []const u8,
        };

        pub const HttpPoller = struct {
            url: []const u8,
        };
    };

    pub fn deinit(self: *Interface, allocator: std.mem.Allocator) void {
        self.settings.deinit();
        allocator.destroy(self.settings);
        self.auth.deinit();
    }
};

pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
    var itr = self.interfaces.valueIterator();
    while (itr.next()) |interface| {
        interface.deinit(allocator);
    }
    self.interfaces.deinit();
    allocator.destroy(self.interfaces);
    allocator.free(self.source);
}

pub fn parseFile(allocator: std.mem.Allocator, path: []const u8, environment: []const u8) !Config {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const buffer = try file.readToEndAlloc(allocator, (try file.metadata()).size());
    errdefer allocator.free(buffer);
    return .{
        .source = buffer,
        .interfaces = try parseInterfaces(allocator, buffer, environment),
    };
}

fn parseInterfaces(allocator: std.mem.Allocator, source: []const u8, environment: []const u8) !*Interfaces {
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
    const interfaces = try allocator.create(Interfaces);
    interfaces.* = Interfaces.init(allocator);
    errdefer {
        var itr = interfaces.valueIterator();
        while (itr.next()) |interface| {
            interface.*.deinit(allocator);
        }
        interfaces.deinit();
        allocator.destroy(interfaces);
    }
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
                .use_last => {},
            }
        }
        var interface_object = try std.json.innerParse(InterfaceObject, allocator, &scanner, options);
        defer interface_object.deinit(allocator);
        try interfaces.put(field_name, try interface_object.toInterface(allocator, field_name, environment));
    }
    std.debug.assert(try scanner.next() == .end_of_document);
    return interfaces;
}

const InterfaceObject = struct {
    module: ?[]const u8 = null,
    settings: ?*EnvSettings = null,
    http_endpoint: ?Interface.Node.HttpEndpoint = null,
    directory_poller: ?Interface.Node.DirectoryPoller = null,
    http_poller: ?Interface.Node.HttpPoller = null,

    const EnvSettings = std.StringHashMap(*Settings);

    pub fn deinit(self: *InterfaceObject, allocator: std.mem.Allocator) void {
        if (self.settings) |env_settings| {
            var itr = env_settings.valueIterator();
            while (itr.next()) |settings| {
                settings.*.deinit();
                allocator.destroy(settings);
            }
            env_settings.deinit();
            allocator.destroy(env_settings);
        }
    }

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!InterfaceObject {
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
                    @field(interface_object, @tagName(comptime_field_name)) = try parse(comptime_field_name, allocator, source, options);
                },
            }
        }
        return interface_object;
    }

    fn parse(
        comptime field: std.meta.FieldEnum(InterfaceObject),
        allocator: std.mem.Allocator,
        source: anytype,
        options: std.json.ParseOptions,
    ) !std.meta.FieldType(InterfaceObject, field) {
        return switch (field) {
            .module,
            .http_endpoint,
            .directory_poller,
            .http_poller,
            => try std.json.innerParse(std.meta.FieldType(InterfaceObject, field), allocator, source, options),
            .settings => blk: {
                if (try source.next() != .object_begin) {
                    return error.UnexpectedToken;
                }
                var env_settings = try allocator.create(EnvSettings);
                env_settings.* = EnvSettings.init(allocator);
                errdefer {
                    var itr = env_settings.valueIterator();
                    while (itr.next()) |env_setting| {
                        env_setting.*.deinit();
                    }
                    env_settings.deinit();
                    allocator.destroy(env_settings);
                }
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
                            .use_last => {},
                        }
                    }
                    try env_settings.put(field_name, try parseSettings(allocator, source, options));
                }
                break :blk env_settings;
            },
        };
    }

    /// FIXME: Memory leak somewhere when parsing settings...
    fn parseSettings(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) !*Settings {
        if (try source.next() != .object_begin) {
            return error.UnexpectedToken;
        }
        var settings = try allocator.create(Settings);
        settings.* = Settings.init(allocator);
        errdefer {
            settings.deinit();
            allocator.destroy(settings);
        }
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
            try settings.put(field_name, try std.json.Value.jsonParse(allocator, source, options));
        }
        return settings;
    }

    pub fn toInterface(self: *InterfaceObject, allocator: std.mem.Allocator, name: []const u8, environment: []const u8) !Interface {
        const node: Interface.Node = blk: {
            if (self.http_endpoint) |http_endpoint| {
                if (self.directory_poller != null or self.http_poller != null) {
                    return error.UnexpectedToken;
                }
                break :blk .{ .http_endpoint = http_endpoint };
            } else if (self.directory_poller) |directory_poller| {
                if (self.http_endpoint != null or self.http_poller != null) {
                    return error.UnexpectedToken;
                }
                break :blk .{ .directory_poller = directory_poller };
            } else if (self.http_poller) |http_poller| {
                if (self.http_endpoint != null or self.directory_poller != null) {
                    return error.UnexpectedToken;
                }
                break :blk .{ .http_poller = http_poller };
            } else {
                return error.MissingField;
            }
        };
        var settings = try allocator.create(Settings);
        settings.* = Settings.init(allocator);
        errdefer {
            settings.deinit();
            allocator.destroy(settings);
        }
        if (self.settings) |env_settings| {
            if (env_settings.get("default")) |env_setting| {
                var itr = env_setting.iterator();
                while (itr.next()) |kv| {
                    try settings.put(kv.key_ptr.*, kv.value_ptr.*);
                }
            }
            if (env_settings.get(environment)) |env_setting| {
                var itr = env_setting.iterator();
                while (itr.next()) |kv| {
                    try settings.put(kv.key_ptr.*, kv.value_ptr.*);
                }
            }
        }
        var auth = std.StringHashMap([]const u8).init(allocator);
        errdefer auth.deinit();
        try auth.put("test", "test");
        return .{
            .name = name,
            .environment = environment,
            .module = self.module,
            .settings = settings,
            .node = node,
            .auth = auth,
        };
    }
};
