// Zig FFI implementations for gleam_stdlib.
//
// Ownership convention: FFI functions receive BORROWED values and return
// OWNED values. Anything a result retains from an argument is dup'd;
// scratch buffers use the untracked page allocator and are freed here.
//
// ponytail: "grapheme" functions segment by codepoint, not UAX#29 grapheme
// cluster; lowercase/uppercase/trim are ASCII-only. Upgrade with a proper
// Unicode table when a real program notices.

const std = @import("std");
const P = @import("../prelude.zig");
const Value = P.Value;

const scratch = P.allocator;

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
    return P.dup(value);
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
    const text = std.fmt.allocPrint(scratch, "{d}", .{x.int}) catch @panic("out of memory");
    defer scratch.free(text);
    return P.copyString(text);
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
    return P.copyString(buffer[index..]);
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
        std.fmt.allocPrint(scratch, "{d}.0", .{f}) catch @panic("out of memory")
    else
        std.fmt.allocPrint(scratch, "{d}", .{f}) catch @panic("out of memory");
    defer scratch.free(text);
    return P.copyString(text);
}

pub fn ceiling(x: Value) Value {
    return P.floatValue(@ceil(x.float));
}

pub fn floor(x: Value) Value {
    return P.floatValue(@floor(x.float));
}

/// Saturating float-to-int: NaN maps to 0, out-of-range clamps, instead
/// of safety panics / UB on valid Gleam calls like float.round(1.0e300).
fn floatToInt(f: f64) i64 {
    if (std.math.isNan(f)) return 0;
    return std.math.lossyCast(i64, f);
}

pub fn round(x: Value) Value {
    return P.intValue(floatToInt(@round(x.float)));
}

pub fn truncate(x: Value) Value {
    return P.intValue(floatToInt(@trunc(x.float)));
}

pub fn power(base: Value, exponent: Value) Value {
    return P.floatValue(std.math.pow(f64, base.float, exponent.float));
}

// ponytail: time-seeded xoshiro, not crypto-grade; swap for an OS entropy
// source if anything security-adjacent ever uses float.random.
threadlocal var prng: ?std.Random.DefaultPrng = null;

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
    const out = P.copyString(string.string);
    for (@constCast(out.string)) |*c| c.* = std.ascii.toLower(c.*);
    return out;
}

pub fn uppercase(string: Value) Value {
    const out = P.copyString(string.string);
    for (@constCast(out.string)) |*c| c.* = std.ascii.toUpper(c.*);
    return out;
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
    if (index.int < 0 or count.int <= 0) return P.copyString("");
    const start = codepointOffset(s, index.int);
    const end = codepointOffset(s[start..], count.int) + start;
    return P.copyString(s[start..end]);
}

pub fn string_byte_slice(string: Value, index: Value, count: Value) Value {
    const s = string.string;
    const start: usize = @intCast(@min(@max(index.int, 0), @as(i64, @intCast(s.len))));
    const wanted: usize = @intCast(@max(count.int, 0));
    const end = @min(start + wanted, s.len);
    return P.copyString(s[start..end]);
}

pub fn crop_string(string: Value, substring: Value) Value {
    const position = std.mem.indexOf(u8, string.string, substring.string) orelse
        return P.dup(string);
    return P.copyString(string.string[position..]);
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
    const before = P.copyString(string.string[0..position]);
    const after = P.copyString(string.string[position + substring.string.len ..]);
    return ok(P.tupleValue(&[_]Value{ before, after }));
}

const whitespace = " \t\n\r";

pub fn trim_start(string: Value) Value {
    return P.copyString(std.mem.trimLeft(u8, string.string, whitespace));
}

pub fn trim_end(string: Value) Value {
    return P.copyString(std.mem.trimRight(u8, string.string, whitespace));
}

pub fn pop_grapheme(string: Value) Value {
    const s = string.string;
    if (s.len == 0) return err(P.NIL);
    const first_length = std.unicode.utf8ByteSequenceLength(s[0]) catch 1;
    const first = P.copyString(s[0..first_length]);
    const rest = P.copyString(s[first_length..]);
    return ok(P.tupleValue(&[_]Value{ first, rest }));
}

