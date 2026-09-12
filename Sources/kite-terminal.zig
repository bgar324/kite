//! Compiled inside the pinned Ghostty src root through main_c.zig.
//! Uses the existing terminal_options/uucode/SIMD dependencies of that root.
//! No App, renderer, config singleton, or Ghostty global allocator is used.
const std = @import("std");
const Terminal = @import("terminal/Terminal.zig");
const Screen = @import("terminal/Screen.zig");
const Parser = @import("terminal/Parser.zig");
const stream = @import("terminal/stream.zig");
const formatter = @import("terminal/formatter.zig");
const modes = @import("terminal/modes.zig");
const color = @import("terminal/color.zig");
const Cell = @import("terminal/page.zig").Cell;
const Style = @import("terminal/style.zig").Style;
const Page = @import("terminal/page.zig").Page;
const alloc = std.heap.c_allocator;
const max_sequence = 64 * 1024;
const max_snapshot = 16 * 1024 * 1024;
const max_scrollback = 2 * 1024 * 1024;
const Stream = stream.Stream(Handler);

const KiteTerminal = struct {
    terminal: Terminal,
    parser: Stream,
    failed: bool = false,
    executed: bool = false,
    pending: std.ArrayList(u8) = .empty,
    pending_overflow: bool = false,
    osc_storage: [max_sequence]u8 = undefined,
    osc_arena: std.heap.FixedBufferAllocator = undefined,
    printed: bool = false,
    replies: std.ArrayList(u8) = .empty,
    title: [4097:0]u8 = @splat(0),
    cwd: [4097:0]u8 = @splat(0),
    dcs: enum { none, status, capability } = .none,

    fn reply(self: *KiteTerminal, comptime fmt: []const u8, args: anytype) !void {
        var buffer: [8192]u8 = undefined;
        const bytes = std.fmt.bufPrint(&buffer, fmt, args) catch return;
        if (self.replies.items.len + bytes.len > max_sequence) return;
        try self.replies.appendSlice(alloc, bytes);
    }
};

