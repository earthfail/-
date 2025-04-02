//! find connected components by ordering the nodes in reverese order by
//! finish time and working backward
const std = @import("std");
const Allocator = std.mem.Allocator;
const expect = std.testing.expect;
const ArrayList = std.ArrayList;
const Set = std.AutoArrayHashMap;
const Graph = std.AutoArrayHashMap(u8, ArrayList(u8));

// const ala = @import("address_logging_allocator.zig");

pub fn reverse(graph: Graph, allocator: Allocator) !Graph {
    var inward_graph = Graph.init(allocator);
    errdefer deinitGraphLists(&inward_graph);

    var it = graph.iterator();
    while (it.next()) |entry| {
        const n = entry.key_ptr.*;
        if(!inward_graph.contains(n)) {
            try inward_graph.put(n,ArrayList(u8).init(allocator));
        }
        const outward_vertices = entry.value_ptr.items;
        for (outward_vertices) |v| {
            if (!inward_graph.contains(v)) {
                try inward_graph.put(v, ArrayList(u8).init(allocator));
            }
            try inward_graph.getPtr(v).?.append(n);
        }
    }
    return inward_graph;
}
pub fn toposort(graph: Graph, n: u8, visited: *Set(u8, void), stack: *ArrayList(u8)) !void {
    if (graph.get(n)) |neighbors| {
        for (neighbors.items) |v| {
            if (!visited.contains(v)) {
                try visited.put(v, {});
                try toposort(graph, v, visited, stack);
            }
        }
    }
    try stack.append(n);
}
pub fn componentGraph(graph: Graph, n: u8, visited: *Set(u8, void), component: *ArrayList(u8)) !void {
    try component.append(n);
    if (graph.get(n)) |neighbors| {
        for (neighbors.items) |v| {
            if (!visited.contains(v)) {
                try visited.put(v, {});
                try componentGraph(graph, v, visited, component);
            }
        }
    }
    return;
}
pub fn strongConnectedComponents(graph: Graph, allocator: Allocator) !ArrayList(ArrayList(u8)) {
    var stack = ArrayList(u8).init(allocator);
    defer stack.deinit();
    {
        var visited = Set(u8, void).init(allocator);
        defer visited.deinit();

        var it = graph.iterator();
        while (it.next()) |entry| {
            const n = entry.key_ptr.*;
            if (!visited.contains(n)) {
                try visited.put(n, {});
                try toposort(graph, n, &visited, &stack);
            }
        }
    }
    var reverse_graph = try reverse(graph, allocator);
    
    defer deinitGraphLists(&reverse_graph);
    var components = ArrayList(ArrayList(u8)).init(allocator);
    {
        var visited = Set(u8, void).init(allocator);
        defer visited.deinit();
        var it = reverse_graph.iterator();
        while (it.next()) |entry| {
            const n = entry.key_ptr.*;
            if (!visited.contains(n)) {
                try visited.put(n, {});
                var component = ArrayList(u8).init(allocator);
                errdefer component.deinit();
                try componentGraph(reverse_graph, n, &visited, &component);
                try components.append(component);
            }
        }
    }
    return components;
}
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const g_allocator = gpa.allocator();
    defer {
        _ = gpa.detectLeaks();
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) expect(false) catch {
            @panic("gpa leaked");
        };
    }
    // var logging = std.heap.loggingAllocator(g_allocator);
    // const l_allocator = logging.allocator();
    // var address_logging = ala.addressLoggingAllocator(g_allocator);
    // const a_allocator = address_logging.allocator();
    const allocator = a_allocator;
    var list = [_][2]u8{ .{ 1, 2 }, .{ 2, 3 }, .{ 3, 4 }, .{ 3, 2 } };
    const adj: [][2]u8 = &list;
    for (adj) |uv| {
        std.debug.print("{}->{}\n", .{ uv[0], uv[1] });
    }
    var graph = try adjacencyList2Graph(adj, allocator);
    defer deinitGraphLists(&graph);
    // var reverse_graph = try reverse(graph, l_allocator);
    // defer deinitGraphLists(&reverse_graph);

    // _ = graph;
    std.debug.print("----------------\n", .{});
    printGraph(graph);
    std.debug.print("----------------\n", .{});
    const components = try strongConnectedComponents(graph, allocator);
    for (components.items, 1..) |component, i| {
        std.debug.print("component {}:", .{i});
        for (component.items) |v| {
            std.debug.print("{} ", .{v});
        }
        std.debug.print("\n", .{});
    }
    for (components.items) |comp| {
        comp.deinit();
    }
    components.deinit();
    // printGraph(reverse_graph);
}
pub fn printGraph(graph: Graph) void {
    var it = graph.iterator();
    while (it.next()) |entry| {
        std.debug.print("{}->", .{entry.key_ptr.*});
        for (entry.value_ptr.*.items) |v| {
            std.debug.print("{} ", .{v});
        }
        std.debug.print("\n", .{});
    }
}
pub fn init(allocator: Allocator) Graph {
    return std.AutoArrayHashMap(u8, ArrayList(u8)).init(allocator);
}
pub fn deinitGraphLists(self: *Graph) void {
    var it = self.iterator();
    while (it.next()) |entry| {
        entry.value_ptr.deinit();
    }
    self.deinit();
}
pub fn adjacencyList2Graph(adj: [][2]u8, allocator: Allocator) !Graph {
    var graph = Graph.init(allocator);
    errdefer deinitGraphLists(&graph);

    for (adj) |uv| {
        if (!graph.contains(uv[0])) {
            try graph.put(uv[0], ArrayList(u8).init(allocator));
        }
        if (!graph.contains(uv[1])) {
            try graph.put(uv[1], ArrayList(u8).init(allocator));
        }
        try graph.getPtr(uv[0]).?.append(uv[1]);
    }
    return graph;
}
