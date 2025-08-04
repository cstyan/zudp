const std = @import("std");

pub const TrackingAllocator = struct {
    base_allocator: std.mem.Allocator,
    total_allocated: usize = 0,
    total_allocations: u32 = 0,
    current_allocated: usize = 0,
    max_allocated: usize = 0,

    pub fn init(a: std.mem.Allocator) TrackingAllocator {
        return TrackingAllocator{ .base_allocator = a };
    }

    fn rawAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        const mem = self.base_allocator.rawAlloc(len, alignment, ra) orelse return null;
        self.total_allocated += len;
        self.total_allocations += 1;
        self.current_allocated += len;
        if (self.current_allocated > self.max_allocated) {
            self.max_allocated = self.current_allocated;
        }
        return mem;
    }

    fn rawResize(ctx: *anyopaque, old_mem: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        const success = self.base_allocator.rawResize(old_mem, alignment, new_len, ra);
        if (!success) return false;

        const old_len = old_mem.len;
        if (new_len > old_len) {
            const diff = new_len - old_len;
            self.total_allocated += diff;
            self.current_allocated += diff;
        } else {
            self.current_allocated -= old_len - new_len;
        }

        if (self.current_allocated > self.max_allocated)
            self.max_allocated = self.current_allocated;

        return success;
    }

    fn rawFree(ctx: *anyopaque, mem: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        self.current_allocated -= mem.len;
        self.base_allocator.rawFree(mem, alignment, ra);
    }

    fn rawRemap(
        ctx: *anyopaque,
        old_mem: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ra: usize,
    ) ?[*]u8 {
        const self: *TrackingAllocator = @ptrCast(@alignCast(ctx));
        return self.base_allocator.rawRemap(old_mem, alignment, new_len, ra);
    }

    pub fn allocator(self: *TrackingAllocator) std.mem.Allocator {
        return std.mem.Allocator{
            .ptr = self,
            .vtable = &.{
                .alloc = rawAlloc,
                .resize = rawResize,
                .free = rawFree,
                .remap = rawRemap,
            },
        };
    }
};
