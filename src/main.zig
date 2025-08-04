const std = @import("std");
const net = std.net;
const posix = std.posix;
const packet = @import("packet.zig");
const tracking_allocator = @import("tracking_allocator.zig");

const sender = net.Address.initIp4(.{ 127, 0, 0, 1 }, 9090);
const receiver = net.Address.initIp4(.{ 127, 0, 0, 1 }, 9091);

const Error = error{
    ErrotEoT,
    NoAck,
};

var recv_buffer: [1024]u8 = [_]u8{0} ** 1024;
var send_buffer: [1024]u8 = [_]u8{0} ** 1024;

fn handle_recv_window(sock: std.posix.socket_t, expectedSeq: *u32) !void {
    var highest_seq_seen: ?u32 = null;
    var recv_count: usize = 0;

    var addr: std.posix.sockaddr = undefined;
    var addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
    var s: ?std.net.Ip4Address = null;
    var r: ?std.net.Ip4Address = null;

    // Only needed for random packet dropping, until we move that into it's own code path.
    var prng = std.Random.DefaultPrng.init(@intCast(std.time.nanoTimestamp()));
    const rand = prng.random();
    var dropRand: f64 = undefined;
    const percent_drop: f64 = 1; // 1% chance

    var recv_buf: [1024]u8 = undefined;
    var pkt = packet.Packet{
        .src = sender.in,
        .dest = receiver.in,
        .kind = packet.Kind{ .Data = .{
            .seq = 0,
            .len = recv_buf.len,
            .data = @constCast(&recv_buffer),
        } },
    };

    var it: u32 = 0;
    while (recv_count < packet.window_size) {
        const ret = posix.recvfrom(sock, @constCast(&recv_buf), 0, &addr, &addr_len) catch |err| switch (err) {
            error.WouldBlock => {
                // We haven't received anything yet, so nothing to ACK.
                if (highest_seq_seen == null) {
                    continue;
                }
                break;
            },
            else => return err,
        };
        it += 1;

        if (ret == 0) {
            // This shouldn't be possible since the socket is blocking, but lets just be safe.
            continue;
        }

        recv_count += 1;

        const kind = try packet.check_kind(&recv_buf);

        switch (kind) {
            .Data => {
                try pkt.deserialize_data(&recv_buf);
                r = pkt.dest;
                s = pkt.src;

                if (pkt.kind.Data.seq == expectedSeq.*) {
                    dropRand = rand.float(f64) * 100.0; // random in [0, 100)
                    if (dropRand < percent_drop) {
                        continue;
                    }

                    std.debug.print("{s}", .{pkt.kind.Data.data[0..pkt.kind.Data.len]});
                    highest_seq_seen = pkt.kind.Data.seq;
                    expectedSeq.* += 1;
                } else {
                    // Out of order packet — ignore or handle according to your protocol/application needs.
                }
            },
            .Ack => {
                // Ignore incoming ACKs here if you want
            },
            .EoT => {
                // we should ACK here and exit
                std.debug.print("\n", .{});
                return error.ErrotEoT;
            },
        }
    }

    // Even though we shouldn't ever reach here and still have a null highest_seq_seen, lets be defensive.
    if (highest_seq_seen) |val| {
        const ack = packet.Packet{
            .src = r orelse receiver.in,
            .dest = s orelse sender.in,
            .kind = packet.Kind{
                .Ack = .{ .ack = val },
            },
        };

        const n = try ack.serialize(@constCast(&send_buffer));
        // We could retry this send, but the sender will retransmit packets within the window that were not ack'd anyways.
        _ = try std.posix.sendto(sock, send_buffer[0..n], 0, &addr, addr_len);
    }
}

fn recv_loop() !void {
    const sock = try posix.socket(
        posix.AF.INET,
        posix.SOCK.DGRAM,
        posix.IPPROTO.UDP,
    );

    const timeout_ms = 100;
    const timeval = std.posix.timeval{
        .sec = @intCast(timeout_ms / 1000),
        .usec = @intCast((timeout_ms % 1000) * 1000),
    };
    try std.posix.setsockopt(
        sock,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVTIMEO,
        std.mem.asBytes(&timeval),
    );
    var expected_seq: u32 = 0;
    try std.posix.bind(sock, @ptrCast(&receiver.any), receiver.in.getOsSockLen());

    while (true) {
        handle_recv_window(sock, &expected_seq) catch |err| switch (err) {
            error.ErrotEoT => {
                std.debug.print("got an eot", .{});
                return;
            },
            else => return err,
        };
    }
}