const Handler = struct {
    owner: *KiteTerminal,
    pub fn deinit(_: *Handler) void {}

    // Track only actions the real Ghostty parser actually executes. Their C0
    // bytes must not appear in the unfinished prefix and execute a second time.
    pub fn vtRaw(self: *Handler, action: Parser.Action) !bool {
        if (action == .execute) self.owner.executed = true;
        return false;
    }

    pub fn vt(self: *Handler, comptime action: stream.Action.Tag, value: stream.Action.Value(action)) !void {
        const owner = self.owner;
        const t = &owner.terminal;
        // CSI-param fast paths call vt directly, bypassing vtRaw. Track the
        // executed C0 actions here too, rather than guessing from input bytes.
        switch (action) {
            .enquiry, .bell, .backspace, .horizontal_tab, .linefeed,
            .carriage_return, .invoke_charset,
            => owner.executed = true,
            else => {},
        }
        var ro = t.vtHandler();
        switch (action) {
            .print => {
                owner.printed = true;
                try t.print(value.cp);
            },
            .window_title => { _ = setText(&owner.title, value.title); },
            .dcs_hook => {
                owner.dcs = if (value.final == 'q' and std.mem.eql(u8, value.intermediates, "$"))
                    .status
                else if (value.final == 'q' and std.mem.eql(u8, value.intermediates, "+"))
                    .capability
                else
                    .none;
            },
            .dcs_unhook => {
                // Explicit negative replies avoid a detached client waiting for
                // unsupported DECRQSS/XTGETTCAP data. No capability is invented.
                switch (owner.dcs) {
                    .status => try owner.reply("\x1bP0$r\x1b\\", .{}),
                    .capability => try owner.reply("\x1bP0+r\x1b\\", .{}),
                    .none => {},
                }
                owner.dcs = .none;
            },
            .report_pwd => {
                if (setCwd(owner, value.url)) {
                    t.pwd.clearRetainingCapacity();
                    try t.pwd.appendSlice(alloc, value.url);
                }
            },
            .device_status => switch (value.request) {
                .operating_status => try owner.reply("\x1b[0n", .{}),
                .cursor_position => {
                    const c = &t.screens.active.cursor;
                    const origin = t.modes.get(.origin);
                    try owner.reply("\x1b[{d};{d}R", .{
                        (if (origin) c.y -| t.scrolling_region.top else c.y) + 1,
                        (if (origin) c.x -| t.scrolling_region.left else c.x) + 1,
                    });
                },
                .color_scheme => try owner.reply("\x1b[?997;1n", .{}),
            },
            .device_attributes => switch (value) {
                .primary => try owner.reply("\x1b[?62;22c", .{}),
                .secondary => try owner.reply("\x1b[>1;10;0c", .{}),
                else => {},
            },
            .request_mode => {
                const tag: modes.ModeTag = @bitCast(@intFromEnum(value.mode));
                try owner.reply("\x1b[{s}{d};{d}$y", .{ if (tag.ansi) "" else "?", tag.value, @as(u8, if (t.modes.get(value.mode)) 1 else 2) });
            },
            .request_mode_unknown => try owner.reply("\x1b[{s}{d};0$y", .{ if (value.ansi) "" else "?", value.mode }),
            .kitty_keyboard_query => try owner.reply("\x1b[?{d}u", .{t.screens.active.kitty_keyboard.current().int()}),
            .xtversion => try owner.reply("\x1bP>|Ghostty 1.3.1\x1b\\", .{}),
            .size_report => switch (value) {
                .csi_14_t => try owner.reply("\x1b[4;{d};{d}t", .{ t.height_px, t.width_px }),
                .csi_16_t => try owner.reply("\x1b[6;{d};{d}t", .{ t.height_px / t.rows, t.width_px / t.cols }),
                .csi_18_t => try owner.reply("\x1b[8;{d};{d}t", .{ t.rows, t.cols }),
                .csi_21_t => try owner.reply("\x1b]l{s}\x1b\\", .{std.mem.sliceTo(&owner.title, 0)}),
            },
            .clipboard_contents => {
                if (std.mem.eql(u8, value.data, "?")) try owner.reply("\x1b]52;{c};\x1b\\", .{value.kind});
            },
            .color_operation => {
                try ro.vt(action, value);
                var it = value.requests.constIterator(0);
                while (it.next()) |request| {
                    if (request.* != .query) continue;
                    switch (request.query) {
                        .palette => |index| {
                            const rgb = t.colors.palette.current[index];
                            try owner.reply("\x1b]4;{d};rgb:{x:0>4}/{x:0>4}/{x:0>4}\x1b\\", .{ index, @as(u16, rgb.r) * 257, @as(u16, rgb.g) * 257, @as(u16, rgb.b) * 257 });
                        },
                        .dynamic => |which| {
                            const rgb = switch (which) {
                                .foreground => t.colors.foreground.get() orelse color.RGB{ .r = 0xdd, .g = 0xdd, .b = 0xdd },
                                .background => t.colors.background.get() orelse color.RGB{ .r = 0x1e, .g = 0x1e, .b = 0x1e },
                                .cursor => t.colors.cursor.get() orelse color.RGB{ .r = 0xdd, .g = 0xdd, .b = 0xdd },
                                else => continue,
                            };
                            try owner.reply("\x1b]{d};rgb:{x:0>4}/{x:0>4}/{x:0>4}\x1b\\", .{ @intFromEnum(which), @as(u16, rgb.r) * 257, @as(u16, rgb.g) * 257, @as(u16, rgb.b) * 257 });
                        },
                        .special => {},
                    }
                }
            },
            // Unlike the upstream read-only adapter, don't swallow SGR errors.
            .set_attribute => switch (value) {
                .unknown => {},
                else => try t.setAttribute(value),
            },
            else => try ro.vt(action, value),
        }
    }
};

fn setText(target: *[4097:0]u8, text: []const u8) bool {
    if (text.len > 4096 or !std.unicode.utf8ValidateSlice(text)) return false;
    for (text) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    @memcpy(target[0..text.len], text);
    target[text.len] = 0;
    return true;
}

