const std = @import("std");
const ArrayList = std.ArrayList;
const HashMap = std.AutoArrayHashMap;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const log = std.log;

const timezone_offset = 1; // NOTE(salim): hack to replace importing a library or learn how time zones work
// Note(Salim): taken data structurs from from timestamp_parse.zig
pub fn main() !void {
    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const allocator = gpa.allocator();

    var args = std.process.args();

    const exe_file = args.next().?;
    std.debug.print("Salam this file is:{s}, exec_file is:{s}\n", .{ @src().file, exe_file });

    var hours_filename: ?[]const u8 = null;
    var op: Operation = .parse;
    const flag_start = "--";

    var i_while: usize = 0;
    while (args.next()) |arg| : (i_while += 1) {
        if (startsWith(arg, flag_start)) {
            const flag = arg[flag_start.len..];
            std.debug.print("flag is |{s}|\n", .{flag});
            if (eql(flag, "parse")) {
                op = .parse;
            } else if (eql(flag, "query")) {
                op = .query; // search for all lessons of a particular student
            } else if (eql(flag, "insert")) {
                op = .insert;
            } else if (eql(flag, "help")) {
                try stdout.writeAll(
                    \\ arguments: [file] [options]
                    \\ --help for this message
                    \\ --insert : interactive lesson entry and if a file is provided will append the formatted entry to the file
                    \\            finally will ask if you would like to stamp this in last pdf file
                    \\ --parse  : parse file (default if provided) or stdin for lines in the entry format and prints the total minutes
                    \\ --query  : search for lessons for a student and compute total minutes, file is required
                    \\ entry format: <student_name>: <timestamp> -> <timestamp>
                    \\ student_name is just characters not containing ':'
                    \\ timestamp: dd:dd where d is a digit. It represents the hour and minute
                    \\
                );
                return;
            }
        } else {
            if (i_while == 0 and hours_filename == null) {
                hours_filename = try allocator.dupeZ(u8, arg);
            }
        }
    }
    std.debug.print("hours filename {?s}\n", .{hours_filename});

    switch (op) {
        .insert => {
            var buffer: [1024]u8 = undefined;

            var name: [1024 + 1]u8 = undefined;
            var timestamps: [2][2 * 3 + 2 + 1]u8 = undefined; // three numbers with two digits each and two colons between at max

            try stdout.writeAll("please write student name\n");
            if (sanitizeLine(stdin, &buffer)) |line| {
                // TOOD(Salim): unretard this retardness
                @memcpy(name[0..line.len], line);
                name[line.len] = 0;
            } else |err| {
                std.debug.print("got error(or null) while expecting full name line: {}\n", .{err});
                return error.NoName;
            }

            for (&timestamps, 1..3) |*timestamp, i| {
                const placement = if (i == 1) "start" else "finish";
                try stdout.print("please write {s} time stamp(leave empty for current timestamp):", .{placement});

                if (sanitizeLine(stdin, &buffer)) |line| {
                    if (line.len != 0) {
                        @memcpy(timestamp[0..line.len], line);
                        timestamp[line.len] = 0;
                    } else {
                        // there is std.fmt.fmt.Duration
                        const now_seconds: i64 = std.time.timestamp();
                        const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @as(u64, @intCast(now_seconds)) };
                        const day_seconds = epoch_seconds.getDaySeconds();

                        const hour = (day_seconds.getHoursIntoDay() + 1 + timezone_offset) % 24;
                        const minute = day_seconds.getMinutesIntoHour();

                        const timestamp_format = std.fmt.bufPrintZ(timestamp, "{d:02}:{d:02}", .{ hour, minute }) catch {
                            std.debug.print("timestamps in function {s} need more space\n", .{@src().fn_name});
                            return;
                        };
                        // std.mem.copyBackwards(u8, timestamp.*, timestamp_format);
                        stdout.print("got timestamp {s}\n", .{timestamp_format}) catch {};
                    }
                } else |err| {
                    std.debug.print("got error(or null) while expecting {s} time stamp: {}\n", .{ placement, err });
                    return error.NoTimeStamp;
                }
            }
            var format_buffer: [name.len + 2 * timestamps.len + 128]u8 = undefined;
            const day_month = mnth: {
                const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @as(u64, @intCast(std.time.timestamp())) };
                const year_day = epoch_seconds.getEpochDay().calculateYearDay();
                const month_day = year_day.calculateMonthDay();
                break :mnth month_day.day_index + 1;
            };
            const begtime_slice = std.mem.sliceTo(&timestamps[0], 0);
            const fintime_slice = std.mem.sliceTo(&timestamps[1], 0);
            const format_string = try std.fmt.bufPrint(&format_buffer, "d{d}) {s}: {s} -> {s}\n", .{
                day_month,
                std.mem.sliceTo(&name, 0),
                begtime_slice,
                fintime_slice,
            });
            try stdout.writeAll(format_string);
            if (hours_filename) |hours_file| {
                const hours = try std.fs.cwd().openFile(hours_file, .{ .mode = .write_only });
                defer hours.close();
                try hours.seekFromEnd(0);

                try hours.writeAll(format_string);
            }
            try stdout.writeAll("Would you like to stamp last pdf file in ~/Downloads/Tmp (y/N)?\n");
            if (sanitizeLine(stdin, &buffer)) |input_line| {
                if (startsWith(input_line, "y")) {
                    //BUG(Salim): first page will not copy images from the original.
                    // will not fix
                    stampLastFile(allocator, begtime_slice, fintime_slice) catch |err| {
                        std.debug.print("stampLastFile failed with error: {}\n", .{err});
                    };
                }
            } else |_| {}
        },
        .query => {
            if (hours_filename) |hours_file_v| {
                const hours_file = try std.fs.cwd().openFile(hours_file_v, .{ .mode = .read_only });
                defer hours_file.close();
                var arena = std.heap.ArenaAllocator.init(allocator);
                defer arena.deinit();
                const arena_allocator = arena.allocator();

                const input_stream: std.io.AnyReader = rdr: {
                    const hours_reader = hours_file.reader();
                    const hours = try hours_reader.readAllAlloc(arena_allocator, std.math.maxInt(u32));
                    if (hours.len == 0) return error.FileEmpty;

                    // NOTE(Salim): Shitty performance, shitty logic.
                    const new_month_line = "تسجيل شهر";
                    var line_it = std.mem.splitBackwardsAny(u8, hours, "\r\n");
                    var month_index: [2]usize = .{ hours.len, hours.len };
                    var last_line_index: usize = undefined;
                    var curr_line_index: usize = hours.len;
                    while (line_it.next()) |line| {
                        last_line_index = curr_line_index;
                        curr_line_index = line_it.index.?;

                        if (startsWith(line, new_month_line)) {
                            month_index[1] = month_index[0];
                            month_index[0] = curr_line_index;

                            try stdout.print("Do you want to parse {s} (Y/n)?\n", .{line});
                            var input_buffer: [10]u8 = undefined;
                            if (sanitizeLine(stdin, &input_buffer)) |input_line| {
                                if (input_line.len == 0 or startsWith(input_line, "y"))
                                    break;
                            } else |_| {}
                        }
                    }

                    const fbs = std.io.fixedBufferStream(hours[last_line_index..month_index[1]]);
                    const fbs_heap = try arena_allocator.create(@TypeOf(fbs));
                    fbs_heap.* = fbs;
                    break :rdr fbs_heap.reader().any();
                };

                //const input_stream: std.io.AnyReader = try promptMonthsBackward(stdout, stdin, allocator, hours_file, &hours);

                var buffer: [3 * 1024]u8 = undefined;
                var name_buffer: [1024 + 1]u8 = undefined;
                var name: []const u8 = undefined;
                try stdout.writeAll("please write student name to search for\n");
                if (sanitizeLine(stdin, &buffer)) |line| {
                    @memcpy(name_buffer[0..line.len], line);
                    name_buffer[line.len] = 0;
                    name = name_buffer[0..line.len];
                } else |err| {
                    std.debug.print("got error(or null) while expecting full name:  {}\n", .{err});
                    return error.NoName;
                }

                var accumulated_minutes: u32 = 0;
                var lesson_count: u32 = 0;
                var ignore_error: bool = true;
                var i: u32 = 1;
                while (sanitizeLine(input_stream, &buffer)) |line| : (i += 1) {
                    if (line.len == 0) continue;
                    var lesson = parseLine(line) catch |err| {
                        if (!ignore_error) {
                            std.debug.print("{d:2}: error {} |{s}|\n", .{ i, err, line });
                        }
                        continue;
                    };
                    ignore_error = false;

                    if (contains(lesson.name, name)) {
                        lesson_count += 1;
                        for (&lesson.timestamps) |*timestamp| {
                            timestamp.* = timestamp.hourMinuteStamp();
                        }
                        const time_diff = TimeStamp.diff(lesson.timestamps[1], lesson.timestamps[0]);
                        const lesson_minutes = time_diff.convertMinutes();
                        accumulated_minutes += lesson_minutes;

                        try stdout.print("{d}) {d:02}:{d:02} ({d:3}m) | line: {s}\n", .{
                            i,
                            time_diff.hour,
                            time_diff.minute,
                            lesson_minutes,
                            line,
                        });
                    }
                } else |err| {
                    if (err != error.GotNull) {
                        std.debug.print("Got error while reading to query {}\n", .{err});
                    }
                }
                try stdout.print("Total Minutes {d}, Lessons: {d}\n", .{ accumulated_minutes, lesson_count });
            } else {
                std.debug.print("File name is required when doing query\n", .{});
            }
        },
        .parse => {
            var hours_file: ?std.fs.File = null;
            defer if (hours_file != null) hours_file.?.close();
            var hours: ?[]const u8 = null;
            defer if (hours != null) allocator.free(hours.?);

            const input_stream: std.io.AnyReader = rdr: {
                if (hours_filename) |hours_file_v| {
                    hours_file = try std.fs.cwd().openFile(hours_file_v, .{ .mode = .read_only });

                    const hours_reader = hours_file.?.reader();
                    hours = try hours_reader.readAllAlloc(allocator, std.math.maxInt(u32));
                    if (hours.?.len == 0) break :rdr stdin.any();

                    // NOTE(Salim): Shitty performance, shitty logic.
                    const new_month_line = "تسجيل شهر";
                    var line_it = std.mem.splitBackwardsAny(u8, hours.?, "\r\n");
                    var month_index: [2]?usize = .{ null, null };
                    var last_line_index: usize = undefined;
                    var curr_line_index: usize = hours.?.len;
                    while (line_it.next()) |line| {
                        last_line_index = curr_line_index;
                        curr_line_index = line_it.index.?;

                        if (startsWith(line, new_month_line)) {
                            month_index[1] = month_index[0];
                            month_index[0] = curr_line_index;

                            try stdout.print("Do you want to parse {s} (Y/n)?\n", .{line});
                            var input_buffer: [10]u8 = undefined;
                            if (sanitizeLine(stdin, &input_buffer)) |input_line| {
                                if (input_line.len == 0 or startsWith(input_line, "y"))
                                    break;
                            } else |_| {}
                        }
                    }
                    var fbs = std.io.fixedBufferStream(hours.?[last_line_index .. month_index[1] orelse hours.?.len]);

                    break :rdr fbs.reader().any();
                } else {
                    break :rdr stdin.any();
                }
            };

            var accumulated_minutes: u32 = 0;

            var line_buffer: [2 * 1024]u8 = undefined;
            var ignore_error: bool = false;
            var i: u32 = 1;
            while (sanitizeLine(input_stream, &line_buffer)) |line| : (i += 1) {
                if (line.len == 0) continue;
                var lesson = parseLine(line) catch |err| {
                    if (!ignore_error) {
                        std.debug.print("{d:2}: error {} |{s}|\n", .{ i, err, line });
                    }
                    continue;
                };
                ignore_error = false; // start handling errors after first successfull parse

                for (&lesson.timestamps) |*timestamp| {
                    timestamp.* = timestamp.hourMinuteStamp();
                }
                const time_diff = TimeStamp.diff(lesson.timestamps[1], lesson.timestamps[0]);

                var buf1_format: [2 * 3 + 2]u8 = undefined;
                const timestamp1_format = std.fmt.bufPrint(
                    &buf1_format,
                    "{d:02}:{d:02}",
                    .{ lesson.timestamps[0].hour, lesson.timestamps[0].minute },
                ) catch "--:--";
                var buf2_format: [2 * 3 + 2]u8 = undefined;
                const timestamp2_format = std.fmt.bufPrint(
                    &buf2_format,
                    "{d:02}:{d:02}",
                    .{ lesson.timestamps[1].hour, lesson.timestamps[1].minute },
                ) catch "--:--";

                const lesson_minutes = time_diff.convertMinutes();
                accumulated_minutes += lesson_minutes;

                try stdout.print("{d}) {d:02}:{d:02} ({d:3}m) | name: {s}, interval {s} -> {s}\n", .{
                    i,

                    time_diff.hour,
                    time_diff.minute,
                    time_diff.convertMinutes(),

                    lesson.name,
                    timestamp1_format,
                    timestamp2_format,
                });
            } else |err| {
                if (err != error.GotNull) {
                    std.debug.print("Got error while reading to parse {}\n", .{err});
                }
            }
            try stdout.print("Total Minutes {d}\n", .{accumulated_minutes});
        },
    }
}
const Operation = enum {
    parse,
    query,
    insert,
};
const Lesson = struct {
    name: []const u8, // name of student
    timestamps: [2]TimeStamp,
};