fn send_window(sock: std.posix.socket_t, window: packet.PacketWindow) !u32 {
    for (0..window.count) |i| {
        const index = (window.head + i) % window.buffer.len;
        const pkt = window.buffer[index];
        const n = try pkt.serialize(@constCast(&send_buffer));
        _ = try std.posix.sendto(sock, send_buffer[0..n], 0, @ptrCast(&receiver.any), receiver.getOsSockLen());
    }

    var buf: [1024]u8 = undefined;

    const recv_len = std.posix.recvfrom(sock, @constCast(&buf), 0, null, null) catch |err| switch (err) {
        error.WouldBlock => { // Would block is how the timeout is represented for recvfrom.
            std.debug.print("Timeout waiting for ack, retrying...\n", .{});
            return error.NoAck;
        },
        else => return err,
    };

    const pkt_recv = try packet.Packet.deserialize(buf[0..recv_len]);

    switch (pkt_recv.kind) {
        .Ack => |ack| {
            return ack.ack;
        },
        else => std.debug.print("Unexpected packet received while waiting for ack\n", .{}),
    }
    return error.NoAck;
}

fn build_window(window: *packet.PacketWindow, f: std.fs.File) !void {
    var buf: [1024 - 21]u8 = undefined;
    while (true) {
        if (!window.can_push()) {
            return;
        }
        const bytesRead = try f.read(buf[0..]);
        if (bytesRead == 0) {
            return error.ErrotEoT; // EOF reached
        }
        window.push_data(.{ .src = sender.in, .dest = receiver.in, .seq = @intCast(window.next_seq), .data = buf[0..bytesRead] }) catch break;
    }
}

fn send_loop(allocator: std.mem.Allocator) !void {
    const sock = try posix.socket(
        posix.AF.INET,
        posix.SOCK.DGRAM,
        posix.IPPROTO.UDP,
    );
    const timeout_ms = 200;
    const timeval = std.posix.timeval{
        .sec = @intCast(timeout_ms / 1000),
        .usec = @intCast((timeout_ms % 1000) * 1000),
    };
    try std.posix.setsockopt(
        sock,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVTIMEO,
        std.mem.asBytes(&timeval),
    );
    // We'll try to  recv acks too so bind early.
    try std.posix.bind(sock, @ptrCast(&sender.any), sender.in.getOsSockLen());

    var file = try std.fs.cwd().openFile("book.txt", .{});
    defer file.close();
    var window = packet.PacketWindow{
        .buffer = undefined,
        .base_seq = 0,
        .count = 0,
        .head = 0,
    };
    try window.initalize(allocator);
    defer window.deinit(allocator);

    while (true) {
        build_window(&window, file) catch |err| switch (err) {
            error.ErrotEoT => {
                if (window.count == 0) {
                    break;
                }
            },
            else => return err,
        };
        const ack = send_window(sock, window) catch |err| switch (err) {
            error.NoAck => continue,
            else => return err,
        };
        window.ack(ack);
        if (window.count != 0) {
            continue;
        }
    }
    // All of our packets have been ack'd, we can signal that this is the end of transmission.
    const eot = packet.Packet{
        .src = sender.in,
        .dest = receiver.in,
        .kind = .EoT,
    };
    const buffer = try allocator.alloc(u8, 1024);
    const n = try eot.serialize(buffer);
    _ = posix.sendto(sock, buffer[0..n], 0, @ptrCast(&receiver.any), receiver.getOsSockLen()) catch |err| {
        std.debug.print("error sending EoT to reciever, it should timeout anyways: {}", .{err});
        return err;
    };
    allocator.free(buffer);
}

const Mode = enum {
    send,
    recv,
};

fn parseModeArg() !Mode {
    var args = std.process.args();
    _ = args.next(); // skip program name

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--mode")) {
            if (args.next()) |value| {
                return if (std.mem.eql(u8, value, "send")) Mode.send else if (std.mem.eql(u8, value, "recv")) Mode.recv else error.InvalidMode;
            } else {
                return error.MissingModeValue;
            }
        }
    }

    return error.NoModeSpecified;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};

    var tracker = tracking_allocator.TrackingAllocator.init(gpa.allocator());
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.debug.print("Memory leaked!\n", .{});
        }
    }
    const mode = try parseModeArg();

    switch (mode) {
        .send => try send_loop(tracker.allocator()),
        .recv => try recv_loop(),
    }
    std.debug.print("\nTotal allocated: {}, Total allocations: {}, Current usage: {}, Max usage: {}\n", .{ tracker.total_allocated, tracker.total_allocations, tracker.current_allocated, tracker.max_allocated });
}
