const std = @import("std");
const args_parser = @import("args");

pub fn main() !u8 {
    var gpa_alloc = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_alloc.deinit();

    const allocator = gpa_alloc.allocator();

    var cli = args_parser.parseForCurrentProcess(CliOptions, allocator, .print) catch return 1;
    defer cli.deinit();

    if (cli.positionals.len != 1) {
        @panic("Requires exactly one argument!");
    }

    const input_buffer = blk: {
        var input_file = try std.fs.cwd().openFile(cli.positionals[0], .{});
        defer input_file.close();

        break :blk try input_file.readToEndAlloc(allocator, 1 << 20);
    };
    defer allocator.free(input_buffer);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var sequences = std.ArrayList(TimeSequence).init(allocator);
    defer sequences.deinit();

    {
        var lines = std.mem.tokenize(u8, input_buffer, "\r\n");
        while (lines.next()) |line| {
            if (line.len == 0)
                continue;
            const whitespace = " \t";

            var splitter = std.mem.split(u8, line, "|");

            const signal_name_raw = splitter.next().?; // always non-null
            const signal_spec_raw = splitter.next() orelse {
                std.debug.print("bad line: {s}", .{line});
                @panic("line is missing a splitter!");
            };
            if (splitter.next()) |_| {
                std.debug.print("bad line: {s}", .{line});
                @panic("line is having too much splitters");
            }

            const signal_name = std.mem.trim(u8, signal_name_raw, whitespace);
            const signal_spec = std.mem.trim(u8, signal_spec_raw, whitespace);

            const sequence = try sequences.addOne();
            sequence.* = TimeSequence{
                .title = try arena.allocator().dupe(u8, signal_name),
                .sequence = undefined,
            };

            var items = std.ArrayList(Edge).init(arena.allocator());
            defer items.deinit();

            try items.ensureTotalCapacity(signal_spec.len);

            for (signal_spec) |char| {
                const event: Edge = switch (char) {
                    '-', ' ' => .keep,
                    'H', 'h', '1' => .high,
                    'L', 'l', '0' => .low,
                    'Z', 'z' => .high_impedance,
                    'B', 'b' => .both,
                    else => @panic("illegal character"),
                };

                try items.append(event);
            }

            sequence.sequence = try items.toOwnedSlice();
        }
    }

    if (sequences.items.len == 0) {
        @panic("empty file!");
    }

    const width = sequences.items[0].sequence.len;
    for (sequences.items) |seq| {
        std.debug.assert(width == seq.sequence.len);
    }

    try render(
        sequences.items,
        std.io.getStdOut().writer(),
    );

    return 0;
}

