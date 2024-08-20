const std = @import("std");
const math = std.math;
const expectEqual = std.testing.expectEqual;

// Implementation of // https://blackpawn.com/texts/lightmaps/default.html.

const Rectangle = struct {
    id: i32,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
};

const Node = struct {
    left: ?*Node,
    right: ?*Node,
    rectangle: Rectangle,
};

pub const Packing = struct {
    size: u32,
    positions: [][2]i32,
};

/// Packs rectangles into a square texture atlas. Due to how the algorithm
/// works, there needs to be an initial estimation of size. The base value is a
/// square root of the total area of all rectangles multiplied by `area_factor`.
///
/// If the `area_factor` is too small the program will crash - this should be
/// fixed.
pub fn pack(allocator: std.mem.Allocator, sizes: [][2]i32, area_factor: f32) !Packing {
    const positions = try allocator.alloc([2]i32, sizes.len);

    var area: f32 = 0;
    for (sizes) |size| {
        area += @as(f32, @floatFromInt(size[0])) * @as(f32, @floatFromInt(size[1]));
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var rectangles = try arena_allocator.alloc(Rectangle, sizes.len);
    for (sizes, 0..) |size, i| {
        rectangles[i] = .{ .id = @intCast(i), .x = 0, .y = 0, .width = size[0], .height = size[1] };
    }
    std.mem.sort(Rectangle, rectangles, {}, sortBySizeFn);

    const approximateSize: i32 = @intFromFloat(@ceil(@sqrt(area) * area_factor));

    const root = try arena_allocator.create(Node);
    root.* = .{
        .left = null,
        .right = null,
        .rectangle = .{
            .id = std.math.maxInt(i32),
            .x = 0,
            .y = 0,
            .width = approximateSize,
            .height = approximateSize,
        },
    };

    for (rectangles) |rectangle| {
        if (try insert(arena_allocator, root, rectangle) == null) {
            return error.FailedToInsertRectangle;
        }
    }

    // Traverse the tree to get the positions.
    var queue = try arena_allocator.alloc(Node, sizes.len);
    var queueSize: usize = 0;
    queue[queueSize] = root.*;
    queueSize += 1;

    // Breadth-first search traverse the graph and find actual width and height.
    var realWidth: i32 = 0;
    var realHeight: i32 = 0;
    while (queueSize > 0) {
        queueSize -= 1;
        const node = queue[queueSize];
        if (node.rectangle.id != std.math.maxInt(i32)) {
            positions[@intCast(node.rectangle.id)] = .{ node.rectangle.x, node.rectangle.y };
            realWidth = @max(realWidth, node.rectangle.x + node.rectangle.width);
            realHeight = @max(realHeight, node.rectangle.y + node.rectangle.height);
        } else {
            if (node.left) |left| {
                queue[queueSize] = left.*;
                queueSize += 1;
            }
            if (node.right) |right| {
                queue[queueSize] = right.*;
                queueSize += 1;
            }
        }
    }

    return Packing{
        .size = ceilPowerOfTwo(@as(u32, @intCast(@max(realWidth, realHeight)))),
        .positions = positions,
    };
}

fn ceilPowerOfTwo(value: u32) u32 {
    var result: u32 = 1;
    while (result < value) {
        result <<= 1;
    }
    return result;
}

fn sign(value: f32) i32 {
    return if (value > 0) 1 else if (value < 0) -1 else 0;
}

fn sortBySizeFn(context: void, a: Rectangle, b: Rectangle) bool {
    _ = context;
    const areaA = a.width * a.height;
    const areaB = b.width * b.height;
    return areaB < areaA;
}

fn insert(allocator: std.mem.Allocator, node: *Node, rectangle: Rectangle) !?*Node {
    // If node is not a leaf, try inserting into first child.
    if (node.left != null and node.right != null) {
        if (try insert(allocator, node.left.?, rectangle)) |new_node| {
            return new_node;
        }
        return try insert(allocator, node.right.?, rectangle);
    } else {
        // If there is already a rectangle here, return.
        if (node.rectangle.id != std.math.maxInt(i32)) {
            return null;
        }

        // If this node is too small, return.
        if (node.rectangle.width < rectangle.width or node.rectangle.height < rectangle.height) {
            return null;
        }

        // If the new rectangle fits perfectly, accept.
        if (node.rectangle.width == rectangle.width and node.rectangle.height == rectangle.height) {
            node.rectangle.id = rectangle.id;
            return node;
        }

        // Otherwise, split this node into two children.
        node.left = try allocator.create(Node);
        node.right = try allocator.create(Node);
        node.left.?.* = .{ .left = null, .right = null, .rectangle = undefined };
        node.right.?.* = .{ .left = null, .right = null, .rectangle = undefined };

        const dw = node.rectangle.width - rectangle.width;
        const dh = node.rectangle.height - rectangle.height;

        if (dw > dh) {
            node.left.?.rectangle = .{
                .id = std.math.maxInt(i32),
                .x = node.rectangle.x,
                .y = node.rectangle.y,
                .width = rectangle.width,
                .height = node.rectangle.height,
            };

            node.right.?.rectangle = .{
                .id = std.math.maxInt(i32),
                .x = node.rectangle.x + rectangle.width,
                .y = node.rectangle.y,
                .width = dw,
                .height = node.rectangle.height,
            };
        } else {
            node.left.?.rectangle = .{
                .id = std.math.maxInt(i32),
                .x = node.rectangle.x,
                .y = node.rectangle.y,
                .width = node.rectangle.width,
                .height = rectangle.height,
            };

            node.right.?.rectangle = .{
                .id = std.math.maxInt(i32),
                .x = node.rectangle.x,
                .y = node.rectangle.y + rectangle.height,
                .width = node.rectangle.width,
                .height = dh,
            };
        }

        // Insert the new rectangle into the first child.
        return try insert(allocator, node.left.?, rectangle);
    }
}

test "packing" {
    const allocator = std.testing.allocator;
    const sizes = [_][2]i32{
        .{ 1, 1 },
        .{ 2, 2 },
        .{ 1, 1 },
        .{ 4, 1 },
        .{ 3, 3 },
    };
    const packing = try pack(allocator, &sizes, 1.15);
    defer allocator.free(packing.positions);

    try expectEqual(8, packing.size);
    try expectEqual(5, packing.positions[0][0]);
    try expectEqual(0, packing.positions[0][1]);
    try expectEqual(3, packing.positions[1][0]);
    try expectEqual(0, packing.positions[1][1]);
    try expectEqual(5, packing.positions[2][0]);
    try expectEqual(1, packing.positions[2][1]);
    try expectEqual(0, packing.positions[3][0]);
    try expectEqual(3, packing.positions[3][1]);
    try expectEqual(0, packing.positions[4][0]);
    try expectEqual(0, packing.positions[4][1]);
}
