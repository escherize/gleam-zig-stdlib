// Zig FFI implementations for gleam_stdlib.
//
// Convention: one Value parameter per Gleam argument, returning Value.
// Values are borrowed in and owned out; everything leaks for now (the
// compiler's Perceus pass will manage memory later).
//
// ponytail: "grapheme" functions segment by codepoint, not UAX#29 grapheme
// cluster; lowercase/uppercase/trim are ASCII-only. Upgrade with a proper
// Unicode table when a real program notices.

const std = @import("std");
const P = @import("../prelude.zig");
const Value = P.Value;

const allocator = P.allocator;

fn ok(value: Value) Value {
    return P.makeRecord("Ok", &[_]Value{value});
}

fn err(value: Value) Value {
    return P.makeRecord("Error", &[_]Value{value});
}

var io_threaded: std.Io.Threaded = .init_single_threaded;

// ------------------------------------------------------------------ io

pub fn print(string: Value) Value {
    doPrint(string.string, false, false);
    return P.NIL;
}

pub fn print_error(string: Value) Value {
    doPrint(string.string, false, true);
    return P.NIL;
}

pub fn console_log(string: Value) Value {
    doPrint(string.string, true, false);
    return P.NIL;
}

pub fn console_error(string: Value) Value {
    doPrint(string.string, true, true);
    return P.NIL;
}

fn doPrint(text: []const u8, newline: bool, to_stderr: bool) void {
    const file = if (to_stderr) std.Io.File.stderr() else std.Io.File.stdout();
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io_threaded.io(), &buffer);
    writer.interface.writeAll(text) catch {};
    if (newline) writer.interface.writeAll("\n") catch {};
    writer.interface.flush() catch {};
}

// ------------------------------------------------------------------ int

pub fn identity(value: Value) Value {
    return value;
}

pub fn int_to_float(x: Value) Value {
    return P.floatValue(@floatFromInt(x.int));
}

pub fn parse_int(string: Value) Value {
    const s = string.string;
    if (!isStrictInt(s)) return err(P.NIL);
    const parsed = std.fmt.parseInt(i64, s, 10) catch return err(P.NIL);
    return ok(P.intValue(parsed));
}