fn setCwd(owner: *KiteTerminal, url: []const u8) bool {
    if (url.len > 8192 or !std.mem.startsWith(u8, url, "file://")) return false;
    const path_start = std.mem.indexOfScalarPos(u8, url, 7, '/') orelse return false;
    const host = url[7..path_start];
    if (host.len > 0 and !std.mem.eql(u8, host, "localhost")) {
        var host_buffer: [std.posix.HOST_NAME_MAX]u8 = undefined;
        const local = std.posix.gethostname(&host_buffer) catch return false;
        if (!std.mem.eql(u8, host, local)) return false;
    }
    var decoded: [4097:0]u8 = @splat(0);
    var i = path_start;
    var n: usize = 0;
    while (i < url.len) : (i += 1) {
        if (n == 4096) return false;
        var byte = url[i];
        if (byte == '%') {
            if (i + 2 >= url.len) return false;
            byte = std.fmt.parseInt(u8, url[i + 1 .. i + 3], 16) catch return false;
            i += 2;
        }
        decoded[n] = byte;
        n += 1;
    }
    return setText(&owner.cwd, decoded[0..n]);
}

export fn kite_terminal_new(cols: u16, rows: u16, scrollback_bytes: usize) ?*KiteTerminal {
    if (!validSize(cols, rows) or scrollback_bytes > max_scrollback) return null;
    const self = alloc.create(KiteTerminal) catch return null;
    self.* = .{
        .terminal = Terminal.init(alloc, .{ .cols = cols, .rows = rows, .max_scrollback = if (scrollback_bytes == 0) max_scrollback else scrollback_bytes }) catch {
            alloc.destroy(self);
            return null;
        },
        .parser = undefined,
    };
    self.osc_arena = std.heap.FixedBufferAllocator.init(&self.osc_storage);
    self.parser = Stream.initAlloc(self.osc_arena.allocator(), .{ .owner = self });
    return self;
}

export fn kite_terminal_free(self: ?*KiteTerminal) void {
    const owner = self orelse return;
    owner.parser.deinit();
    owner.terminal.deinit(alloc);
    owner.pending.deinit(alloc);
    owner.replies.deinit(alloc);
    alloc.destroy(owner);
}

fn validSize(cols: u16, rows: u16) bool {
    return cols > 0 and cols <= 1000 and rows > 0 and rows <= 1000;
}

export fn kite_terminal_in_ground(self: *KiteTerminal) bool {
    return !self.failed and self.parser.parser.state == .ground and self.parser.utf8decoder.state == 0;
}

export fn kite_terminal_feed(self: *KiteTerminal, bytes: [*]const u8, len: usize) bool {
    if (self.failed) return false;
    for (bytes[0..len]) |byte| {
        self.executed = false;
        self.printed = false;
        if (self.pending.items.len == max_sequence) {
            self.pending.clearRetainingCapacity();
            self.pending_overflow = true;
        }
        const was_osc = self.parser.parser.state == .osc_string;
        self.parser.next(byte) catch {
            self.failed = true;
            return false;
        };
        if (was_osc and self.parser.parser.state != .osc_string) {
            // OSC dispatch consumed its borrowed payload synchronously. Reclaim
            // the bounded arena before accepting another untrusted command.
            self.parser.parser.osc_parser.reset();
            self.osc_arena.reset();
        }
        if (kite_terminal_in_ground(self)) {
            self.pending.clearRetainingCapacity();
            self.pending_overflow = false;
        } else {
            // A malformed UTF-8 prefix may have emitted U+FFFD while this
            // byte starts a new incomplete character. Do not replay that prefix.
            if (self.printed and self.parser.utf8decoder.state != 0) self.pending.clearRetainingCapacity();
            // ESC interrupts the old sequence. OSC dispatch happens on ESC,
            // not the following backslash; retain only the new ESC in that case.
            if (byte == 0x1b and self.parser.parser.state == .escape) self.pending.clearRetainingCapacity();
            if (!self.executed and !self.pending_overflow) self.pending.append(alloc, byte) catch {
                self.failed = true;
                return false;
            };
        }
    }
    return true;
}

export fn kite_terminal_resize(self: *KiteTerminal, cols: u16, rows: u16) bool {
    if (self.failed or !validSize(cols, rows)) return false;
    self.terminal.resize(alloc, cols, rows) catch {
        self.failed = true;
        return false;
    };
    return true;
}

