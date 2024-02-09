const std = @import("std");
const args_parser = @import("args");

const CliOptions = struct {
    help: bool = false,
    output: ?[]const u8 = null,

    @"no-grid": bool = false,
    @"no-time": bool = false,
    ascii: bool = false,

    pub const shorthands = .{
        .h = "help",
        .o = "output",
        .G = "no-grid",
        .T = "no-time",
        .A = "ascii",
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
            .ascii = "Outputs ASCII graphics instead of UTF-8.",
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
        .ascii = cli.options.ascii,
    });

    return 0;
}

pub const RenderOptions = struct {
    grid: bool,
    time: bool,
    ascii: bool,
};

pub fn render(src_items: []const TimeSequence, raw_writer: std.fs.File.Writer, options: RenderOptions) !void {
    var buffered_writer = std.io.bufferedWriter(raw_writer);
    const writer = buffered_writer.writer();

    const BufferedWriter = @TypeOf(writer);

    const Renderer = struct {
        items: []const TimeSequence,
        writer: BufferedWriter,
        max_title_width: usize,
        transitions: TransitionSet,

        fn flushLine(r: @This()) !void {
            try r.writer.writeByteNTimes(' ', r.max_title_width + 3);
            for (r.items[0].sequence, 0..) |_, i| {
                if (i > 0)
                    try r.writer.writeAll("  ");
                try r.writer.writeAll(r.transitions.grid_column);
            }
            try r.writer.writeAll("\n");
        }

        pub fn writeSeries(r: @This(), events: []const Edge, lut_id: TransitionLUT, row: u2) !void {
            const lookup_table: [5][5][]const u8 = switch (lut_id) {
                inline else => |tag| @field(r.transitions, @tagName(tag)),
            };

            const hspc = "  ";
            const hout = r.transitions.phase_out;
            const hpad = r.transitions.keep_level;

            var previous_state: Edge = .high_impedance;
            for (events, 0..) |event, i| {
                if (i == 0 and event != .keep)
                    previous_state = event;

                if (i == 0) {
                    try r.writer.writeAll(switch (previous_state) {
                        .keep => unreachable,
                        .high => if (row == 0) hout else hspc,
                        .high_impedance => if (row == 1) hout else hspc,
                        .both => if (row != 1) hout else hspc,
                        .low => if (row == 2) hout else hspc,
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
                    try r.writer.writeAll(if (level) hpad else hspc);
                }

                var out = lookup_table[@intFromEnum(event)][@intFromEnum(previous_state)];

                if (std.mem.eql(u8, out, SPC)) {
                    out = r.transitions.grid_column;
                }

                try r.writer.writeAll(out);
            }
            try r.writer.writeAll(switch (previous_state) {
                .keep => unreachable,
                .high => if (row == 0) hout else hspc,
                .high_impedance => if (row == 1) hout else hspc,
                .both => if (row != 1) hout else hspc,
                .low => if (row == 2) hout else hspc,
            });
        }
    };

    var max_title_width: usize = 0;
    for (src_items) |seq| {
        if (seq.title.len > max_title_width)
            max_title_width = seq.title.len;
    }

    var transitions = if (options.ascii)
        ascii_transitions
    else
        unicode_transitions;

    if (!options.grid)
        transitions.grid_column = " ";

    const renderer = Renderer{
        .items = src_items,
        .writer = writer,
        .max_title_width = max_title_width,

        .transitions = transitions,
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
            try renderer.writeSeries(time_series.sequence, .upper_row, 0);
            try writer.writeAll("\n");
        }

        // center row
        {
            try writer.print("{[title]s: >[padding]} ", .{
                .title = time_series.title,
                .padding = max_title_width,
            });
            try renderer.writeSeries(time_series.sequence, .middle_row, 1);
            try writer.writeAll("\n");
        }

        // bottom row
        {
            try writer.writeByteNTimes(' ', max_title_width + 1);
            try renderer.writeSeries(time_series.sequence, .bottom_row, 2);
            try writer.writeAll("\n");
        }
        try renderer.flushLine();
    }

    try buffered_writer.flush();
}

const SPC = " ";

pub const TransitionLUT = enum {
    upper_row,
    middle_row,
    bottom_row,
};

const TransitionSet = struct {
    phase_out: []const u8,
    keep_level: []const u8,
    grid_column: []const u8,

    upper_row: [5][5][]const u8,
    middle_row: [5][5][]const u8,
    bottom_row: [5][5][]const u8,
};

const unicode_transitions = TransitionSet{
    .phase_out = "╍╍",
    .keep_level = "━━",
    .grid_column = "┆",

    //                            ↓-to
    //                               ↓-from
    .upper_row = .{
        // from:
        //  -    h    l    z    b     to:
        .{ "X", "━", SPC, SPC, "━" }, // -
        .{ "X", "━", "┏", "┏", "┳" }, // h
        .{ "X", "┓", SPC, SPC, "┓" }, // l
        .{ "X", "┓", SPC, SPC, "┓" }, // z
        .{ "X", "┳", "┏", "┏", "┳" }, // b
    },

    //                             ↓-to
    //                                ↓-from
    .middle_row = .{
        // from:
        //  -    h    l    z    b     to:
        .{ "X", SPC, SPC, "━", SPC }, // -
        .{ "X", SPC, "┃", "┛", "┃" }, // h
        .{ "X", "┃", SPC, "┓", "┃" }, // l
        .{ "X", "┗", "┏", "━", "┣" }, // z
        .{ "X", "┃", "┃", "┫", "┃" }, // b
    },

    //                             ↓-to
    //                                ↓-from
    .bottom_row = .{
        // from:
        //  -    h    l    z    b     to:
        .{ "X", SPC, "━", SPC, "━" }, // -
        .{ "X", SPC, "┛", SPC, "┛" }, // h
        .{ "X", "┗", "━", "┗", "┻" }, // l
        .{ "X", SPC, "┛", SPC, "┛" }, // z
        .{ "X", "┗", "┻", "┗", "┻" }, // b
    },
};

const ascii_transitions = TransitionSet{
    .phase_out = "--",
    .keep_level = "--",
    .grid_column = "'", // TODO: what here?

    //                            ↓-to
    //                               ↓-from
    .upper_row = .{
        // from:
        //  -    h    l    z    b     to:
        .{ "X", "-", SPC, SPC, "-" }, // -
        .{ "X", "-", ".", ".", "+" }, // h
        .{ "X", ".", SPC, SPC, "." }, // l
        .{ "X", ".", SPC, SPC, "." }, // z
        .{ "X", "+", ".", ".", "+" }, // b
    },

    //                             ↓-to
    //                                ↓-from
    .middle_row = .{
        // from:
        //  -    h    l    z    b     to:
        .{ "X", SPC, SPC, "-", SPC }, // -
        .{ "X", SPC, "|", "'", "|" }, // h
        .{ "X", "|", SPC, ".", "|" }, // l
        .{ "X", "'", ".", "-", "|" }, // z
        .{ "X", "|", "|", "|", "|" }, // b
    },

    //                             ↓-to
    //                                ↓-from
    .bottom_row = .{
        // from:
        //  -    h    l    z    b     to:
        .{ "X", SPC, "-", SPC, "-" }, // -
        .{ "X", SPC, "'", SPC, "'" }, // h
        .{ "X", "'", "-", "'", "+" }, // l
        .{ "X", SPC, "'", SPC, "'" }, // z
        .{ "X", "'", "+", "'", "+" }, // b
    },
};

pub const TimeSequence = struct {
    title: []u8,
    sequence: []Edge,
};

pub const Edge = enum(u8) {
    keep = 0,
    high = 1,
    low = 2,
    high_impedance = 3,
    both = 4,
};