fn isStrictInt(s: []const u8) bool {
    if (s.len == 0) return false;
    var index: usize = 0;
    if (s[0] == '+' or s[0] == '-') index = 1;
    if (index == s.len) return false;
    for (s[index..]) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

pub fn int_from_base_string(string: Value, base: Value) Value {
    const parsed = std.fmt.parseInt(i64, string.string, @intCast(base.int)) catch
        return err(P.NIL);
    return ok(P.intValue(parsed));
}

pub fn to_string(x: Value) Value {
    const text = std.fmt.allocPrint(allocator, "{d}", .{x.int}) catch @panic("out of memory");
    return P.stringValue(text);
}

pub fn int_to_base_string(x: Value, base: Value) Value {
    const digits = "0123456789abcdefghijklmnopqrstuvwxyz";
    const b: u64 = @intCast(base.int);
    var buffer: [70]u8 = undefined;
    var index: usize = buffer.len;
    const negative = x.int < 0;
    var magnitude: u64 = @abs(x.int);
    if (magnitude == 0) {
        index -= 1;
        buffer[index] = '0';
    }
    while (magnitude != 0) {
        index -= 1;
        buffer[index] = digits[@intCast(magnitude % b)];
        magnitude /= b;
    }
    if (negative) {
        index -= 1;
        buffer[index] = '-';
    }
    const text = allocator.dupe(u8, buffer[index..]) catch @panic("out of memory");
    return P.stringValue(text);
}

pub fn bitwise_and(x: Value, y: Value) Value {
    return P.intValue(x.int & y.int);
}

pub fn bitwise_not(x: Value) Value {
    return P.intValue(~x.int);
}

pub fn bitwise_or(x: Value, y: Value) Value {
    return P.intValue(x.int | y.int);
}

pub fn bitwise_exclusive_or(x: Value, y: Value) Value {
    return P.intValue(x.int ^ y.int);
}

pub fn bitwise_shift_left(x: Value, y: Value) Value {
    if (y.int < 0 or y.int > 63) return P.intValue(0);
    return P.intValue(x.int << @intCast(y.int));
}

pub fn bitwise_shift_right(x: Value, y: Value) Value {
    if (y.int < 0) return P.intValue(0);
    const amount: u6 = if (y.int > 63) 63 else @intCast(y.int);
    return P.intValue(x.int >> amount);
}

// ------------------------------------------------------------------ float

pub fn parse_float(string: Value) Value {
    const s = string.string;
    // Gleam floats require a decimal point.
    if (std.mem.indexOfScalar(u8, s, '.') == null) return err(P.NIL);
    const parsed = std.fmt.parseFloat(f64, s) catch return err(P.NIL);
    return ok(P.floatValue(parsed));
}

pub fn float_to_string(x: Value) Value {
    const f = x.float;
    const text = if (f == @trunc(f) and !std.math.isInf(f) and !std.math.isNan(f))
        std.fmt.allocPrint(allocator, "{d}.0", .{f}) catch @panic("out of memory")
    else
        std.fmt.allocPrint(allocator, "{d}", .{f}) catch @panic("out of memory");
    return P.stringValue(text);
}

pub fn ceiling(x: Value) Value {
    return P.floatValue(@ceil(x.float));
}

pub fn floor(x: Value) Value {
    return P.floatValue(@floor(x.float));
}

pub fn round(x: Value) Value {
    return P.intValue(@intFromFloat(@round(x.float)));
}

pub fn truncate(x: Value) Value {
    return P.intValue(@intFromFloat(@trunc(x.float)));
}

pub fn power(base: Value, exponent: Value) Value {
    return P.floatValue(std.math.pow(f64, base.float, exponent.float));
}

// ponytail: time-seeded xoshiro, not crypto-grade; swap for an OS entropy
// source if anything security-adjacent ever uses float.random.
var prng: ?std.Random.DefaultPrng = null;

pub fn random_uniform() Value {
    if (prng == null) {
        const now = std.Io.Clock.now(.awake, io_threaded.io());
        const seed: u64 = @truncate(@as(u96, @bitCast(now.nanoseconds)));
        prng = std.Random.DefaultPrng.init(seed ^ @intFromPtr(&prng));
    }
    return P.floatValue(prng.?.random().float(f64));
}

pub fn log(x: Value) Value {
    return P.floatValue(@log(x.float));
}

pub fn exp(x: Value) Value {
    return P.floatValue(@exp(x.float));
}

// ------------------------------------------------------------------ string

fn codepointCount(s: []const u8) i64 {
    var count: i64 = 0;
    var index: usize = 0;
    while (index < s.len) {
        index += std.unicode.utf8ByteSequenceLength(s[index]) catch 1;
        count += 1;
    }
    return count;
}

pub fn string_length(string: Value) Value {
    return P.intValue(codepointCount(string.string));
}

pub fn byte_size(string: Value) Value {
    return P.intValue(@intCast(string.string.len));
}

pub fn lowercase(string: Value) Value {
    const out = allocator.dupe(u8, string.string) catch @panic("out of memory");
    for (out) |*c| c.* = std.ascii.toLower(c.*);
    return P.stringValue(out);
}

pub fn uppercase(string: Value) Value {
    const out = allocator.dupe(u8, string.string) catch @panic("out of memory");
    for (out) |*c| c.* = std.ascii.toUpper(c.*);
    return P.stringValue(out);
}

pub fn less_than(a: Value, b: Value) Value {
    return P.boolValue(std.mem.order(u8, a.string, b.string) == .lt);
}

/// Byte offset of the codepoint at `index`, or the string length if past
/// the end.
fn codepointOffset(s: []const u8, index: i64) usize {
    var seen: i64 = 0;
    var offset: usize = 0;
    while (offset < s.len and seen < index) {
        offset += std.unicode.utf8ByteSequenceLength(s[offset]) catch 1;
        seen += 1;
    }
    return offset;
}

pub fn string_grapheme_slice(string: Value, index: Value, count: Value) Value {
    const s = string.string;
    if (index.int < 0 or count.int <= 0) return P.stringValue("");
    const start = codepointOffset(s, index.int);
    const end = codepointOffset(s[start..], count.int) + start;
    return P.stringValue(s[start..end]);
}

pub fn string_byte_slice(string: Value, index: Value, count: Value) Value {
    const s = string.string;
    const start: usize = @intCast(@min(@max(index.int, 0), @as(i64, @intCast(s.len))));
    const wanted: usize = @intCast(@max(count.int, 0));
    const end = @min(start + wanted, s.len);
    return P.stringValue(s[start..end]);
}

pub fn crop_string(string: Value, substring: Value) Value {
    const position = std.mem.indexOf(u8, string.string, substring.string) orelse
        return string;
    return P.stringValue(string.string[position..]);
}

pub fn contains_string(haystack: Value, needle: Value) Value {
    return P.boolValue(std.mem.indexOf(u8, haystack.string, needle.string) != null);
}

pub fn starts_with(string: Value, prefix: Value) Value {
    return P.boolValue(std.mem.startsWith(u8, string.string, prefix.string));
}

pub fn ends_with(string: Value, suffix: Value) Value {
    return P.boolValue(std.mem.endsWith(u8, string.string, suffix.string));
}

pub fn split_once(string: Value, substring: Value) Value {
    const position = std.mem.indexOf(u8, string.string, substring.string) orelse
        return err(P.NIL);
    const before = P.stringValue(string.string[0..position]);
    const after = P.stringValue(string.string[position + substring.string.len ..]);
    return ok(P.tupleValue(&[_]Value{ before, after }));
}

const whitespace = " \t\n\r";

pub fn trim_start(string: Value) Value {
    return P.stringValue(std.mem.trimLeft(u8, string.string, whitespace));
}

pub fn trim_end(string: Value) Value {
    return P.stringValue(std.mem.trimRight(u8, string.string, whitespace));
}

pub fn pop_grapheme(string: Value) Value {
    const s = string.string;
    if (s.len == 0) return err(P.NIL);
    const first_length = std.unicode.utf8ByteSequenceLength(s[0]) catch 1;
    const first = P.stringValue(s[0..first_length]);
    const rest = P.stringValue(s[first_length..]);
    return ok(P.tupleValue(&[_]Value{ first, rest }));
}

pub fn graphemes(string: Value) Value {
    const s = string.string;
    var items: std.ArrayList(Value) = .empty;
    var index: usize = 0;
    while (index < s.len) {
        const step = std.unicode.utf8ByteSequenceLength(s[index]) catch 1;
        items.append(allocator, P.stringValue(s[index .. index + step])) catch
            @panic("out of memory");
        index += step;
    }
    return P.listFromSlice(items.items, P.emptyList());
}

pub fn codepoint(value: Value) Value {
    // UtfCodepoint is represented as its integer value.
    return value;
}

pub fn utf_codepoint_to_int(value: Value) Value {
    return value;
}

pub fn string_to_codepoint_integer_list(string: Value) Value {
    const s = string.string;
    var items: std.ArrayList(Value) = .empty;
    var iterator = std.unicode.Utf8Iterator{ .bytes = s, .i = 0 };
    while (iterator.nextCodepoint()) |cp| {
        items.append(allocator, P.intValue(cp)) catch @panic("out of memory");
    }
    return P.listFromSlice(items.items, P.emptyList());
}

pub fn utf_codepoint_list_to_string(list: Value) Value {
    var aw = std.Io.Writer.Allocating.init(allocator);
    var cell = list.list;
    while (cell != null) {
        var buffer: [4]u8 = undefined;
        const encoded = std.unicode.utf8Encode(@intCast(cell.?.head.int), &buffer) catch 0;
        aw.writer.writeAll(buffer[0..encoded]) catch @panic("out of memory");
        cell = cell.?.tail;
    }
    return P.stringValue(aw.written());
}

pub fn inspect(term: Value) Value {
    return P.stringValue(P.inspectValue(term));
}

pub fn string_remove_prefix(string: Value, prefix: Value) Value {
    if (std.mem.startsWith(u8, string.string, prefix.string)) {
        return P.stringValue(string.string[prefix.string.len..]);
    }
    return string;
}

pub fn string_remove_suffix(string: Value, suffix: Value) Value {
    if (std.mem.endsWith(u8, string.string, suffix.string)) {
        return P.stringValue(string.string[0 .. string.string.len - suffix.string.len]);
    }
    return string;
}

// ------------------------------------------------------------------ string_tree
// StringTree is represented as a plain string; add/concat copy eagerly.

pub fn add(tree: Value, string: Value) Value {
    return P.concatenate(tree, string);
}

pub fn concat(trees: Value) Value {
    var aw = std.Io.Writer.Allocating.init(allocator);
    var cell = trees.list;
    while (cell != null) {
        aw.writer.writeAll(cell.?.head.string) catch @panic("out of memory");
        cell = cell.?.tail;
    }
    return P.stringValue(aw.written());
}

pub fn length(tree: Value) Value {
    return P.intValue(@intCast(tree.string.len));
}

pub fn split(string: Value, pattern: Value) Value {
    const s = string.string;
    const separator = pattern.string;
    var items: std.ArrayList(Value) = .empty;
    if (separator.len == 0) return graphemes(string);
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, s, start, separator)) |position| {
        items.append(allocator, P.stringValue(s[start..position])) catch
            @panic("out of memory");
        start = position + separator.len;
    }
    items.append(allocator, P.stringValue(s[start..])) catch @panic("out of memory");
    return P.listFromSlice(items.items, P.emptyList());
}