// This procedure is complicted but oh well
pub fn stampLastFile(allocator: Allocator, begtime: []const u8, fintime: []const u8) !void {
    const stamp_bin_name = "pdf_title";
    const text = try std.fmt.allocPrintZ(allocator, "{s} -> {s}", .{ begtime, fintime });

    const home_path = try std.process.getEnvVarOwned(allocator, "HOME");
    const directory_pdf = "/Downloads/Tmp";
    const directory_path = try std.mem.concatWithSentinel(allocator, u8, &.{ home_path, directory_pdf }, 0);

    const sorted_files_marathon = try std.process.Child.run(.{ .allocator = allocator, .argv = &.{ "ls", "-c", directory_path } });
    var file_names_it = std.mem.splitScalar(u8, sorted_files_marathon.stdout, '\n');
    const last_file = pfile: {
        while (file_names_it.next()) |fname| {
            if (endsWith(fname, ".pdf") and !startsWith(fname, "stamped.")) {
                break :pfile fname;
            }
        }
        return error.NoPDFILE;
    };

    const stamp_result = try std.process.Child.run(.{ .allocator = allocator, .cwd = directory_path, .argv = &.{ stamp_bin_name, last_file, text } });
    switch (stamp_result.term) {
        .Exited => |status| {
            if (status != 0) {
                std.debug.print("exit status {d}\n", .{status});
                std.debug.print("STDOUT\n{s}", .{stamp_result.stdout});
                std.debug.print("STDERR\n{s}", .{stamp_result.stderr});
                return error.NoZero;
            }
        },
        else => |v| {
            std.debug.print("got stamp result {s}\n", .{@tagName(v)});
            return error.NoExit;
        },
    }
    if (false) {
        const dir = try std.fs.openDirAbsolute(directory_path, .{ .iterate = true });
        defer dir.close();
        var it = dir.iterator();

        while (it.next()) |entry_maybe| {
            if (entry_maybe) |entry| {
                if (entry.kind == .file) {
                    const stats = dir.statFile(entry.name) catch continue;
                    _ = stats;
                }
            }
        } else |err| {
            std.debug.print("got error while iterating: {}\n", .{err});
        }
    }
}

