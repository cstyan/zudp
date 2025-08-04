const std = @import("std");
const tracking_allocator = @import("tracking_allocator.zig");

pub const window_size = 5;

const DeserializeError = error{NonMatchingKind};

pub const PacketType = enum(u8) {
    Data,
    Ack,
    EoT,
};

pub const Kind = union(PacketType) {
    Data: struct {
        seq: u32,
        len: usize,
        data: []u8,
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
        var w_stream = std.io.fixedBufferStream(buffer);
        var w = w_stream.writer();

        try w.writeInt(u32, self.src.sa.addr, .little);
        try w.writeInt(u16, self.src.sa.port, .little);
        try w.writeInt(u32, self.dest.sa.addr, .little);
        try w.writeInt(u16, self.dest.sa.port, .little);
        try w.writeByte(@intFromEnum(self.kind));

        switch (self.kind) {
            .Data => |d| {
                try w.writeInt(u32, d.seq, .little);
                try w.writeInt(u32, @intCast(d.data.len), .little);
                try w.writeAll(d.data);
            },
            .Ack => |a| {
                try w.writeInt(u32, a.ack, .little);
            },
            .EoT => {},
        }

        return w_stream.pos;
    }

    pub fn deserialize(bytes: []u8) !Packet {
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
                const seq: u32 = try r.readInt(u32, .little);
                const data_len: usize = try r.readInt(u32, .little);
                // if we get here we've already read 25 bytes
                const data: []u8 = bytes[stream.pos .. stream.pos + data_len];

                return Packet{
                    .src = src,
                    .dest = dest,
                    .kind = Kind{
                        .Data = .{
                            .seq = seq,
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

    pub fn deserialize_data(self: *Packet, bytes: []u8) !void {
        var stream = std.io.fixedBufferStream(bytes);
        var r = stream.reader();

        const src_bytes = try r.readBytesNoEof(4);
        const src_port = try r.readInt(u16, .little);
        self.src = std.net.Ip4Address.init(src_bytes, src_port);

        const dest_bytes = try r.readBytesNoEof(4);
        const dest_port = try r.readInt(u16, .little);
        self.dest = std.net.Ip4Address.init(dest_bytes, dest_port);

        const kind_byte = try r.readByte();
        const kind_tag: PacketType = try std.meta.intToEnum(PacketType, kind_byte);

        if (kind_tag != .Data)
            return error.UnexpectedPacketType;

        const data = &self.kind.Data;
        data.seq = try r.readInt(u32, .little);

        const len: usize = try r.readInt(u32, .little);
        if (len > data.data.len) {
            // std.debug.print("len: {d} data len {d}\n", .{ len, data.data.len });
            return error.DataBufferTooSmall;
        }

        data.len = len;
        try r.readNoEof(data.data[0..len]);
    }
};

pub fn check_kind(bytes: []u8) !PacketType {
    const kind_byte = bytes[12];
    return try std.meta.intToEnum(PacketType, kind_byte);
}

const PacketData = struct {
    src: std.net.Ip4Address,
    dest: std.net.Ip4Address,
    seq: u32,
    data: []const u8,
};

pub const WindowError = error{
    WindowFull,
    UnexpectedSequence,
    WindowOverflow,
};

pub const PacketWindow = struct {
    buffer: [window_size]Packet,
    base_seq: u32 = 0, // sequence number of first (oldest) packet
    next_seq: u32 = 0, // next to be generated
    count: usize = 0,
    head: usize = 0, // write position (mod N)

    pub fn initalize(self: *PacketWindow, allocator: std.mem.Allocator) !void {
        for (&self.buffer) |*pkt| {
            pkt.* = .{
                .src = undefined,
                .dest = undefined,
                .kind = .{ .Data = .{
                    .seq = 0,
                    .len = 0,
                    .data = try allocator.alloc(u8, 1024 - 21),
                } },
            };
        }
    }

    pub fn push_data(self: *PacketWindow, data: PacketData) !void {
        if (self.count >= window_size) {
            return error.WindowFull;
        }

        const expected_seq = self.base_seq + self.count;
        if (self.next_seq != expected_seq) {
            return error.UnexpectedSequence;
        }

        const insert_index = (self.head + self.count) % window_size;
        var pkt = &self.buffer[insert_index];
        var kind_data = &pkt.kind.Data;
        // do the insert
        pkt.src = data.src;
        pkt.dest = data.dest;
        kind_data.seq = data.seq;
        std.mem.copyForwards(u8, kind_data.data, data.data);

        self.count += 1;
        self.next_seq += 1;
    }

    pub fn can_push(self: *PacketWindow) bool {
        return self.count < self.buffer.len;
    }

    // Slide window forward on ACK (inclusive)
    pub fn ack(self: *PacketWindow, ack_seq: u32) void {
        if (ack_seq + 1 < self.base_seq) {
            std.debug.print("old ack", .{});
            // Older ACK, ignore
            return;
        }
        const acked = ack_seq + 1 - self.base_seq;
        if (acked > self.count) {
            std.debug.print("too new ack", .{});

            // ACK beyond current window, ignore or handle error
            return;
        }
        const N = self.buffer.len;
        self.head = (self.head + acked) % N;
        self.base_seq = ack_seq + 1;
        self.count -= acked;
    }

    pub fn deinit(self: *PacketWindow, allocator: std.mem.Allocator) void {
        // We need &self.buffer and *pkt so that we don't get a const reference to each packet.
        for (&self.buffer) |*pkt| {
            pkt.deinit(allocator);
        }
    }
};