pub fn graphemes(string: Value) Value {
    const s = string.string;
    var items: std.ArrayList(Value) = .empty;
    defer items.deinit(scratch);
    var index: usize = 0;
    while (index < s.len) {
        const step = std.unicode.utf8ByteSequenceLength(s[index]) catch 1;
        items.append(scratch, P.copyString(s[index .. index + step])) catch
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
    defer items.deinit(scratch);
    var iterator = std.unicode.Utf8Iterator{ .bytes = s, .i = 0 };
    while (iterator.nextCodepoint()) |cp| {
        items.append(scratch, P.intValue(cp)) catch @panic("out of memory");
    }
    return P.listFromSlice(items.items, P.emptyList());
}

pub fn utf_codepoint_list_to_string(list: Value) Value {
    var aw = std.Io.Writer.Allocating.init(scratch);
    defer aw.deinit();
    var cell = list.list;
    while (cell != null) {
        var buffer: [4]u8 = undefined;
        const encoded = std.unicode.utf8Encode(@intCast(cell.?.head.int), &buffer) catch 0;
        aw.writer.writeAll(buffer[0..encoded]) catch @panic("out of memory");
        cell = cell.?.tail;
    }
    return P.copyString(aw.written());
}

pub fn inspect(term: Value) Value {
    return P.inspectValue(term);
}

pub fn string_remove_prefix(string: Value, prefix: Value) Value {
    if (std.mem.startsWith(u8, string.string, prefix.string)) {
        return P.copyString(string.string[prefix.string.len..]);
    }
    return P.dup(string);
}

pub fn string_remove_suffix(string: Value, suffix: Value) Value {
    if (std.mem.endsWith(u8, string.string, suffix.string)) {
        return P.copyString(string.string[0 .. string.string.len - suffix.string.len]);
    }
    return P.dup(string);
}

// ------------------------------------------------------------------ string_tree
// StringTree is represented as a plain string; add/concat copy eagerly.

pub fn add(tree: Value, string: Value) Value {
    // concatenate consumes; these are borrowed, so take references first.
    return P.concatenate(P.dup(tree), P.dup(string));
}

pub fn concat(trees: Value) Value {
    var aw = std.Io.Writer.Allocating.init(scratch);
    defer aw.deinit();
    var cell = trees.list;
    while (cell != null) {
        aw.writer.writeAll(cell.?.head.string) catch @panic("out of memory");
        cell = cell.?.tail;
    }
    return P.copyString(aw.written());
}

pub fn length(tree: Value) Value {
    return P.intValue(@intCast(tree.string.len));
}

pub fn split(string: Value, pattern: Value) Value {
    const s = string.string;
    const separator = pattern.string;
    if (separator.len == 0) return graphemes(string);
    var items: std.ArrayList(Value) = .empty;
    defer items.deinit(scratch);
    var start: usize = 0;
    while (std.mem.indexOfPos(u8, s, start, separator)) |position| {
        items.append(scratch, P.copyString(s[start..position])) catch
            @panic("out of memory");
        start = position + separator.len;
    }
    items.append(scratch, P.copyString(s[start..])) catch @panic("out of memory");
    return P.listFromSlice(items.items, P.emptyList());
}

pub fn string_replace(string: Value, pattern: Value, replacement: Value) Value {
    const replaced = std.mem.replaceOwned(
        u8,
        scratch,
        string.string,
        pattern.string,
        replacement.string,
    ) catch @panic("out of memory");
    defer scratch.free(replaced);
    return P.copyString(replaced);
}

// ------------------------------------------------------------------ dict
// ponytail: Dict is an insertion-ordered association list (a Value.list of
// #(key, value) tuples). O(n) operations; swap for a hash map when a real
// workload notices. "Transient" variants return fresh copies.

pub fn dict_identity(dict: Value) Value {
    return P.dup(dict);
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
        if (P.isEqual(cell.?.head.tuple[0], key)) return ok(P.dup(cell.?.head.tuple[1]));
    }
    return err(P.NIL);
}

