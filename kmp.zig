// Knuth Morris Patric algorithm
// used for searching for a string inside another string.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const mem = std.mem;
const ErrorMemory = mem.Allocator.Error;
/// return an array `sufpref` of length input.len such that sufpref[i] is the length of the longest
/// (strict) prefix of input[0..i+1] which is also a (strict) suffix of input[0..i+1] (strict means is not everything)
fn longestSuffixPrefix(allocator: mem.Allocator, input: []const u8) ErrorMemory![]const usize {
    assert(input.len > 0);
    // usize could be replaced by a smaller type for optimizations
    var sufprefix: []usize = try allocator.alloc(usize, input.len);
    sufprefix[0] = 0;
    var i: usize = 1;
    while (i < input.len) : (i += 1) {
        // what ever is the value of sufprefix[i] should be, we know that this prefix ends with input[i] and
        // a letter before it is input[i-1] and so all the letters of this prefix excluding the last one
        // (input[i]) is a prefix which is also a suffix of input[0..i] (the last slice the algorithm looked into before entering this iteration with i)
        // and so should be shorter than the longest prefix suffix.
        sufprefix[i] = 0;

        var j: usize = i;
        candidates: while (j > 0) {
            j -= 1;
            const start = sufprefix[j];
            for (input[start .. start + i - j], input[j + 1 .. i + 1]) |prefix, suffix| {
                if (prefix != suffix) {
                    continue :candidates;
                }
            } else {
                // characters from 0..start are checked via sufprefix[j] and the for loop above checks the
                // remaining characters from j+1 until i are equal to characters from start until the end
                // (until start+i-j exclusive)
                sufprefix[i] = sufprefix[i - 1] + 1;
                break;
            }
        }
        // old: could add this else branch to the candidates: while(j>0) : (j-=1)  with j initalized as
        // i-1 instead of i
        // else {
        //     // I didn't know how to make the condition of while to be j>=0 with j in usize and not get
        //     // integer overflow error
        //     if (input[0] == input[i])
        //         sufprefix[i] = 1;
        // }
    }
    return sufprefix;
}
const ErrorSearch = error{NotFound};
const ErrorKMP = ErrorSearch || ErrorMemory;
/// returns first occurrence of needle in haystack. aux_allocator is used to allocate memory but is never returned
fn searchKMPone(aux_allocator: mem.Allocator, haystack: []const u8, needle: []const u8) ErrorKMP!usize {
    if (needle.len == 0)
        return ErrorSearch.NotFound;

    const sufprefix = try longestSuffixPrefix(aux_allocator, needle);
    defer aux_allocator.free(sufprefix);

    var it_hay: usize = 0;
    var it_ndle: usize = 0;
    while (it_ndle < needle.len and it_hay < haystack.len) {
        if (needle[it_ndle] == haystack[it_hay]) {
            it_ndle += 1;
            it_hay += 1;
        } else {
            if (it_ndle == 0) {
                it_hay += 1;
            } else {
                it_ndle = sufprefix[it_ndle - 1];
            }
        }
    }
    if (it_ndle == needle.len) {
        return it_hay - needle.len;
    }
    assert(it_hay == haystack.len);
    return ErrorSearch.NotFound;
}
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        const check = gpa.deinit();
        if (check == .leak) {
            @panic("there was a leak. call a plumber");
        }
    }
    // var buffer: [1024]u8 = undefined;
    const stdin = std.io.getStdIn().reader();

    const print = std.debug.print;
    print("Salam\n", .{});

    print("Please Enter text to search into (max 1023)\n", .{});
    // for window it is \r\n for linux it should be \n. I have compatibility issues
    const line_input = try stdin.readUntilDelimiterAlloc(allocator, '\n', 1024);
    const input: []const u8 = if (builtin.os.tag == .windows) std.mem.trimRight(u8, line_input, "\r") else line_input;
    defer allocator.free(line_input);
    print("got input \"{s}\" {any}\n", .{ input, input });

    print("Please Enter text to search for\n", .{});
    const line_needle = try stdin.readUntilDelimiterAlloc(allocator, '\n', 1024);
    const needle: []const u8 = if (builtin.os.tag == .windows) std.mem.trimRight(u8, line_needle, "\r") else line_needle;
    defer allocator.free(line_needle);
    print("got needle \"{s}\" {any}\n", .{ needle, needle });

    if (false) {
        const result = try longestSuffixPrefix(allocator, input);
        defer allocator.free(result);
        // print("got result {any}\n", .{result});
        for (result, 0..) |r, i| {
            print("{}: {}\n", .{ i, r });
        }
        var all_valid = true;
        for (result, 1..) |prefix_len, i| {
            if (!checkPrefixSuffixProperty(input[0..i], prefix_len)) {
                print("index {} failed the prefix-suffix property. Got {}\n", .{ i - 1, prefix_len });
                print("    prefix: {s}\n", .{input[0..prefix_len]});
                print("    suffix: {s}\n", .{input[i - prefix_len .. i]});
                all_valid = false;
            }
        }
        if (all_valid) {
            print("prefix-suffix property is true for input\n", .{});
        }
    }
    if (searchKMPone(allocator, input, needle)) |index| {
        print("found \"{s}\" in \"{s}\" at {}\n", .{ needle, input, index });
    } else |err| {
        print("didn't find it because {}\n", .{err});
    }

    print("Salam\n", .{});
}

/// check if input[0..prefix_len] is indeed a suffix
fn checkPrefixSuffixProperty(input: []const u8, prefix_len: usize) bool {
    assert(prefix_len < input.len);
    const len = input.len;
    for (input[0..prefix_len], input[len - prefix_len .. len]) |prefix, suffix| {
        if (prefix != suffix) {
            return false;
        }
    }
    return true;
}