pub fn string_replace(string: Value, pattern: Value, replacement: Value) Value {
    const replaced = std.mem.replaceOwned(
        u8,
        allocator,
        string.string,
        pattern.string,
        replacement.string,
    ) catch @panic("out of memory");
    return P.stringValue(replaced);
}

// ------------------------------------------------------------------ dict
// ponytail: Dict is an insertion-ordered association list (a Value.list of
// #(key, value) tuples). O(n) operations; swap for a hash map when a real
// workload notices. "Transient" variants return fresh copies.

pub fn dict_identity(dict: Value) Value {
    return dict;
}

pub fn dict_make() Value {
    return P.emptyList();
}

pub fn dict_size(dict: Value) Value {
    var count: i64 = 0;
    var cell = dict.list;
    while (cell != null) : (cell = cell.?.tail) count += 1;
    return P.intValue(count);
}

pub fn dict_has(dict: Value, key: Value) Value {
    var cell = dict.list;
    while (cell != null) : (cell = cell.?.tail) {
        if (P.isEqual(cell.?.head.tuple[0], key)) return P.TRUE;
    }
    return P.FALSE;
}

pub fn dict_get(dict: Value, key: Value) Value {
    var cell = dict.list;
    while (cell != null) : (cell = cell.?.tail) {
        if (P.isEqual(cell.?.head.tuple[0], key)) return ok(cell.?.head.tuple[1]);
    }
    return err(P.NIL);
}