/// Borrows dict, key and value; returns an owned copy of the dict with
/// `key` replaced (keeping its position) or the new entry appended.
fn dictPut(dict: Value, key: Value, value: Value) Value {
    var items: std.ArrayList(Value) = .empty;
    defer items.deinit(scratch);
    var replaced = false;
    var cell = dict.list;
    while (cell != null) : (cell = cell.?.tail) {
        if (P.isEqual(cell.?.head.tuple[0], key)) {
            const entry = P.tupleValue(&[_]Value{ P.dup(key), P.dup(value) });
            items.append(scratch, entry) catch @panic("out of memory");
            replaced = true;
        } else {
            items.append(scratch, P.dup(cell.?.head)) catch @panic("out of memory");
        }
    }
    if (!replaced) {
        const entry = P.tupleValue(&[_]Value{ P.dup(key), P.dup(value) });
        items.append(scratch, entry) catch @panic("out of memory");
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
    defer items.deinit(scratch);
    var cell = dict.list;
    while (cell != null) : (cell = cell.?.tail) {
        const key = cell.?.head.tuple[0];
        const mapped = P.call2(P.dup(fun), P.dup(key), P.dup(cell.?.head.tuple[1]));
        const entry = P.tupleValue(&[_]Value{ P.dup(key), mapped });
        items.append(scratch, entry) catch @panic("out of memory");
    }
    return P.listFromSlice(items.items, P.emptyList());
}

pub fn dict_transient_delete(key: Value, dict: Value) Value {
    var items: std.ArrayList(Value) = .empty;
    defer items.deinit(scratch);
    var cell = dict.list;
    while (cell != null) : (cell = cell.?.tail) {
        if (!P.isEqual(cell.?.head.tuple[0], key)) {
            items.append(scratch, P.dup(cell.?.head)) catch @panic("out of memory");
        }
    }
    return P.listFromSlice(items.items, P.emptyList());
}

pub fn dict_fold(dict: Value, initial: Value, fun: Value) Value {
    var accumulator = P.dup(initial);
    var cell = dict.list;
    while (cell != null) : (cell = cell.?.tail) {
        accumulator = P.call3(
            P.dup(fun),
            accumulator,
            P.dup(cell.?.head.tuple[0]),
            P.dup(cell.?.head.tuple[1]),
        );
    }
    return accumulator;
}

pub fn dict_transient_update_with(key: Value, fun: Value, init: Value, dict: Value) Value {
    var cell = dict.list;
    while (cell != null) : (cell = cell.?.tail) {
        if (P.isEqual(cell.?.head.tuple[0], key)) {
            const updated = P.call1(P.dup(fun), P.dup(cell.?.head.tuple[1]));
            const result = dictPut(dict, key, updated);
            P.drop(updated);
            return result;
        }
    }
    return dictPut(dict, key, init);
}

// ------------------------------------------------------------------ bit_array

pub fn ba_from_string(string: Value) Value {
    return P.copyBitArray(string.string);
}

pub fn ba_bit_size(bits: Value) Value {
    return P.intValue(@intCast(bits.bit_array.bytes().len * 8));
}

pub fn ba_byte_size(bits: Value) Value {
    return P.intValue(@intCast(bits.bit_array.bytes().len));
}

pub fn ba_unsafe_to_string(bits: Value) Value {
    return P.copyString(bits.bit_array.bytes());
}

pub fn ba_to_string(bits: Value) Value {
    const view = bits.bit_array.bytes();
    if (!std.unicode.utf8ValidateSlice(view)) return err(P.NIL);
    return ok(P.copyString(view));
}

/// Negative length slices backwards from position.
pub fn ba_slice(bits: Value, position: Value, count: Value) Value {
    const view = bits.bit_array.bytes();
    const size: i64 = @intCast(view.len);
    const p = position.int;
    const l = count.int;
    const start = if (l < 0) p + l else p;
    const end = if (l < 0) p else p + l;
    if (start < 0 or end > size or start > end) return err(P.NIL);
    return ok(P.copyBitArray(view[@intCast(start)..@intCast(end)]));
}

pub fn ba_concat(bit_arrays: Value) Value {
    var aw = std.Io.Writer.Allocating.init(scratch);
    defer aw.deinit();
    var cell = bit_arrays.list;
    while (cell != null) : (cell = cell.?.tail) {
        aw.writer.writeAll(cell.?.head.bit_array.bytes()) catch @panic("out of memory");
    }
    return P.copyBitArray(aw.written());
}

pub fn ba_base64_encode(input: Value, padding: Value) Value {
    const view = input.bit_array.bytes();
    const encoder = if (padding.bool)
        std.base64.standard.Encoder
    else
        std.base64.standard_no_pad.Encoder;
    const size = encoder.calcSize(view.len);
    const buffer = scratch.alloc(u8, size) catch @panic("out of memory");
    defer scratch.free(buffer);
    return P.copyString(encoder.encode(buffer, view));
}

pub fn ba_base64_decode(encoded: Value) Value {
    const text = encoded.string;
    const decoder = if (std.mem.endsWith(u8, text, "="))
        std.base64.standard.Decoder
    else
        std.base64.standard_no_pad.Decoder;
    const size = decoder.calcSizeForSlice(text) catch return err(P.NIL);
    const buffer = scratch.alloc(u8, size) catch @panic("out of memory");
    defer scratch.free(buffer);
    decoder.decode(buffer, text) catch return err(P.NIL);
    return ok(P.copyBitArray(buffer));
}

pub fn ba_base16_encode(input: Value) Value {
    const digits = "0123456789ABCDEF";
    const view = input.bit_array.bytes();
    const buffer = scratch.alloc(u8, view.len * 2) catch @panic("out of memory");
    defer scratch.free(buffer);
    for (view, 0..) |byte, index| {
        buffer[index * 2] = digits[byte >> 4];
        buffer[index * 2 + 1] = digits[byte & 0x0F];
    }
    return P.copyString(buffer);
}

pub fn ba_base16_decode(input: Value) Value {
    const text = input.string;
    if (text.len % 2 != 0) return err(P.NIL);
    const buffer = scratch.alloc(u8, text.len / 2) catch @panic("out of memory");
    defer scratch.free(buffer);
    for (0..buffer.len) |index| {
        buffer[index] = std.fmt.parseInt(u8, text[index * 2 .. index * 2 + 2], 16) catch
            return err(P.NIL);
    }
    return ok(P.copyBitArray(buffer));
}

pub fn ba_starts_with(bits: Value, prefix: Value) Value {
    return P.boolValue(std.mem.startsWith(u8, bits.bit_array.bytes(), prefix.bit_array.bytes()));
}
