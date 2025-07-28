const std = @import("std");
const net = std.net;
const posix = std.posix;
const packet = @import("packet.zig");

const sender = net.Address.initIp4(.{ 127, 0, 0, 1 }, 9090);
const receiver = net.Address.initIp4(.{ 127, 0, 0, 1 }, 9091);

const Error = error{
    ErrotEoT,
};

fn simulate_network(sock: std.posix.socket_t, percent_drop: f64, rng: std.Random) !void {
    var r: f64 = undefined;
    const buf: [1024]u8 = undefined;

    while (true) {
        r = rng.float(f64) * 100.0; // random in [0, 100)
        const ret = try posix.recvfrom(sock, @constCast(&buf), 0, null, null);
        if (r < percent_drop) {
            std.debug.print("Simulated error at iteration\n", .{});
            continue;
        }
        std.debug.print("data received {d} {s}", .{ ret, buf[0..ret] });
    }
}

// fn run_network() !void {
//     const sock = try posix.socket(
//         posix.AF.INET,
//         posix.SOCK.DGRAM,
//         posix.IPPROTO.UDP,
//     );

//     var prng = std.Random.DefaultPrng.init(@intCast(std.time.nanoTimestamp()));
//     const rand = prng.random();

//     const percent_chance: f64 = 50; // 0.1% chance

//     const sockAddr = comptime net.Address.initIp4(.{ 0, 0, 0, 0 }, 9090);
//     // const len = comptime sockAddr.in.getOsSockLen();
//     try std.posix.bind(sock, @ptrCast(&sockAddr.any), sockAddr.in.getOsSockLen());
//     try simulate_network(sock, percent_chance, rand);
// }

fn handle_recv(allocator: std.mem.Allocator, senderAddr: std.posix.sockaddr, senderLen: std.posix.socklen_t, s: std.posix.socket_t, p: packet.Packet, expectedSeq: *u32) !void {
    switch (p.kind) {
        .Data => |d| {
            if (d.seq != expectedSeq.*) {
                return;
            }
            std.debug.print("{s}", .{d.data});
            // if packet was EOT also end an EOT
            const ack = packet.Packet{
                .src = p.dest,
                .dest = p.src,
                .kind = packet.Kind{
                    .Ack = .{ .ack = expectedSeq.* },
                },
            };
            const buffer = try allocator.alloc(u8, 1024);
            const n = try ack.serialize(buffer);
            _ = posix.sendto(s, buffer[0..n], 0, &senderAddr, senderLen) catch |err| {
                // std.debug.print("error trying to send an ack back to receiver: {}", .{err});
                return err;
            };
            allocator.free(buffer);
            expectedSeq.* += 1;
        },
        .Ack => return,
        .EoT => {
            std.debug.print("\n", .{});
            // we should return some kind of error telling the main loop that it can exit
            return Error.ErrotEoT;
        },
    }
}

// recv packets in a loop and ack them untul we recv an eot
fn recv_loop(allocator: std.mem.Allocator) !void {
    const sock = try posix.socket(
        posix.AF.INET,
        posix.SOCK.DGRAM,
        posix.IPPROTO.UDP,
    );

    try std.posix.bind(sock, @ptrCast(&receiver.any), receiver.in.getOsSockLen());

    const buf: [1024]u8 = undefined;
    var expectedSeq: u32 = 0;

    var addr: std.posix.sockaddr = undefined;
    var addr_len: std.posix.socklen_t = @sizeOf(std.posix.sockaddr);
    var prng = std.Random.DefaultPrng.init(@intCast(std.time.nanoTimestamp()));
    const rand = prng.random();
    var r: f64 = undefined;
    const percent_drop: f64 = 1; // 1% chance

    while (true) {
        const ret = try posix.recvfrom(sock, @constCast(&buf), 0, &addr, &addr_len);
        // parse out the sender and then make an ack packet and send it back
        if (ret == 0) {
            // This shouldn't be possible since the socket is blocking, but lets just be safe.
            continue;
        }
        const p = try packet.Packet.deserialize(buf[0..ret]);
        r = rand.float(f64) * 100.0; // random in [0, 100)
        if (r < percent_drop and p.kind != .EoT) {
            continue;
        }
        handle_recv(allocator, addr, addr_len, sock, p, &expectedSeq) catch |err| {
            if (err == Error.ErrotEoT) {
                std.debug.print("\ngot an EoT, exiting\n", .{});
                return;
            }
            return err;
        };
    }
}

fn send_wait(
    sock: std.posix.socket_t,
    allocator: std.mem.Allocator,
    pkt: *const packet.Packet,
    expect_ack: u32,
    timeout_ms: u64,
) !void {
    const buffer = try allocator.alloc(u8, 1024);

    const n = try pkt.serialize(buffer);
    defer allocator.free(buffer);

    const buf: [1024]u8 = undefined;

    while (true) {
        _ = try std.posix.sendto(sock, buffer[0..n], 0, @ptrCast(&receiver.any), receiver.getOsSockLen());

        // Set receive timeout
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

        const recv_len = std.posix.recvfrom(sock, @constCast(&buf), 0, null, null) catch |err| switch (err) {
            error.WouldBlock => { // would block is how the timeout is represented for recvfrom
                std.debug.print("Timeout waiting for ack {d}, retrying...\n", .{expect_ack});
                continue; // retry
            },
            else => return err,
        };

        const pkt_recv = try packet.Packet.deserialize(buf[0..recv_len]);

        switch (pkt_recv.kind) {
            .Ack => |ack| {
                if (ack.ack == expect_ack) {
                    return;
                }
            },
            else => std.debug.print("Unexpected packet received while waiting for ack\n", .{}),
        }
    }
}

fn send_loop(allocator: std.mem.Allocator) !void {
    const sock = try posix.socket(
        posix.AF.INET,
        posix.SOCK.DGRAM,
        posix.IPPROTO.UDP,
    );
    // we'll try to  recv acks too so bind early
    try std.posix.bind(sock, @ptrCast(&sender.any), sender.in.getOsSockLen());

    var expectAck: u32 = 0;
    var file = try std.fs.cwd().openFile("book.txt", .{});
    defer file.close();

    // to start we'll excpect to send and recv acks in sequence
    while (true) {
        // we need to account for the space needed to write the packet header
        var buf: [1024 - 25]u8 = undefined;

        const bytesRead = try file.read(buf[0..]);
        if (bytesRead == 0) break; // EOF reached
        // std.debug.print("bytes read: .{d}", .{bytesRead});

        var p = try packet.initDataPacket(
            allocator,
            sender.in,
            receiver.in,
            @intCast(expectAck),
            expectAck,
            buf[0..bytesRead],
        );
        errdefer p.deinit(allocator);

        try send_wait(sock, allocator, &p, expectAck, 100);
        p.deinit(allocator);
        expectAck += 1;
    }
    // all of our packets have been ack'd
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
    defer {
        const leaked = gpa.deinit();
        if (leaked == .leak) {
            std.debug.print("Memory leaked!\n", .{});
        }
    }
    const allocator = gpa.allocator();
    const mode = try parseModeArg();

    switch (mode) {
        .send => try send_loop(allocator),
        .recv => try recv_loop(allocator),
    }
}
