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

    pub fn serialize_into(self: *const Packet, buffer: []u8) !usize {
        var i: usize = 0;

        if (buffer.len < 13) return error.BufferTooSmall;

        buffer[0] = @truncate(self.src.sa.addr >> 0);
        buffer[1] = @truncate(self.src.sa.addr >> 8);
        buffer[2] = @truncate(self.src.sa.addr >> 16);
        buffer[3] = @truncate(self.src.sa.addr >> 24);

        buffer[4] = @truncate(self.src.sa.port >> 0);
        buffer[5] = @truncate(self.src.sa.port >> 8);

        buffer[6] = @truncate(self.dest.sa.addr >> 0);
        buffer[7] = @truncate(self.dest.sa.addr >> 8);
        buffer[8] = @truncate(self.dest.sa.addr >> 16);
        buffer[9] = @truncate(self.dest.sa.addr >> 24);

        buffer[10] = @truncate(self.dest.sa.port >> 0);
        buffer[11] = @truncate(self.dest.sa.port >> 8);

        buffer[12] = @intFromEnum(self.kind);
        i = 13;

        switch (self.kind) {
            .Data => |d| {
                if (buffer.len < 21 + d.data.len) return error.BufferTooSmall;

                buffer[13] = @truncate(d.seq >> 0);
                buffer[14] = @truncate(d.seq >> 8);
                buffer[15] = @truncate(d.seq >> 16);
                buffer[16] = @truncate(d.seq >> 24);

                buffer[17] = @truncate(d.data.len >> 0);
                buffer[18] = @truncate(d.data.len >> 8);
                buffer[19] = @truncate(d.data.len >> 16);
                buffer[20] = @truncate(d.data.len >> 24);
                @memcpy(buffer[21 .. 21 + d.data.len], d.data);
                i += 8 + d.data.len;
            },
            .Ack => |a| {
                buffer[13] = @truncate(a.ack >> 0);
                buffer[14] = @truncate(a.ack >> 8);
                buffer[15] = @truncate(a.ack >> 16);
                buffer[16] = @truncate(a.ack >> 24);
                i += 4;
            },
            .EoT => std.debug.print("serialized EoT", .{}),
        }

        return i;
    }

    pub fn deserialize_into(self: *Packet, bytes: []u8) !void {
        self.src = std.net.Ip4Address.init(bytes[0..4].*, @as(u16, bytes[4]) | (@as(u16, bytes[5]) << 8));
        self.dest = std.net.Ip4Address.init(bytes[6..10].*, @as(u16, bytes[10]) | (@as(u16, bytes[11]) << 8));

        const kind_byte = bytes[12];
        const kind_tag: PacketType = try std.meta.intToEnum(PacketType, kind_byte);

        switch (kind_tag) {
            .Data => {
                const data = &self.kind.Data;
                data.seq = @as(u32, bytes[13]) |
                    (@as(u32, bytes[14]) << 8) |
                    (@as(u32, bytes[15]) << 16) |
                    (@as(u32, bytes[16]) << 24);

                const len: usize = @as(u32, bytes[17]) |
                    (@as(u32, bytes[18]) << 8) |
                    (@as(u32, bytes[19]) << 16) |
                    (@as(u32, bytes[20]) << 24);
                if (len > data.data.len) {
                    return error.DataBufferTooSmall;
                }

                data.len = len;
                data.data = bytes[21 .. 21 + len];
            },
            .Ack => {
                const ack = &self.kind.Ack;
                ack.ack = @as(u32, bytes[13]) |
                    (@as(u32, bytes[14]) << 8) |
                    (@as(u32, bytes[15]) << 16) |
                    (@as(u32, bytes[16]) << 24);
            },
            .EoT => {
                self.kind = .EoT;
            },
        }
    }
};

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
                    .data = try allocator.alloc(u8, (1024 * 10) - 21),
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
        kind_data.len = data.data.len;
        @memcpy(kind_data.data[0..data.data.len], data.data);

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