export fn kite_terminal_title(self: *KiteTerminal) [*:0]const u8 { return &self.title; }
export fn kite_terminal_cwd(self: *KiteTerminal) [*:0]const u8 { return &self.cwd; }

export fn kite_terminal_bytes_free(bytes: ?[*]u8, len: usize) void {
    if (bytes) |p| alloc.free(p[0..len]);
}

export fn kite_terminal_take_reply(self: *KiteTerminal, bytes: *?[*]u8, len: *usize) bool {
    bytes.* = null;
    len.* = 0;
    if (self.failed) return false;
    if (self.replies.items.len == 0) return true;
    const result = self.replies.toOwnedSlice(alloc) catch return false;
    bytes.* = result.ptr;
    len.* = result.len;
    return true;
}

const vt_options: formatter.Options = .{ .emit = .vt, .unwrap = true, .trim = false };

fn modeSequence(writer: *std.Io.Writer, mode: modes.Mode, enabled: bool) !void {
    const tag: modes.ModeTag = @bitCast(@intFromEnum(mode));
    try writer.print("\x1b[{s}{d}{c}", .{ if (tag.ansi) "" else "?", tag.value, @as(u8, if (enabled) 'h' else 'l') });
}

fn cellStyle(page: *const Page, cell: Cell) Style {
    return switch (cell.content_tag) {
        .codepoint, .codepoint_grapheme => if (cell.hasStyling())
            page.styles.get(page.memory, cell.style_id).*
        else
            .{},
        .bg_color_palette => .{ .bg_color = .{ .palette = cell.content.color_palette } },
        .bg_color_rgb => .{ .bg_color = .{ .rgb = .{
            .r = cell.content.color_rgb.r,
            .g = cell.content.color_rgb.g,
            .b = cell.content.color_rgb.b,
        } } },
    };
}

fn content(writer: *std.Io.Writer, screen: *const Screen) !void {
    try writer.writeAll("\x1b[?6l\x1b[?69l\x1b[r\x1b[4l\x1b[?7h\x1b[0m\x1b[0\"q\x1b]8;;\x1b\\\x0f\x1b(B\x1b[H");
    const top = screen.pages.getTopLeft(.screen);
    const bottom = screen.pages.getBottomRight(.screen).?;
    var it = top.pageIterator(.right_down, bottom);
    var first = true;
    var wrapped = false;
    while (it.next()) |chunk| {
        const page = &chunk.node.data;
        for (chunk.start..chunk.end) |y| {
            if (!first and !wrapped) try writer.writeAll("\r\n");
            first = false;
            const row = page.getRow(@intCast(y));
            const cells = page.getCells(row);
            const continuation = wrapped;
            wrapped = row.wrap;
            var start: usize = 0;
            while (start < cells.len) {
                var end = start + 1;
                while (end < cells.len and cells[end].protected == cells[start].protected) : (end += 1) {}
                try writer.print("\x1b[{d}\"q", .{@as(u8, if (cells[start].protected) 1 else 0)});
                const run = cells[start..end];
                if (Cell.hasTextAny(run)) {
                    var row_formatter = formatter.PageFormatter.init(page, vt_options);
                    row_formatter.start_y = @intCast(y);
                    row_formatter.end_y = @intCast(y);
                    row_formatter.start_x = @intCast(start);
                    row_formatter.end_x = @intCast(end - 1);
                    // A row ending in a wide spacer must not include the next
                    // row's glyph. The outer loop owns that continuation.
                    row_formatter.rectangle = true;
                    const trailing = try row_formatter.formatWithState(writer);
                    if (wrapped or end < cells.len) try writer.splatByteAll(' ', trailing.cells);
                } else {
                    // ECH preserves empty cells without changing REP's previous
                    // character. Wrapped/protected blanks need actual printing.
                    var previous: Style = .{};
                    var x = start;
                    while (x < end) {
                        const cell = cells[x];
                        if (cell.wide == .spacer_head or cell.wide == .spacer_tail) {
                            x += 1;
                            continue;
                        }
                        const style = cellStyle(page, cell);
                        var next = x + 1;
                        while (next < end and cells[next].wide == .narrow and
                            cellStyle(page, cells[next]).eql(style)) : (next += 1) {}
                        if (!style.eql(previous)) try writer.print("{f}", .{style.formatterVt()});
                        previous = style;
                        if (wrapped or continuation or cell.protected) {
                            try writer.splatByteAll(' ', next - x);
                        } else {
                            try writer.print("\x1b[{d}X\x1b[{d}C", .{ next - x, next - x });
                        }
                        x = next;
                    }
                    if (!previous.default()) try writer.writeAll("\x1b[0m");
                }
                start = end;
            }
        }
    }
}