pub fn parseLine(line: []const u8) !Lesson {
    const sep_index = std.mem.indexOf(u8, line, ":") orelse return error.NoColon;
    const first_part = line[0..sep_index];
    const name = std.mem.trimRight(u8, first_part, " ");

    const time_interval = line[sep_index + ":".len ..];
    const first_stamp, const second_stamp = stamps: {
        if (std.mem.indexOf(u8, time_interval, "->")) |stamp_sep_index| {
            const first_stamp = time_interval[0..stamp_sep_index];
            const second_stamp = time_interval[stamp_sep_index + "->".len ..];
            break :stamps .{ first_stamp, second_stamp };
        } else {
            return error.NoArrow;
        }
    };
    var stamps: [2]TimeStamp = undefined;
    for (&stamps, [_][]const u8{ first_stamp, second_stamp }, 1..3) |*s, text, i| {
        var it = TimeStampIterator.init(text);
        const stamp = readTimeStamp(&it) catch |err| {
            std.debug.print("the error is {}\n", .{err});
            if (i == 1) {
                return error.InvalidFirstTimeStamp;
            } else if (i == 2) {
                return error.InvalidSecondTimeStamp;
            } else unreachable;
        };
        s.* = stamp;
    }

    return .{
        .name = name,
        .timestamps = stamps,
    };
}