fn render(src_items: []const TimeSequence, raw_writer: std.fs.File.Writer) !void {
    var buffered_writer = std.io.bufferedWriter(raw_writer);
    const writer = buffered_writer.writer();

    const BufferedWriter = @TypeOf(writer);

    const Renderer = struct {
        items: []const TimeSequence,
        writer: BufferedWriter,
        max_title_width: usize,

        fn flushLine(r: @This()) !void {
            try r.writer.writeByteNTimes(' ', r.max_title_width + 3);
            for (r.items[0].sequence) |_, i| {
                if (i > 0)
                    try r.writer.writeAll("  ");
                try r.writer.writeAll("┆");
            }
            try r.writer.writeAll("\n");
        }

        pub fn writeSeries(r: @This(), events: []const Edge, lookup_table: [5][5][]const u8, row: u2) !void {
            var previous_state: Edge = .high_impedance;
            for (events) |event, i| {
                if (i == 0 and event != .keep)
                    previous_state = event;

                if (i == 0) {
                    try r.writer.writeAll(switch (previous_state) {
                        .keep => unreachable,
                        .high => if (row == 0) "╍╍" else "  ",
                        .high_impedance => if (row == 1) "╍╍" else "  ",
                        .both => if (row != 1) "╍╍" else "  ",
                        .low => if (row == 2) "╍╍" else "  ",
                    });
                }

                defer if (event != .keep) {
                    previous_state = event;
                };

                if (i > 0) {
                    const level = switch (previous_state) {
                        .keep => unreachable,
                        .both => (row != 1),
                        .high => (row == 0),
                        .high_impedance => (row == 1),
                        .low => (row == 2),
                    };
                    try r.writer.writeAll(if (level) "━━" else "  ");
                }

                try r.writer.writeAll(lookup_table[@enumToInt(event)][@enumToInt(previous_state)]);
            }
            try r.writer.writeAll(switch (previous_state) {
                .keep => unreachable,
                .high => if (row == 0) "╍╍" else "  ",
                .high_impedance => if (row == 1) "╍╍" else "  ",
                .both => if (row != 1) "╍╍" else "  ",
                .low => if (row == 2) "╍╍" else "  ",
            });
        }
    };

    var max_title_width: usize = 0;
    for (src_items) |seq| {
        if (seq.title.len > max_title_width)
            max_title_width = seq.title.len;
    }

    const renderer = Renderer{
        .items = src_items,
        .writer = writer,
        .max_title_width = max_title_width,
    };

    // const sequence_length = items[0].sequence.len;

    // write 10s digit clock cycles
    if (src_items[0].sequence.len > 10) {
        try writer.writeByteNTimes(' ', max_title_width + 3);
        for (src_items[0].sequence) |_, i| {
            if (i > 0)
                try writer.writeAll("  ");
            if (i % 10 == 0 and i > 0) {
                try writer.print("{d}", .{(i / 10) % 10});
            } else {
                try writer.writeAll(".");
            }
        }
        try writer.writeAll("\n");
    }

    // write 1s digit clock cycles
    {
        try writer.writeByteNTimes(' ', max_title_width + 3);
        for (src_items[0].sequence) |_, i| {
            if (i > 0)
                try writer.writeAll("  ");
            try writer.print("{d}", .{i % 10});
        }
        try writer.writeAll("\n");
    }

    for (src_items) |time_series| {
        try renderer.flushLine();

        // top row
        {
            try writer.writeByteNTimes(' ', max_title_width + 1);
            try renderer.writeSeries(time_series.sequence, upper_row_transitions, 0);
            try writer.writeAll("\n");
        }

        // center row
        {
            try writer.print("{[title]s: >[padding]} ", .{
                .title = time_series.title,
                .padding = max_title_width,
            });
            try renderer.writeSeries(time_series.sequence, middle_row_transitions, 1);
            try writer.writeAll("\n");
        }

        // bottom row
        {
            try writer.writeByteNTimes(' ', max_title_width + 1);
            try renderer.writeSeries(time_series.sequence, bottom_row_transitions, 2);
            try writer.writeAll("\n");
        }
    }
    try renderer.flushLine();

    try buffered_writer.flush();
}

//                            ↓-to
//                               ↓-from
const upper_row_transitions: [5][5][]const u8 = .{
    // from:
    //  -    h    l    z    b     to:
    .{ "X", "━", "┆", "┆", "━" }, // -
    .{ "X", "━", "┏", "┏", "┳" }, // h
    .{ "X", "┓", "┆", "┆", "┓" }, // l
    .{ "X", "┓", "┆", "┆", "┓" }, // z
    .{ "X", "┳", "┏", "┏", "┳" }, // b
};

//                             ↓-to
//                                ↓-from
const middle_row_transitions: [5][5][]const u8 = .{
    // from:
    //  -    h    l    z    b     to:
    .{ "X", "┆", "┆", "━", " " }, // -
    .{ "X", "┆", "┃", "┛", "┃" }, // h
    .{ "X", "┃", "┆", "┓", "┃" }, // l
    .{ "X", "┗", "┏", "━", "┣" }, // z
    .{ "X", "┃", "┃", "┫", "┃" }, // b
};

//                             ↓-to
//                                ↓-from
const bottom_row_transitions: [5][5][]const u8 = .{
    // from:
    //  -    h    l    z    b     to:
    .{ "X", "┆", "━", "┆", "━" }, // -
    .{ "X", "┆", "┛", "┆", "┛" }, // h
    .{ "X", "┗", "━", "┗", "┻" }, // l
    .{ "X", "┆", "┛", "┆", "┛" }, // z
    .{ "X", "┗", "┻", "┗", "┻" }, // b
};

const TimeSequence = struct {
    title: []u8,
    sequence: []Edge,
};

const Edge = enum(u8) {
    keep = 0,
    high = 1,
    low = 2,
    high_impedance = 3,
    both = 4,
};

const CliOptions = struct {
    help: bool = false,
};