fn cursorState(writer: *std.Io.Writer, t: *const Terminal, screen: *const Screen, origin: bool, keyboard: bool) !void {
    try writer.writeAll("\x1b[?6l\x1b[0m\x1b]8;;\x1b\\\x1b[0\"q\x0f\x1b(B\x1b)B\x1b*B\x1b+B\x1b}");
    var state = formatter.ScreenFormatter.init(screen, vt_options);
    state.content = .none;
    state.extra = .all;
    state.extra.protection = false;
    state.extra.cursor = false;
    state.extra.kitty_keyboard = false;
    try state.format(writer);
    try protectionState(writer, screen, screen.cursor.protected);
    if (keyboard) {
        // Restore all eight ring slots, not only the current Kitty flags.
        const stack = screen.kitty_keyboard;
        try writer.writeAll("\x1b[<8u");
        for (0..8) |offset| {
            const index = (@as(usize, stack.idx) + 1 + offset) % 8;
            try writer.print("\x1b[>{d}u", .{stack.flags[index].int()});
        }
    }
    try modeSequence(writer, .origin, origin);
    const c = &screen.cursor;
    const row = if (origin) c.y -| t.scrolling_region.top else c.y;
    const col = if (origin) c.x -| t.scrolling_region.left else c.x;
    try writer.print("\x1b[{d};{d}H", .{ row + 1, col + 1 });
    // CUP clears pending wrap. Reprinting the existing final cell restores it
    // without replaying a historical byte stream or moving any other cell.
    if (c.pending_wrap) {
        const pin = screen.pages.pin(.{ .active = .{ .x = c.x, .y = c.y } }).?;
        var cell = formatter.PageFormatter.init(&pin.node.data, vt_options);
        cell.start_y = pin.y;
        cell.end_y = pin.y;
        cell.start_x = pin.x;
        cell.end_x = pin.x;
        const cells = pin.node.data.getCells(pin.node.data.getRow(pin.y));
        cell.rectangle = true;
        const painted = if (cells[pin.x].wide == .spacer_tail) cells[pin.x - 1] else cells[pin.x];
        try protectionState(writer, screen, painted.protected);
        if (cells[pin.x].wide == .spacer_tail) {
            try writer.print("\x1b[{d};{d}H", .{ row + 1, col });
        }
        try writer.writeAll("\x1b[?7h\x1b[4l\x0f\x1b(B");
        if (!cells[pin.x].hasText() and cells[pin.x].wide != .spacer_tail) {
            const style = cellStyle(&pin.node.data, cells[pin.x]);
            try writer.print("{f} ", .{style.formatterVt()});
        } else {
            try cell.format(writer);
        }
        state.extra.charsets = true;
        try state.format(writer);
        try protectionState(writer, screen, c.protected);
        try modeSequence(writer, .wraparound, t.modes.get(.wraparound));
        try modeSequence(writer, .insert, t.modes.get(.insert));
    }
    const shape: u8 = switch (c.cursor_style) {
        .block => 2,
        .underline => 4,
        .bar => 6,
        .block_hollow => 2,
    };
    try writer.print("\x1b[{d} q", .{shape - @as(u8, if (t.modes.get(.cursor_blinking)) 1 else 0)});
}

fn protectionState(writer: *std.Io.Writer, screen: *const Screen, enabled: bool) !void {
    // DECSCA alone loses the distinction: ISO protection also affects ordinary
    // ECH/EL/ED, whereas DEC protection only affects selective erasure.
    switch (screen.protected_mode) {
        .iso => try writer.writeAll("\x1bV"),
        .dec => try writer.writeAll("\x1b[1\"q"),
        .off => {},
    }
    if (!enabled) try writer.writeAll("\x1b[0\"q");
}