const ReadError = error{ NoTerminalSpace, NoDigits, InvalidTime, NoTimeStamp, InvalidCharacter };

pub fn readTimeStamp(it: *TimeStampIterator) ReadError!TimeStamp {
    var times: [3]u8 = undefined;
    // skip non digits
    while (it.peek()) |token| {
        assert(token.len != 0);
        if (std.ascii.isDigit(token[0]))
            break;
        it.advance(token.len);
    }
    var parsed: u8 = 0;
    while (parsed < 3) {
        const digits = it.next() orelse return ReadError.NoDigits;
        const value = try readNumber(digits);
        if (parsed != 0) {}
        times[parsed] = value;
        parsed += 1;
        if (it.peek()) |seperator| {
            assert(seperator.len != 0);
            if (seperator[0] == ' ') {
                break;
            }
            if (std.mem.eql(u8, seperator, ":")) {
                it.advance(seperator.len);
                continue;
            }
            return ReadError.NoTerminalSpace;
        } else {
            break;
        }
    }
    const output: TimeStamp = switch (parsed) {
        0 => return ReadError.NoTimeStamp,
        1 => return ReadError.InvalidTime,
        2 => tim: {
            const minute = times[0];
            const second = times[1];
            if (minute >= 60 or second >= 60) {
                return ReadError.InvalidTime;
            }
            break :tim .{
                .hour = 0,
                .minute = minute,
                .second = second,
            };
        },
        3 => tim: {
            const hour = times[0];
            const minute = times[1];
            const second = times[2];
            if (minute >= 60 or second >= 60) {
                return ReadError.InvalidTime;
            }
            break :tim .{
                .hour = hour,
                .minute = minute,
                .second = second,
            };
        },
        else => unreachable,
    };
    return output;
}
pub fn readNumber(digits: []const u8) ReadError!u8 {
    var num: u8 = 0;
    for (digits) |d| {
        const v: u8 = switch (d) {
            '0'...'9' => d - '0',
            else => return ReadError.InvalidCharacter,
        };
        num = 10 * num + v;
    }
    return num;
}
const TimeStampIterator = struct {
    buffer: []const u8,
    index: usize,

    pub fn init(buffer: []const u8) TimeStampIterator {
        return .{
            .buffer = buffer,
            .index = 0,
        };
    }
    pub fn peek(self: *TimeStampIterator) ?[]const u8 {
        if (self.index < self.buffer.len) {
            switch (self.buffer[self.index]) {
                '0'...'9' => {
                    var i: usize = self.index + 1;
                    while (i < self.buffer.len) : (i += 1) {
                        switch (self.buffer[i]) {
                            '0'...'9' => {},
                            else => break,
                        }
                    }
                    return self.buffer[self.index..i];
                },
                ':', '\n' => {
                    return self.buffer[self.index .. self.index + 1];
                },
                ' ' => {
                    var i: usize = self.index + 1;
                    while (i < self.buffer.len and self.buffer[i] == ' ') : (i += 1) {}
                    return self.buffer[self.index..i];
                },
                else => {
                    var i: usize = self.index + 1;
                    while (i < self.buffer.len and
                        switch (self.buffer[i]) {
                            '0'...'9' => false,
                            ':', '\n' => false,
                            ' ' => false,
                            else => true,
                        }) : (i += 1)
                    {}
                    return self.buffer[self.index..i];
                },
            }
        }
        return null;
    }
    // used to replace doing .next() after doing .peek on the same token
    // like first doing self.peek() and if a condition is met do self.next()
    pub fn advance(self: *TimeStampIterator, adv: usize) void {
        self.index += adv;
    }
    pub fn next(self: *TimeStampIterator) ?[]const u8 {
        const result = self.peek() orelse return null;
        self.index += result.len;
        return result;
    }
    pub fn reset(self: *TimeStampIterator) void {
        self.index = 0;
    }
    pub fn rest(self: TimeStampIterator) []const u8 {
        return self.buffer[self.index..];
    }
};

