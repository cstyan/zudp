const std = @import("std");

pub const PacketType = enum(u8) {
    Data,
    Ack,
    EoT,
};

pub const Kind = union(PacketType) {
    Data: struct {
        seq: u32,
        ack: u32,
        len: usize,
        data: []const u8, // not owned — you manage backing storage elsewhere
    },
    Ack: struct {
        ack: u32,
    },
    EoT: void, // no payload
};

pub const Packet = struct {
    src: std.net.Ip4Address,
    dest: std.net.Ip4Address,
    kind: Kind,

    pub fn deinit(self: *Packet, allocator: std.mem.Allocator) void {
        switch (self.kind) {
            .Data => |*d| allocator.free(d.data),
            else => {},
        }
    }

    pub fn serialize(self: *const Packet, buffer: []u8) !usize {
        // const max_data_len = switch (self.kind) {
        //     .Data => self.kind.Data.len,
        //     else => 0,
        // };

        // Rough max size: 4 bytes IP * 2 + 1 byte kind + 4 seq + 4 ack + 4 len + data length
        // We’ll build the buffer dynamically but keep it simple here
        // const buffer = try allocator.alloc(u8, 1024);
        // defer allocator.free(buffer);

        var w_stream = std.io.fixedBufferStream(buffer);
        var w = w_stream.writer();

        try w.writeInt(u32, self.src.sa.addr, .little);
        try w.writeInt(u16, self.src.sa.port, .little);
        try w.writeInt(u32, self.dest.sa.addr, .little);
        try w.writeInt(u16, self.dest.sa.port, .little);

        // Write kind as u8
        try w.writeByte(@intFromEnum(self.kind));
        // std.debug.print("after header bytes written is {d}\n", .{w_stream.pos});

        switch (self.kind) {
            .Data => |d| {
                // std.debug.print("data type\n", .{});
                try w.writeInt(u32, d.seq, .little);
                try w.writeInt(u32, d.ack, .little);
                try w.writeInt(u32, @intCast(d.data.len), .little);
                // std.debug.print("after data header bytes written is {d}\n", .{w_stream.pos});

                try w.writeAll(d.data);
            },
            .Ack => |a| {
                try w.writeInt(u32, a.ack, .little);
            },
            .EoT => {},
        }

        return w_stream.pos;
    }

    pub fn deserialize(
        // allocator: std.mem.Allocator,
        bytes: []const u8,
    ) !Packet {
        var stream = std.io.fixedBufferStream(bytes);
        var r = stream.reader();

        const src_bytes = try r.readBytesNoEof(4);
        const src_port = try r.readInt(u16, .little);
        const src = std.net.Ip4Address.init(src_bytes, src_port);

        const dest_bytes = try r.readBytesNoEof(4);
        const dest_port = try r.readInt(u16, .little);
        const dest = std.net.Ip4Address.init(dest_bytes, dest_port);

        const kind_byte = try r.readByte();
        const kind_tag: PacketType = try std.meta.intToEnum(PacketType, kind_byte);

        return switch (kind_tag) {
            .Data => {
                // const len = try r.readInt(u32, .little);
                // const body = try allocator.alloc(u8, len);
                // _ = try r.readAll(body);
                const seq: u32 = try r.readInt(u32, .little);
                const ack: u32 = try r.readInt(u32, .little);
                const data_len: usize = try r.readInt(u32, .little);
                // if we get here we've already read 25 bytes
                const data: []const u8 = bytes[stream.pos .. stream.pos + data_len];

                return Packet{
                    .src = src,
                    .dest = dest,
                    .kind = Kind{
                        .Data = .{
                            .seq = seq,
                            .ack = ack,
                            .len = data_len,
                            // .data = &[_]u8{},
                            .data = data,
                        },
                    },
                };
            },
            .Ack => {
                const ack = try r.readInt(u32, .little);
                return Packet{
                    .src = src,
                    .dest = dest,
                    .kind = Kind{ .Ack = .{ .ack = ack } },
                };
            },
            .EoT => Packet{
                .src = src,
                .dest = dest,
                .kind = .EoT,
            },
        };
    }
};

pub fn initDataPacket(
    allocator: std.mem.Allocator,
    src: std.net.Ip4Address,
    dest: std.net.Ip4Address,
    seq: u32,
    ack: u32,
    msg: []const u8,
) !Packet {
    const data = try allocator.alloc(u8, msg.len);
    std.mem.copyForwards(u8, data, msg);

    return Packet{ .src = src, .dest = dest, .kind = Kind{
        .Data = .{
            .seq = seq,
            .ack = ack,
            .len = msg.len,
            .data = data,
        },
    } };
}

pub fn printPacket(p: Packet) void {
    switch (p.kind) {
        .Data => |data| {
            // data is the payload struct for Data variant
            std.debug.print("Data packet: seq={}, ack={}, len={}, data={s}\n", .{ data.seq, data.ack, data.len, data.data });
        },
        .Ack => |ack| {
            std.debug.print("Ack packet: ack={}\n", .{ack.ack});
        },
        .EoT => {
            std.debug.print("EoT packet\n", .{});
        },
    }
}