fn savedCursor(writer: *std.Io.Writer, t: *const Terminal, screen: *const Screen) !void {
    const saved = screen.saved_cursor orelse return;
    var view = screen.*;
    view.cursor.x = saved.x;
    view.cursor.y = saved.y;
    view.cursor.style = saved.style;
    view.cursor.protected = saved.protected;
    view.cursor.pending_wrap = saved.pending_wrap;
    view.charset = saved.charset;
    try cursorState(writer, t, &view, saved.origin, false);
    try writer.writeAll("\x1b7");
}

fn screenMargins(writer: *std.Io.Writer, t: *const Terminal) !void {
    try writer.writeAll("\x1b[?6l");
    try modeSequence(writer, .enable_left_and_right_margin, t.modes.get(.enable_left_and_right_margin));
    var extras = formatter.TerminalFormatter.init(t, vt_options);
    extras.content = .none;
    extras.extra = .none;
    extras.extra.scrolling_region = true;
    try extras.format(writer);
}

fn repeatState(writer: *std.Io.Writer, t: *const Terminal) !void {
    const cp = t.previous_char orelse return;
    const screen = t.screens.active;
    const c = screen.cursor;
    if (c.pending_wrap) {
        // cursorState's final-cell repaint is the last print in this case.
        const pin = screen.pages.pin(.{ .active = .{ .x = c.x, .y = c.y } }).?;
        const cells = pin.node.data.getCells(pin.node.data.getRow(pin.y));
        const cell = cells[if (cells[pin.x].wide == .spacer_tail) pin.x - 1 else pin.x];
        if (cell.codepoint() != cp) return error.RepeatStateUnavailable;
        return;
    }

    const width: usize = if (cp <= 0xff) 1 else @intCast(@import("unicode/main.zig").table.get(cp).width);
    var target: ?struct { x: u16, y: u16, erase: bool } = null;
    // Prefer an existing exact glyph: reprinting it doesn't need a scratch
    // region and works on completely full screens. Do not replace graphemes
    // or hyperlinks with a bare codepoint.
    for (0..t.rows) |y| {
        const pin = screen.pages.pin(.{ .active = .{ .x = 0, .y = @intCast(y) } }).?;
        const row = pin.node.data.getRow(pin.y);
        const cells = pin.node.data.getCells(row);
        for (cells, 0..) |cell, x| {
            if (cell.content_tag == .codepoint and cell.codepoint() == cp and !cell.hyperlink) {
                target = .{ .x = @intCast(x), .y = @intCast(y), .erase = false };
                break;
            }
            // ECH resets row wrapping, so only an unwrapped, default empty
            // region is disposable. Never shift/drop live cells to make room.
            if (target == null and !row.wrap and !row.wrap_continuation and x + width <= cells.len) {
                const empty = for (cells[x .. x + width]) |blank| {
                    if (!blank.isEmpty() or blank.hasStyling() or blank.protected or
                        blank.hyperlink or blank.semantic_content != .output) break false;
                } else true;
                if (empty) target = .{ .x = @intCast(x), .y = @intCast(y), .erase = true };
            }
        }
        if (target) |found| if (!found.erase) break;
    }
    // There is no REP setter in the pinned VT parser. If no safe location
    // exists, reject the snapshot rather than silently destroy text/history.
    const found = target orelse return error.RepeatStateUnavailable;
    const pin = screen.pages.pin(.{ .active = .{ .x = found.x, .y = found.y } }).?;
    const cell = pin.node.data.getCells(pin.node.data.getRow(pin.y))[pin.x];
    try writer.writeAll("\x1b[?6l\x1b[?69l\x1b[r\x1b[?7l\x1b[4l\x1b[?2027l\x1b[0m\x1b]8;;\x1b\\\x0f\x1b(B");
    try protectionState(writer, screen, if (found.erase) false else cell.protected);
    try writer.print("\x1b[{d};{d}H{f}", .{ found.y + 1, found.x + 1, cellStyle(&pin.node.data, cell).formatterVt() });
    var utf8: [4]u8 = undefined;
    const len = try std.unicode.utf8Encode(cp, &utf8);
    try writer.writeAll(utf8[0..len]);
    if (found.erase) {
        try writer.print("\x1b[{d};{d}H\x1b[{d}X", .{ found.y + 1, found.x + 1, width });
    }
    try modeSequence(writer, .wraparound, t.modes.get(.wraparound));
    try modeSequence(writer, .insert, t.modes.get(.insert));
    try modeSequence(writer, .grapheme_cluster, t.modes.get(.grapheme_cluster));
    try screenMargins(writer, t);
}