const TimeStamp = struct {
    hour: u8,
    minute: u8,
    second: u8,

    fn convertSeconds(self: TimeStamp) u32 {
        const hour = self.hour;
        const minute = hour * 60 + self.minute;
        const second = minute * 60 + self.second;
        return second;
    }
    fn convertMinutes(self: TimeStamp) u32 {
        assert(self.second == 0);
        return self.hour * 60 + self.minute;
    }
    fn hourMinuteStamp(self: TimeStamp) TimeStamp {
        assert(self.hour == 0);
        return .{
            .hour = self.minute,
            .minute = self.second,
            .second = 0,
        };
    }
    fn diff(self: TimeStamp, other: TimeStamp) TimeStamp {
        var hours: i32 = @as(i32, @intCast(self.hour)) - @as(i32, @intCast(other.hour));
        var minutes: i32 = @as(i32, @intCast(self.minute)) - @as(i32, @intCast(other.minute));
        var seconds: i32 = @as(i32, @intCast(self.second)) - @as(i32, @intCast(other.second));
        assert(seconds < 60);
        assert(seconds > -60);
        assert(minutes < 60);
        assert(minutes > -60);
        if (seconds < 0) {
            seconds += 60;
            minutes -= 1;
        }
        if (minutes < 0) {
            minutes += 60;
            hours -= 1;
        }
        assert(seconds >= 0);
        assert(minutes >= 0);
        if (hours < 0) {
            @panic("I only implement it with self being the bigger timestamp");
        }
        return .{
            .hour = @as(u8, @intCast(hours)),
            .minute = @as(u8, @intCast(minutes)),
            .second = @as(u8, @intCast(seconds)),
        };
    }
};