/// Copy the dict, replacing `key` if present (keeping its position) or
/// appending the new entry at the end.
fn dictPut(dict: Value, key: Value, value: Value) Value {
    var items: std.ArrayList(Value) = .empty;
    var replaced = false;
    var cell = dict.list;
    while (cell != null) : (cell = cell.?.tail) {
        if (P.isEqual(cell.?.head.tuple[0], key)) {
            items.append(allocator, P.tupleValue(&[_]Value{ key, value })) catch
                @panic("out of memory");
            replaced = true;
        } else {
            items.append(allocator, cell.?.head) catch @panic("out of memory");
        }
    }
    if (!replaced) {
        items.append(allocator, P.tupleValue(&[_]Value{ key, value })) catch
            @panic("out of memory");
    }
    return P.listFromSlice(items.items, P.emptyList());
}

pub fn dict_insert(dict: Value, key: Value, value: Value) Value {
    return dictPut(dict, key, value);
}

pub fn dict_transient_insert(key: Value, value: Value, dict: Value) Value {
    return dictPut(dict, key, value);
}

pub fn dict_map(dict: Value, fun: Value) Value {
    var items: std.ArrayList(Value) = .empty;
    var cell = dict.list;
    while (cell != null) : (cell = cell.?.tail) {
        const key = cell.?.head.tuple[0];
        const mapped = P.call2(fun, key, cell.?.head.tuple[1]);
        items.append(allocator, P.tupleValue(&[_]Value{ key, mapped })) catch
            @panic("out of memory");
    }
    return P.listFromSlice(items.items, P.emptyList());
}

pub fn dict_transient_delete(key: Value, dict: Value) Value {
    var items: std.ArrayList(Value) = .empty;
    var cell = dict.list;
    while (cell != null) : (cell = cell.?.tail) {
        if (!P.isEqual(cell.?.head.tuple[0], key)) {
            items.append(allocator, cell.?.head) catch @panic("out of memory");
        }
    }
    return P.listFromSlice(items.items, P.emptyList());
}

pub fn dict_fold(dict: Value, initial: Value, fun: Value) Value {
    var accumulator = initial;
    var cell = dict.list;
    while (cell != null) : (cell = cell.?.tail) {
        accumulator = P.call3(fun, accumulator, cell.?.head.tuple[0], cell.?.head.tuple[1]);
    }
    return accumulator;
}

pub fn dict_transient_update_with(key: Value, fun: Value, init: Value, dict: Value) Value {
    var cell = dict.list;
    while (cell != null) : (cell = cell.?.tail) {
        if (P.isEqual(cell.?.head.tuple[0], key)) {
            return dictPut(dict, key, P.call1(fun, cell.?.head.tuple[1]));
        }
    }
    return dictPut(dict, key, init);
}