fn checkNullRepeat(t: *const Terminal) !void {
    if (t.previous_char != null) return;
    // RIS is the only supported operation that clears REP. A screen populated
    // by non-print operations such as DECALN cannot be repainted with text
    // while retaining a null REP value. Empty screens use ECH instead.
    inline for (.{ .primary, .alternate }) |key| {
        if (t.screens.get(key)) |screen| {
            if (screen.cursor.pending_wrap) return error.RepeatStateUnavailable;
            if (screen.saved_cursor) |saved| if (saved.pending_wrap) return error.RepeatStateUnavailable;
            const top = screen.pages.getTopLeft(.screen);
            const bottom = screen.pages.getBottomRight(.screen).?;
            var it = top.pageIterator(.right_down, bottom);
            while (it.next()) |chunk| {
                for (chunk.start..chunk.end) |y| {
                    const row = chunk.node.data.getRow(@intCast(y));
                    if (row.wrap) return error.RepeatStateUnavailable;
                    for (chunk.node.data.getCells(row)) |cell| {
                        if (cell.hasText() or cell.protected) return error.RepeatStateUnavailable;
                    }
                }
            }
        }
    }
}

fn snapshot(self: *KiteTerminal, writer: *std.Io.Writer) !void {
    const t = &self.terminal;
    try checkNullRepeat(t);
    // RIS is reconstructed initialization, not a replayed application command.
    try writer.writeAll("\x18\x1bc");
    // Preserve XTSAVE slots before painting. ANSI save slots and operations
    // with screen-clearing or reporting side effects are not replayed here.
    inline for (@typeInfo(modes.Mode).@"enum".fields) |field| {
        const mode: modes.Mode = @enumFromInt(field.value);
        const tag: modes.ModeTag = @bitCast(@intFromEnum(mode));
        switch (mode) {
            .alt_screen_legacy, .alt_screen, .alt_screen_save_cursor_clear_enter,
            .save_cursor, .@"132_column", .enable_mode_3,
            .synchronized_output, .report_color_scheme, .in_band_size_reports,
            => {},
            else => if (!tag.ansi) {
                try modeSequence(writer, mode, @field(t.modes.saved, field.name));
                try writer.print("\x1b[?{d}s", .{tag.value});
            },
        }
    }
    try modeSequence(writer, .grapheme_cluster, t.modes.get(.grapheme_cluster));
    var extras = formatter.TerminalFormatter.init(t, vt_options);
    extras.content = .none;
    extras.extra = .none;
    extras.extra.palette = true;
    try extras.format(writer);
    inline for (.{ .{ "10", "foreground" }, .{ "11", "background" }, .{ "12", "cursor" } }) |entry| {
        if (@field(t.colors, entry[1]).get()) |rgb| try writer.print("\x1b]{s};rgb:{x:0>2}/{x:0>2}/{x:0>2}\x1b\\", .{ entry[0], rgb.r, rgb.g, rgb.b });
    }
    // DECCOLM is intentionally not emitted: it would change the fresh surface
    // to 80/132 columns instead of the daemon's authoritative attach dimensions.
    try modeSequence(writer, .enable_mode_3, t.modes.get(.enable_mode_3));
    const primary = t.screens.get(.primary).?;
    try content(writer, primary);
    try screenMargins(writer, t);
    try savedCursor(writer, t, primary);
    try cursorState(writer, t, primary, t.modes.get(.origin), true);
    if (t.screens.get(.alternate)) |alternate| {
        // 1049 saves the primary cursor unconditionally. Use its saved state
        // as the switching cursor, not the potentially different live cursor.
        if (t.modes.get(.alt_screen_save_cursor_clear_enter)) {
            if (primary.saved_cursor != null) try writer.writeAll("\x1b8");
            try modeSequence(writer, .alt_screen_save_cursor_clear_enter, true);
        } else if (t.modes.get(.alt_screen)) {
            try modeSequence(writer, .alt_screen, true);
        } else {
            try modeSequence(writer, .alt_screen_legacy, true);
        }
        try writer.writeAll("\x1b[2J");
        try content(writer, alternate);
        try screenMargins(writer, t);
        try savedCursor(writer, t, alternate);
        try cursorState(writer, t, alternate, t.modes.get(.origin), true);
        if (t.screens.active_key == .primary) try writer.writeAll("\x1b[?47l");
    }

    // Replay non-destructive modes AFTER contents. Screen switching and saved
    // cursors were reconstructed above without clearing the populated grids.
    inline for (@typeInfo(modes.Mode).@"enum".fields) |field| {
        const mode: modes.Mode = @enumFromInt(field.value);
        switch (mode) {
            .alt_screen_legacy, .alt_screen, .alt_screen_save_cursor_clear_enter,
            .save_cursor, .@"132_column", .enable_mode_3, .origin,
            .synchronized_output, .report_color_scheme, .in_band_size_reports,
            => {},
            else => try modeSequence(writer, mode, t.modes.get(mode)),
        }
    }
    // Mouse protocols have last-operation-wins state in addition to mode bits.
    // Setting a different mouse mode false can clear the active protocol.
    const mouse: ?modes.Mode = switch (t.flags.mouse_event) {
        .none => null,
        .x10 => .mouse_event_x10,
        .normal => .mouse_event_normal,
        .button => .mouse_event_button,
        .any => .mouse_event_any,
    };
    if (mouse) |mode| try modeSequence(writer, mode, true);
    const mouse_format: ?modes.Mode = switch (t.flags.mouse_format) {
        .x10 => null,
        .utf8 => .mouse_format_utf8,
        .sgr => .mouse_format_sgr,
        .urxvt => .mouse_format_urxvt,
        .sgr_pixels => .mouse_format_sgr_pixels,
    };
    if (mouse_format) |mode| try modeSequence(writer, mode, true);
    if (t.flags.mouse_shift_capture != .null) {
        try writer.print("\x1b[>{d}s", .{@as(u8, if (t.flags.mouse_shift_capture == .true) 1 else 0)});
    }
    // Upstream TerminalFormatter emits margin and tab operations AFTER cursor,
    // which homes/moves it. Do extras first under absolute origin, cursor last.
    try writer.writeAll("\x1b[?6l");
    extras.extra = .none;
    extras.extra.tabstops = true;
    extras.extra.scrolling_region = true;
    extras.extra.keyboard = true;
    extras.extra.pwd = true;
    try extras.format(writer);
    try repeatState(writer, t);
    try cursorState(writer, t, t.screens.active, t.modes.get(.origin), true);
    const title = std.mem.sliceTo(&self.title, 0);
    if (title.len != 0) try writer.print("\x1b]2;{s}\x1b\\", .{title});
    // These enable unsolicited reports on a real renderer. Relay suppresses all
    // input until replayEnd, including restoration-generated replies.
    try modeSequence(writer, .report_color_scheme, t.modes.get(.report_color_scheme));
    try modeSequence(writer, .in_band_size_reports, t.modes.get(.in_band_size_reports));
    try modeSequence(writer, .synchronized_output, t.modes.get(.synchronized_output));
    if (t.screens.active.charset.single_shift) |slot| {
        switch (slot) {
            .G2 => try writer.writeAll("\x1bN"),
            .G3 => try writer.writeAll("\x1bO"),
            else => {},
        }
    }
    try writer.writeAll(self.pending.items);
}

export fn kite_terminal_snapshot(self: *KiteTerminal, bytes: *?[*]u8, len: *usize) bool {
    bytes.* = null;
    len.* = 0;
    if (self.failed or self.pending_overflow) return false;
    const buffer = alloc.alloc(u8, max_snapshot) catch return false;
    var writer = std.Io.Writer.fixed(buffer);
    snapshot(self, &writer) catch {
        alloc.free(buffer);
        return false;
    };
    const result = alloc.realloc(buffer, writer.end) catch {
        alloc.free(buffer);
        return false;
    };
    bytes.* = result.ptr;
    len.* = result.len;
    return true;
}