pub fn startsWith(a: []const u8, b: []const u8) bool {
    return std.mem.startsWith(u8, a, b);
}
pub fn endsWith(a: []const u8, b: []const u8) bool {
    return std.mem.endsWith(u8, a, b);
}
pub fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
pub fn contains(a: []const u8, b: []const u8) bool {
    return std.mem.indexOf(u8, a, b) != null;
}
pub fn nextLine(reader: anytype, buffer: []u8) !?[]const u8 {
    const line = (try reader.readUntilDelimiterOrEof(
        buffer,
        '\n',
    )) orelse return null;
    return std.mem.trimRight(u8, line, "\r");
}

pub fn sanitizeLine(reader: anytype, buffer: []u8) ![]const u8 {
    if (nextLine(reader, buffer)) |line_m| {
        if (line_m) |line| {
            return line;
        } else {
            return error.GotNull;
        }
    } else |err| {
        return err;
    }
}

const PromptError = error{FileEmpty};
pub fn promptMonthsBackward(stdout: anytype, stdin: anytype, allocator: Allocator, hours_file: std.fs.File, hours_buffer: *?[]const u8) !std.io.AnyReader {
    const hours_reader = hours_file.reader();
    hours_buffer.* = null;
    hours_buffer.* = try hours_reader.readAllAlloc(allocator, std.math.maxInt(u32));
    if (hours_buffer.*.?.len == 0)
        return PromptError.FileEmpty;

    // NOTE(Salim): Shitty performance, shitty logic.
    const new_month_line = "تسجيل شهر";
    var line_it = std.mem.splitBackwardsAny(u8, hours_buffer.*.?, "\r\n");
    var month_index: [2]usize = .{ hours_buffer.*.?.len, hours_buffer.*.?.len }; // index zero holds latest index and index 1 hold the previous value
    var last_line_index: usize = undefined;
    var curr_line_index: usize = hours_buffer.*.?.len;
    while (line_it.next()) |line| {
        last_line_index = curr_line_index;
        curr_line_index = line_it.index.?;

        if (startsWith(line, new_month_line)) {
            month_index[1] = month_index[0];
            month_index[0] = curr_line_index;

            try stdout.print("Do you want to query {s} (Y/n)?\n", .{line});
            var input_buffer: [10]u8 = undefined;
            if (sanitizeLine(stdin, &input_buffer)) |input_line| {
                if (input_line.len == 0 or startsWith(input_line, "y"))
                    break;
            } else |_| {}
        }
    }

    var fbs = std.io.fixedBufferStream(hours_buffer.*.?[last_line_index..month_index[1]]);
    return fbs.reader().any();
}
