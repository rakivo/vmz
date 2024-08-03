const std = @import("std");

const mem  = std.mem;
const math = std.math;

const Allocator = std.mem.Allocator;

const assert = std.debug.assert;

/// Double-ended queue ported from Rust's standard library, which is provided under MIT License.
/// It can be found at https://github.com/rust-lang/rust/blob/master/LICENSE-MIT
pub fn VecDeque(comptime T: type) type {
    return struct {
        /// tail and head are pointers into the buffer. Tail always points
        /// to the first element that could be read, Head always points
        /// to where data should be written.
        /// If tail == head the buffer is empty. The length of the ringbuffer
        /// is defined as the distance between the two.
        tail: usize,
        head: usize,
        /// Users should **NOT** use this field directly.
        /// In order to access an item with an index, use `get` method.
        /// If you want to iterate over the items, call `iterator` method to get an iterator.
        buf: []T,
        allocator: Allocator,

        const Self = @This();
        const INITIAL_CAPACITY = 7; // 2^3 - 1
        const MINIMUM_CAPACITY = 1; // 2 - 1

        /// Creates an empty deque.
        /// Deinitialize with `deinit`.
        pub inline fn init(allocator: Allocator) Allocator.Error!Self {
            return initCapacity(allocator, INITIAL_CAPACITY);
        }

        /// Creates an empty deque with space for at least `capacity` elements.
        ///
        /// Note that there is no guarantee that the created VecDeque has the specified capacity.
        /// If it is too large, this method gives up meeting the capacity requirement.
        /// In that case, it will instead create a VecDeque with the default capacity anyway.
        ///
        /// Deinitialize with `deinit`.
        pub fn initCapacity(allocator: Allocator, capacity: usize) Allocator.Error!Self {
            const effective_cap =
                math.ceilPowerOfTwo(usize, @max(capacity +| 1, MINIMUM_CAPACITY + 1)) catch
                math.ceilPowerOfTwoAssert(usize, INITIAL_CAPACITY + 1);
            const buf = try allocator.alloc(T, effective_cap);
            return Self{
                .tail = 0,
                .head = 0,
                .buf = buf,
                .allocator = allocator,
            };
        }

        /// Release all allocated memory.
        pub inline fn deinit(self: *Self) void {
            self.allocator.free(self.buf);
        }

        /// Returns the length of the already-allocated buffer.
        pub inline fn cap(self: *const Self) usize {
            return self.buf.len;
        }

        /// Returns the number of elements in the deque.
        pub inline fn len(self: *const Self) usize {
            return count(self.tail, self.head, self.cap());
        }

        /// Gets the pointer to the element with the given index, if any.
        /// Otherwise it returns `null`.
        pub inline fn get(self: *Self, index: usize) ?*T {
            const idx = self.wrapAdd(self.tail, index);
            return &self.buf[idx];
        }

        /// Gets the pointer to the first element, if any.
        pub inline fn front(self: *Self) ?*T {
            return self.get(0);
        }

        /// Gets the pointer to the last element, if any.
        pub inline fn back(self: *Self) ?*T {
            const last_idx = math.sub(usize, self.len(), 1) catch return null;
            return self.get(last_idx);
        }

        /// Swaps two elements
        pub inline fn swap(self: *Self, a_: usize, b_: usize) void {
            const a = self.get(a_).?;
            const b = self.get(b_).?;
            const t = b.*;
            b.* = a.*;
            a.* = t;
        }

        /// Adds the given element to the back of the deque.
        pub fn pushBack(self: *Self, item: T) void {
            if (self.isFull()) self.grow();
            const head = self.head;
            self.head = self.wrapAdd(self.head, 1);
            self.buf[head] = item;
        }

        /// Adds the given element to the front of the deque.
        pub fn pushFront(self: *Self, item: T) void {
            if (self.isFull()) self.grow();
            self.tail = self.wrapSub(self.tail, 1);
            const tail = self.tail;
            self.buf[tail] = item;
        }

        /// Pops and returns the last element of the deque.
        pub fn popBack(self: *Self) ?T {
            self.head = self.wrapSub(self.head, 1);
            const head = self.head;
            const item = self.buf[head];
            self.buf[head] = undefined;
            return item;
        }

        /// Pops and returns the first element of the deque.
        pub fn popFront(self: *Self) ?T {
            const tail = self.tail;
            self.tail = self.wrapAdd(self.tail, 1);
            const item = self.buf[tail];
            self.buf[tail] = undefined;
            return item;
        }

        /// Adds all the elements in the given slice to the back of the deque.
        pub inline fn appendSlice(self: *Self, items: []const T) void {
            for (items) |item| self.pushBack(item);
        }

        /// Adds all the elements in the given slice to the front of the deque.
        pub fn prependSlice(self: *Self, items: []const T) Allocator.Error!void {
            var i: usize = items.len - 1;
            while (true) : (i -= 1) {
                const item = items[i];
                try self.pushFront(item);
                if (i == 0) break;
            }
        }

        /// Returns an iterator over the deque.
        /// Modifying the deque may invalidate this iterator.
        pub inline fn iterator(self: *const Self) Iterator {
            return .{
                .head = self.head,
                .tail = self.tail,
                .ring = self.buf,
            };
        }

        pub fn format(self: *const Self, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
            try writer.writeAll("[");

            var it = self.iterator();
            if (it.next()) |val| try writer.print("{any}", .{val});
            while (it.next()) |val| try writer.print(", {any}", .{val});

            try writer.writeAll("]");
        }

        pub const Iterator = struct {
            head: usize,
            tail: usize,
            ring: []T,

            pub fn next(it: *Iterator) ?*T {
                if (it.head == it.tail) return null;

                const tail = it.tail;
                it.tail = wrapIndex(it.tail +% 1, it.ring.len);
                return &it.ring[tail];
            }

            pub fn nextBack(it: *Iterator) ?*T {
                if (it.head == it.tail) return null;

                it.head = wrapIndex(it.head -% 1, it.ring.len);
                return &it.ring[it.head];
            }
        };

        /// Returns `true` if the buffer is at full capacity.
        inline fn isFull(self: *const Self) bool {
            return self.cap() - self.len() == 1;
        }

        inline fn grow(self: *Self) void {
            const old_cap = self.cap();
            self.buf = self.allocator.realloc(self.buf, old_cap * 2) catch |err| {
                std.debug.print("ERROR: FAILED TO REALLOC VEC_DEQUE: {}\n", .{err});
                std.process.exit(1);
            };
            self.handleCapacityIncrease(old_cap);
        }

        /// Updates `tail` and `head` values to handle the fact that we just reallocated the internal buffer.
        fn handleCapacityIncrease(self: *Self, old_capacity: usize) void {
            const new_capacity = self.cap();

            // Move the shortest contiguous section of the ring buffer.
            // There are three cases to consider:
            //
            // (A) No need to update
            //          T             H
            // before: [o o o o o o o . ]
            //
            // after : [o o o o o o o . . . . . . . . . ]
            //          T             H
            //
            //
            // (B) [..H] needs to be moved
            //              H T
            // before: [o o . o o o o o ]
            //          ---
            //           |_______________.
            //                           |
            //                           v
            //                          ---
            // after : [. . . o o o o o o o . . . . . . ]
            //                T             H
            //
            //
            // (C) [T..old_capacity] needs to be moved
            //                    H T
            // before: [o o o o o . o o ]
            //                      ---
            //                       |_______________.
            //                                       |
            //                                       v
            //                                      ---
            // after : [o o o o o . . . . . . . . . o o ]
            //                    H                 T

            if (self.tail <= self.head) {
                // (A), Nop
            } else if (self.head < old_capacity - self.tail) {
                // (B)
                self.copyNonOverlapping(old_capacity, 0, self.head);
                self.head += old_capacity;
                assert(self.head > self.tail);
            } else {
                // (C)
                const new_tail = new_capacity - (old_capacity - self.tail);
                self.copyNonOverlapping(new_tail, self.tail, old_capacity - self.tail);
                self.tail = new_tail;
                assert(self.head < self.tail);
            }
            assert(self.head < self.cap());
            assert(self.tail < self.cap());
        }

        inline fn copyNonOverlapping(self: *Self, dest: usize, src: usize, length: usize) void {
            assert(dest + length <= self.cap());
            assert(src + length <= self.cap());
            @memcpy(self.buf[dest .. dest + length], self.buf[src .. src + length]);
        }

        inline fn wrapAdd(self: *const Self, idx: usize, addend: usize) usize {
            return wrapIndex(idx +% addend, self.cap());
        }

        inline fn wrapSub(self: *const Self, idx: usize, subtrahend: usize) usize {
            return wrapIndex(idx -% subtrahend, self.cap());
        }
    };
}

inline fn count(tail: usize, head: usize, size: usize) usize {
    return (head -% tail) & (size - 1);
}

inline fn wrapIndex(index: usize, size: usize) usize {
    return index & (size - 1);
}
