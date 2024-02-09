const std = @import("std");
const args_parser = @import("args");

const CliOptions = struct {
    help: bool = false,
    output: ?[]const u8 = null,

    @"no-grid": bool = false,
    @"no-time": bool = false,

    pub const shorthands = .{
        .h = "help",
        .o = "output",
        .G = "no-grid",
        .T = "no-time",
    };

    pub const meta = .{
        .usage_summary = "[-h] [-o <file>] [<input>]",
        .full_text =
        \\Generates nice Unicode art based waveform graphics based on a basic text file.
        \\If <input> is given, the data is read from the file at <input>, otherwise, stdin is consumed.
        ,
        .option_docs = .{
            .help = "Prints this text.",
            .output = "Redirects the output to the provided file. If not given, the generated text is printed to stdout.",
            .@"no-grid" = "Disables generation of the vertical grid axis.",
            .@"no-time" = "Disables generation of the time step numbers.",
        },
    };
};

fn printHelp(writer: anytype, exe_name: ?[]const u8) !void {
    try args_parser.printHelp(CliOptions, exe_name orelse "waveform", writer);

    try writer.writeAll(
        \\
        \\The format for these text files is a line based ASCII format.
        \\
        \\Each line starts with the name of a signal, separated by a pipe (`|`). After the pipe, a
        \\sequence of signal edges is listed. Edges can have the following types:
        \\  'L': edge to low
        \\  'H': edge to high
        \\  'Z': edge to high impedance
        \\  'B': edge to low or high (can be both)
        \\  '-': no change in the signal
        \\
        \\Simple example:
        \\  CLK  | LLHLHLHLHLHLHLHLHLHLLLL
        \\  /CE  | HLLLLLLLLLLLLLLLLLHHHHH
        \\  MOSI | ZZB-B-B-B-B-B-B-B-ZZZZZ
        \\  MISO | ZZZB-B-B-B-B-B-B-B-ZZZZ
    );
}

pub fn main() !u8 {
    const stdout = std.io.getStdOut();
    const stderr = std.io.getStdErr();

    var gpa_alloc = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_alloc.deinit();

    const allocator = gpa_alloc.allocator();

    var cli = args_parser.parseForCurrentProcess(CliOptions, allocator, .print) catch return 1;
    defer cli.deinit();

    if (cli.options.help) {
        try printHelp(stdout.writer(), cli.executable_name);
        return 0;
    }
    if (cli.positionals.len > 1) {
        try printHelp(stderr.writer(), cli.executable_name);
        return 1;
    }

    var input_file = if (cli.positionals.len > 0)
        try std.fs.cwd().openFile(cli.positionals[0], .{})
    else
        std.io.getStdIn();
    defer input_file.close();

    const input_buffer = try input_file.readToEndAlloc(allocator, 1 << 20);
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
        try stderr.writeAll("empty file is not allowed!\n");
        return 1;
    }

    const width = sequences.items[0].sequence.len;
    for (sequences.items) |seq| {
        std.debug.assert(width == seq.sequence.len);
    }

    var output_file = if (cli.options.output) |output_path|
        try std.fs.cwd().createFile(output_path, .{})
    else
        stdout;
    defer output_file.close();

    try render(sequences.items, output_file.writer(), .{
        .grid = !cli.options.@"no-grid",
        .time = !cli.options.@"no-time",
    });

    return 0;
}

const RenderOptions = struct {
    grid: bool,
    time: bool,
};

fn render(src_items: []const TimeSequence, raw_writer: std.fs.File.Writer, options: RenderOptions) !void {
    var buffered_writer = std.io.bufferedWriter(raw_writer);
    const writer = buffered_writer.writer();

    const BufferedWriter = @TypeOf(writer);

    const Renderer = struct {
        items: []const TimeSequence,
        writer: BufferedWriter,
        max_title_width: usize,
        spacing_char: []const u8,

        fn flushLine(r: @This()) !void {
            try r.writer.writeByteNTimes(' ', r.max_title_width + 3);
            for (r.items[0].sequence, 0..) |_, i| {
                if (i > 0)
                    try r.writer.writeAll("  ");
                try r.writer.writeAll(r.spacing_char);
            }
            try r.writer.writeAll("\n");
        }

        pub fn writeSeries(r: @This(), events: []const Edge, lookup_table: [5][5][]const u8, row: u2) !void {
            var previous_state: Edge = .high_impedance;
            for (events, 0..) |event, i| {
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

                var out = lookup_table[@intFromEnum(event)][@intFromEnum(previous_state)];

                if (std.mem.eql(u8, out, SPC)) {
                    out = r.spacing_char;
                }

                try r.writer.writeAll(out);
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

        .spacing_char = if (options.grid)
            "┆"
        else
            SPC,
    };

    var sequence_length = src_items[0].sequence.len;

    if (options.time) {

        // write 10s digit clock cycles
        var digits = std.math.log10(sequence_length - 1);
        while (digits > 0) {
            const pot = try std.math.powi(usize, 10, digits);
            try writer.writeByteNTimes(' ', max_title_width + 3);
            for (src_items[0].sequence, 0..) |_, i| {
                if (i > 0)
                    try writer.writeAll("  ");
                if (i % 10 == 0 and i / pot > 0) {
                    try writer.print("{d}", .{(i / pot) % 10});
                } else {
                    try writer.writeAll(SPC);
                }
            }
            try writer.writeAll("\n");
            digits -= 1;
        }

        // write 1s digit clock cycles
        {
            try writer.writeByteNTimes(' ', max_title_width + 3);
            for (src_items[0].sequence, 0..) |_, i| {
                if (i > 0)
                    try writer.writeAll("  ");
                try writer.print("{d}", .{i % 10});
            }
            try writer.writeAll("\n");
        }
    }
    try renderer.flushLine();

    for (src_items) |time_series| {

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
        try renderer.flushLine();
    }

    try buffered_writer.flush();
}

const SPC = " ";

//                            ↓-to
//                               ↓-from
const upper_row_transitions: [5][5][]const u8 = .{
    // from:
    //  -    h    l    z    b     to:
    .{ "X", "━", SPC, SPC, "━" }, // -
    .{ "X", "━", "┏", "┏", "┳" }, // h
    .{ "X", "┓", SPC, SPC, "┓" }, // l
    .{ "X", "┓", SPC, SPC, "┓" }, // z
    .{ "X", "┳", "┏", "┏", "┳" }, // b
};

//                             ↓-to
//                                ↓-from
const middle_row_transitions: [5][5][]const u8 = .{
    // from:
    //  -    h    l    z    b     to:
    .{ "X", SPC, SPC, "━", SPC }, // -
    .{ "X", SPC, "┃", "┛", "┃" }, // h
    .{ "X", "┃", SPC, "┓", "┃" }, // l
    .{ "X", "┗", "┏", "━", "┣" }, // z
    .{ "X", "┃", "┃", "┫", "┃" }, // b
};

//                             ↓-to
//                                ↓-from
const bottom_row_transitions: [5][5][]const u8 = .{
    // from:
    //  -    h    l    z    b     to:
    .{ "X", SPC, "━", SPC, "━" }, // -
    .{ "X", SPC, "┛", SPC, "┛" }, // h
    .{ "X", "┗", "━", "┗", "┻" }, // l
    .{ "X", SPC, "┛", SPC, "┛" }, // z
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
