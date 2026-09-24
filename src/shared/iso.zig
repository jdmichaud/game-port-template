//! ISO 9660 over an abstract byte source (DESIGN.md): the shared half of reading
//! a gameport CD. The file system and the byte access are separate, so nothing here does
//! host I/O. The image comes through a `ByteSource`, which a native file, a browser Blob or a
//! block of memory can implement. This file compiles for wasm32-freestanding with the rest of
//! the shared module.
//!
//! The reader never buffers the image. A lookup reads only the sectors that it needs, and a
//! file read is one range read of the file's extent. The browser host can thus keep the ISO on
//! its side and answer slices of it.
//!
//! Only the primary volume descriptor and its directory records are read: no path tables, no
//! Joliet or Rock Ridge, no multi-extent files. An ISO identifier becomes a logical asset name:
//! the `;1` version suffix and the trailing `.` of a name without extension are removed, and
//! the result is upper-cased. An identifier that is not a valid logical component is
//! invisible, not an error, as in the directory provider. A malformed image gives `error.Io`
//! and never a read out of bounds: each field is checked against its record, each record
//! against its sector, and each extent against the image.
const std = @import("std");
const platform = @import("platform.zig");

/// The logical block size that this reader supports, and the only one that a game CD uses.
pub const sector_size = 2048;

/// The volume descriptors follow the 16-sector system area.
const primary_descriptor_lba = 16;
const descriptor_primary = 0x01;
const descriptor_terminator = 0xff;
const descriptor_signature = "CD001";
const descriptor_version = 1;

/// A directory record up to its identifier: lengths, extent, date, flags, interleaving and
/// the volume sequence number.
const record_fixed_len = 33;
const flag_directory = 0x02;
const flag_multi_extent = 0x80;

/// Limits for one directory, so that a corrupt record cannot make the enumeration run without
/// end. A game CD is far below both limits.
const max_directory_bytes = 1 << 20;
const max_directory_records = 8192;

/// Random access to an image: a host file, a browser Blob, or bytes in memory. Reads are
/// positional and can be short, as in `platform.AssetSource.read_at`, so a source can return
/// the result of one range request.
pub const ByteSource = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        read_at: *const fn (*anyopaque, u64, []u8) platform.AssetError!usize,
        /// The image's length when the source knows it, else null. The reader uses it to
        /// reject extents that point past the end.
        length: *const fn (*anyopaque) ?u64,
    };

    /// Reads at `offset` into `dst`; returns the actual count (short reads and EOF allowed).
    pub fn readAt(s: ByteSource, offset: u64, dst: []u8) platform.AssetError!usize {
        return s.vtable.read_at(s.context, offset, dst);
    }

    pub fn length(s: ByteSource) ?u64 {
        return s.vtable.length(s.context);
    }

    /// Fills all of `dst`, and reads again after a short read. A read of zero bytes before the
    /// end gives `error.ShortRead`.
    pub fn readExact(s: ByteSource, offset: u64, dst: []u8) platform.AssetError!void {
        var done: usize = 0;
        while (done < dst.len) {
            const at = std.math.add(u64, offset, done) catch return error.Io;
            const n = try s.readAt(at, dst[done..]);
            if (n == 0) return error.ShortRead;
            done += n;
        }
    }
};

/// A byte source over bytes in memory: the test images, and in the browser an ISO that the
/// host has fetched completely.
pub const MemoryByteSource = struct {
    bytes: []const u8,
    /// Deliver at most this many bytes per read (0 = no limit), to exercise short reads.
    max_read: usize = 0,

    pub fn init(bytes: []const u8) MemoryByteSource {
        return .{ .bytes = bytes };
    }

    pub fn byteSource(self: *MemoryByteSource) ByteSource {
        return .{ .context = self, .vtable = &vtable };
    }

    const vtable = ByteSource.VTable{ .read_at = readAt, .length = length };

    fn readAt(ctx: *anyopaque, offset: u64, dst: []u8) platform.AssetError!usize {
        const self: *MemoryByteSource = @ptrCast(@alignCast(ctx));
        if (offset >= self.bytes.len) return 0;
        const start: usize = @intCast(offset);
        var n = @min(dst.len, self.bytes.len - start);
        if (self.max_read != 0) n = @min(n, self.max_read);
        @memcpy(dst[0..n], self.bytes[start..][0..n]);
        return n;
    }

    fn length(ctx: *anyopaque) ?u64 {
        const self: *MemoryByteSource = @ptrCast(@alignCast(ctx));
        return self.bytes.len;
    }
};

/// The location of the bytes of a file or a directory: a sector index and a byte count.
pub const Extent = struct {
    lba: u32,
    length: u32,

    /// The extent's byte offset in the image.
    pub fn start(e: Extent) u64 {
        return @as(u64, e.lba) * sector_size;
    }
};

/// What a directory record tells the game: a logical component name, the extent that it
/// points at, and whether the extent is another directory.
pub const Entry = struct {
    name_buf: [platform.max_name_len]u8 = @splat(0),
    name_len: u8 = 0,
    extent: Extent,
    is_directory: bool,

    /// The upper-case logical component (`NESTED.DAT`); empty for the root directory.
    pub fn name(e: *const Entry) []const u8 {
        return e.name_buf[0..e.name_len];
    }
};

/// A parsed directory record; `identifier` borrows the caller's sector buffer.
const RawRecord = struct {
    length: u8,
    extent: Extent,
    flags: u8,
    identifier: []const u8,

    /// The two records every directory starts with, named by a single 0 or 1 byte.
    fn isSelfOrParent(r: RawRecord) bool {
        return r.identifier.len == 1 and (r.identifier[0] == 0 or r.identifier[0] == 1);
    }
};

/// Parses the record at the start of `bytes`, which runs to the end of its sector. A record
/// never crosses a sector boundary, so all of the record must fit inside `bytes`.
fn parseRecord(bytes: []const u8) platform.AssetError!RawRecord {
    const length = bytes[0];
    if (length < record_fixed_len or length > bytes.len) return error.Io;
    const record = bytes[0..length];
    const identifier_len = record[32];
    if (identifier_len == 0 or record_fixed_len + @as(usize, identifier_len) > length) return error.Io;
    const flags = record[25];
    // A file in several records would have to open as one asset, and the handle model cannot do
    // this. No game CD has such files.
    if (flags & flag_multi_extent != 0) return error.Io;
    // An extended attribute record fills the first blocks of the extent, and the data length
    // does not include it, so the file's bytes start after it.
    const attribute_blocks = record[1];
    const lba = std.math.add(u32, std.mem.readInt(u32, record[2..6], .little), attribute_blocks) catch return error.Io;
    return .{
        .length = length,
        .extent = .{ .lba = lba, .length = std.mem.readInt(u32, record[10..14], .little) },
        .flags = flags,
        .identifier = record[record_fixed_len..][0..identifier_len],
    };
}

/// The logical component that an ISO identifier names, upper-cased into `out`. Null when the
/// result is not a valid logical component: the game cannot name such an entry, so it is
/// invisible, not an error.
fn logicalName(identifier: []const u8, out: *[platform.max_name_len]u8) ?[]const u8 {
    var name = identifier;
    if (std.mem.lastIndexOfScalar(u8, name, ';')) |version| name = name[0..version];
    // A name without an extension is recorded as `README.`.
    if (name.len > 0 and name[name.len - 1] == '.') name = name[0 .. name.len - 1];
    if (name.len == 0 or name.len > out.len) return null;
    const canonical = platform.canonicalAssetName(name, out[0..name.len]);
    platform.validateName(canonical) catch return null;
    return canonical;
}

/// Reads bytes that the structure of the image says are present. A short read here means that
/// the image is truncated: it is malformed, not a temporary short read.
fn readStructure(source: ByteSource, offset: u64, dst: []u8) platform.AssetError!void {
    source.readExact(offset, dst) catch |err| switch (err) {
        error.ShortRead => return error.Io,
        else => |e| return e,
    };
}

/// One ISO 9660 volume: the root directory of the primary descriptor, over a byte source.
/// Nothing is cached and nothing is allocated; every lookup reads the sectors that it needs.
pub const Volume = struct {
    source: ByteSource,
    /// The image's length when the source knows it, read once at `init`.
    image_length: ?u64,
    root: Entry,

    /// Reads and checks the primary volume descriptor at sector 16.
    pub fn init(source: ByteSource) platform.AssetError!Volume {
        var sector: [sector_size]u8 = undefined;
        try readStructure(source, primary_descriptor_lba * sector_size, &sector);
        if (sector[0] != descriptor_primary) return error.Io;
        if (!std.mem.eql(u8, sector[1..6], descriptor_signature)) return error.Io;
        if (sector[6] != descriptor_version) return error.Io;
        // Every extent address in the image counts blocks of this size. Another size changes
        // the meaning of every address.
        if (std.mem.readInt(u16, sector[128..130], .little) != sector_size) return error.Io;
        var volume = Volume{ .source = source, .image_length = source.length(), .root = undefined };
        const record = try parseRecord(sector[156..190]);
        if (record.flags & flag_directory == 0) return error.Io;
        volume.root = .{ .extent = try volume.checkedExtent(record), .is_directory = true };
        return volume;
    }

    /// Walks `path` from the root, one ASCII case-insensitive component at a time. The shared
    /// name rules apply, so `../X` gives `error.InvalidName`.
    pub fn find(self: *const Volume, path: []const u8) platform.AssetError!Entry {
        try platform.validateAssetName(path);
        var current = self.root;
        var components = std.mem.splitScalar(u8, path, platform.asset_separator);
        while (components.next()) |component| {
            if (!current.is_directory) return error.NotFound;
            current = try self.findIn(current, component);
        }
        return current;
    }

    fn findIn(self: *const Volume, dir: Entry, component: []const u8) platform.AssetError!Entry {
        var records = try self.iterate(dir);
        while (try records.next()) |entry| {
            if (platform.assetNameEql(entry.name(), component)) return entry;
        }
        return error.NotFound;
    }

    /// The records of one directory, read a sector at a time.
    pub fn iterate(self: *const Volume, dir: Entry) platform.AssetError!Iterator {
        if (!dir.is_directory) return error.NotFound;
        if (dir.extent.length > max_directory_bytes) return error.Io;
        return .{ .volume = self, .extent = dir.extent };
    }

    /// Reads at most `dst.len` bytes of `extent` at `offset`, clamped to its length. Short reads
    /// and EOF follow the asset contract.
    pub fn readExtent(self: *const Volume, extent: Extent, offset: u64, dst: []u8) platform.AssetError!usize {
        if (offset >= extent.length) return 0;
        const n: usize = @intCast(@min(@as(u64, dst.len), extent.length - offset));
        if (n == 0) return 0;
        return self.source.readAt(extent.start() + offset, dst[0..n]);
    }

    /// Rejects an extent that overflows or runs past a known image length.
    fn checkedExtent(self: *const Volume, record: RawRecord) platform.AssetError!Extent {
        const start = std.math.mul(u64, record.extent.lba, sector_size) catch return error.Io;
        const end = std.math.add(u64, start, record.extent.length) catch return error.Io;
        if (self.image_length) |len| {
            if (end > len) return error.Io;
        }
        return record.extent;
    }

    /// The entry that a record names, or null when its identifier is not a logical component.
    /// The extent is checked first, so a malformed extent is reported even for an entry that the
    /// game never sees.
    fn entryFrom(self: *const Volume, record: RawRecord) platform.AssetError!?Entry {
        var entry = Entry{
            .extent = try self.checkedExtent(record),
            .is_directory = record.flags & flag_directory != 0,
        };
        const logical = logicalName(record.identifier, &entry.name_buf) orelse return null;
        entry.name_len = @intCast(logical.len);
        return entry;
    }
};

/// Walks one directory extent. It skips the self and parent records, and the entries whose
/// identifier is not a logical component. It buffers one sector at a time: a record never
/// crosses a sector boundary, so the parser needs no more. A nested listing thus costs one
/// buffer per level, not a copy of the image.
pub const Iterator = struct {
    volume: *const Volume,
    extent: Extent,
    offset: u32 = 0,
    /// The index of the sector held in `sector`, when one is loaded.
    loaded: ?u32 = null,
    sector: [sector_size]u8 = undefined,
    /// Valid bytes of the loaded sector; the extent's last one may be partial.
    valid: usize = 0,
    seen: u32 = 0,

    pub fn next(it: *Iterator) platform.AssetError!?Entry {
        while (it.offset < it.extent.length) {
            if (it.seen >= max_directory_records) return error.Io;
            const index: u32 = it.offset / sector_size;
            const within: usize = it.offset % sector_size;
            if (it.loaded == null or it.loaded.? != index) try it.load(index);
            // A zero length byte is padding: no further record follows in this sector.
            if (within >= it.valid or it.sector[within] == 0) {
                it.offset = (index + 1) * sector_size;
                continue;
            }
            const record = try parseRecord(it.sector[within..it.valid]);
            it.offset += record.length;
            it.seen += 1;
            if (record.isSelfOrParent()) continue;
            if (try it.volume.entryFrom(record)) |entry| return entry;
        }
        return null;
    }

    fn load(it: *Iterator, index: u32) platform.AssetError!void {
        const start = @as(u64, index) * sector_size;
        it.valid = @intCast(@min(@as(u64, sector_size), it.extent.length - start));
        try readStructure(it.volume.source, it.extent.start() + start, it.sector[0..it.valid]);
        it.loaded = index;
    }
};

/// The `AssetSource` contract over an ISO image, used when the game starts from a CD. A handle
/// names an extent, so a read is one range read and nothing is kept between calls. The source
/// must live longer than its bound interface and must not move, because handles and iterators
/// refer to it.
pub const IsoAssetSource = struct {
    allocator: std.mem.Allocator,
    volume: Volume,
    /// Open handles by slot. The handle is the slot index plus one, so zero is never a handle,
    /// and a closed handle is invalid until its slot is used again.
    handles: std.ArrayList(?Extent) = .empty,

    pub fn init(allocator: std.mem.Allocator, source: ByteSource) platform.AssetError!IsoAssetSource {
        return .{ .allocator = allocator, .volume = try Volume.init(source) };
    }

    pub fn deinit(self: *IsoAssetSource) void {
        self.handles.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn openHandles(self: *const IsoAssetSource) usize {
        var n: usize = 0;
        for (self.handles.items) |slot| {
            if (slot != null) n += 1;
        }
        return n;
    }

    pub fn assetSource(self: *IsoAssetSource) platform.AssetSource {
        return .{ .context = self, .vtable = &vtable, .allocator = self.allocator };
    }

    const vtable = platform.AssetSource.VTable{
        .open = openAsset,
        .read_at = readAt,
        .list = list,
        .close = close,
    };

    fn cast(ctx: *anyopaque) *IsoAssetSource {
        return @ptrCast(@alignCast(ctx));
    }

    fn openAsset(ctx: *anyopaque, path: []const u8) platform.AssetError!platform.OpenedAsset {
        const self = cast(ctx);
        const entry = try self.volume.find(path);
        // A directory is not an asset.
        if (entry.is_directory) return error.NotFound;
        const slot = try self.allocateSlot();
        self.handles.items[slot] = entry.extent;
        return .{ .handle = @fromBackingInt(@as(u32, @intCast(slot + 1))), .length = entry.extent.length };
    }

    fn allocateSlot(self: *IsoAssetSource) platform.AssetError!usize {
        for (self.handles.items, 0..) |slot, i| {
            if (slot == null) return i;
        }
        self.handles.append(self.allocator, null) catch return error.OutOfMemory;
        return self.handles.items.len - 1;
    }

    fn readAt(ctx: *anyopaque, file: platform.AssetHandle, offset: u64, dst: []u8) platform.AssetError!usize {
        const self = cast(ctx);
        const extent = self.lookup(file) orelse return error.InvalidHandle;
        return self.volume.readExtent(extent, offset, dst);
    }

    fn lookup(self: *const IsoAssetSource, file: platform.AssetHandle) ?Extent {
        const raw = @backingInt(file);
        if (raw == 0 or raw > self.handles.items.len) return null;
        return self.handles.items[raw - 1];
    }

    fn close(ctx: *anyopaque, file: platform.AssetHandle) void {
        const self = cast(ctx);
        const raw = @backingInt(file);
        if (raw == 0 or raw > self.handles.items.len) return;
        self.handles.items[raw - 1] = null;
    }

    fn list(ctx: *anyopaque, prefix: []const u8) platform.AssetError!platform.OwnedAssetEntries {
        const self = cast(ctx);
        var names: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (names.items) |n| self.allocator.free(n);
            names.deinit(self.allocator);
        }
        var logical: [platform.max_asset_name_len]u8 = undefined;
        try self.walk(self.volume.root, &logical, 0, 1, prefix, &names);
        std.mem.sort([]const u8, names.items, {}, platform.assetNameLessThan);
        const slice = names.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
        return .{ .names = slice, .allocator = self.allocator };
    }

    /// Appends the canonical logical names under `dir` (whose logical prefix is
    /// `logical[0..used]`) that match `prefix`. The depth limit makes the recursion safe. A
    /// deeper name is not a valid logical name, and a directory record that points at one of
    /// its own ancestors cannot make the walk loop without end.
    fn walk(
        self: *IsoAssetSource,
        dir: Entry,
        logical: *[platform.max_asset_name_len]u8,
        used: usize,
        depth: usize,
        prefix: []const u8,
        names: *std.ArrayList([]const u8),
    ) platform.AssetError!void {
        var records = try self.volume.iterate(dir);
        while (try records.next()) |entry| {
            const component = entry.name();
            if (used + component.len > logical.len) continue;
            @memcpy(logical[used..][0..component.len], component);
            const full = logical[0 .. used + component.len];
            if (entry.is_directory) {
                if (depth >= platform.max_asset_depth or full.len + 1 >= logical.len) continue;
                logical[full.len] = platform.asset_separator;
                // The sub-walk overwrites `logical` after the separator; the entry's name is not
                // needed after it.
                try self.walk(entry, logical, full.len + 1, depth + 1, prefix, names);
                continue;
            }
            if (!platform.assetNameStartsWith(full, prefix)) continue;
            const copy = self.allocator.dupe(u8, full) catch return error.OutOfMemory;
            names.append(self.allocator, copy) catch {
                self.allocator.free(copy);
                return error.OutOfMemory;
            };
        }
    }
};

/// Test support: one file of a `buildTestImage` image, at most one directory deep.
pub const TestFile = struct {
    path: []const u8,
    bytes: []const u8,
};

pub const BuildError = error{ OutOfMemory, InvalidName, TooManyDirectories, TooDeep };

/// The directories one test image may hold, the root included.
const max_test_directories = 8;
/// The first sector after the primary descriptor and the terminator.
const test_root_lba = 18;

/// Test support: builds a minimal ISO 9660 image of `files`, so that the reader and the
/// provider contract can run without a real CD. The image holds a primary volume descriptor at
/// sector 16, a terminator, a root directory extent, one extent for each subdirectory and one
/// for each file, with `;1` on every file name. It has no path tables and no supplementary
/// descriptors, because this reader does not read them. The records are in the given order,
/// not sorted; the reader does not need them sorted.
pub fn buildTestImage(allocator: std.mem.Allocator, files: []const TestFile) BuildError![]u8 {
    var directories: [max_test_directories][]const u8 = @splat("");
    var directory_count: usize = 1; // the root
    const placed = try allocator.alloc(PlacedFile, files.len);
    defer allocator.free(placed);
    for (files, placed) |file, *info| {
        try platform.validateAssetName(file.path);
        var components = std.mem.splitScalar(u8, file.path, platform.asset_separator);
        const first = components.next().?;
        if (components.next()) |leaf| {
            if (components.next() != null) return error.TooDeep;
            const index = try directoryIndex(&directories, &directory_count, first);
            info.* = .{ .directory = index, .name = leaf, .bytes = file.bytes, .lba = 0 };
        } else {
            info.* = .{ .directory = 0, .name = first, .bytes = file.bytes, .lba = 0 };
        }
    }

    // Measure every directory before any write. A record holds the address and the size of
    // its target, so all of them must be known before the first record is written.
    var extents: [max_test_directories]Extent = @splat(.{ .lba = 0, .length = 0 });
    for (0..directory_count) |index| {
        var sink = RecordSink{ .image = null, .base = 0 };
        emitDirectory(&sink, index, directories[0..directory_count], placed, &extents);
        extents[index].length = @intCast(sink.finish());
    }
    var next_lba: u32 = test_root_lba;
    for (0..directory_count) |index| {
        extents[index].lba = next_lba;
        next_lba += @intCast(extents[index].length / sector_size);
    }
    for (placed) |*info| {
        info.lba = next_lba;
        next_lba += @intCast((info.bytes.len + sector_size - 1) / sector_size);
    }

    const image = try allocator.alloc(u8, @as(usize, next_lba) * sector_size);
    @memset(image, 0);
    writeDescriptors(image, next_lba, extents[0]);
    for (0..directory_count) |index| {
        var sink = RecordSink{ .image = image, .base = @as(usize, extents[index].lba) * sector_size };
        emitDirectory(&sink, index, directories[0..directory_count], placed, &extents);
    }
    for (placed) |info| {
        const at = @as(usize, info.lba) * sector_size;
        @memcpy(image[at..][0..info.bytes.len], info.bytes);
    }
    return image;
}

const PlacedFile = struct {
    directory: u8,
    name: []const u8,
    bytes: []const u8,
    lba: u32,
};

fn directoryIndex(directories: *[max_test_directories][]const u8, count: *usize, name: []const u8) BuildError!u8 {
    for (directories[1..count.*], 1..) |existing, index| {
        if (platform.assetNameEql(existing, name)) return @intCast(index);
    }
    if (count.* == max_test_directories) return error.TooManyDirectories;
    directories[count.*] = name;
    count.* += 1;
    return @intCast(count.* - 1);
}

/// Packs directory records into an extent. A record never crosses a sector boundary: zero
/// padding moves a record that does not fit to the next sector. With `image` null only the size
/// is measured, so the addresses are known before anything is written.
const RecordSink = struct {
    image: ?[]u8,
    base: usize,
    pos: usize = 0,

    fn add(self: *RecordSink, identifier: []const u8, extent: Extent, is_directory: bool) void {
        const length = recordLength(identifier.len);
        if (self.pos % sector_size + length > sector_size) {
            self.pos = (self.pos / sector_size + 1) * sector_size;
        }
        if (self.image) |image| {
            writeRecord(image[self.base + self.pos ..][0..length], identifier, extent, is_directory);
        }
        self.pos += length;
    }

    /// The extent's size in whole sectors. The end of the last sector is padding.
    fn finish(self: *const RecordSink) usize {
        return (self.pos + sector_size - 1) / sector_size * sector_size;
    }
};

fn recordLength(identifier_len: usize) usize {
    const length = record_fixed_len + identifier_len;
    // A padding byte after an even-length identifier keeps every record's length even.
    return length + (length & 1);
}

fn emitDirectory(
    sink: *RecordSink,
    index: usize,
    directories: []const []const u8,
    placed: []const PlacedFile,
    extents: *const [max_test_directories]Extent,
) void {
    sink.add(&[_]u8{0}, extents[index], true);
    // Every subdirectory's parent is the root, and the root is its own parent.
    sink.add(&[_]u8{1}, extents[0], true);
    if (index == 0) {
        for (directories[1..], 1..) |name, subdirectory| sink.add(name, extents[subdirectory], true);
    }
    var identifier: [platform.max_name_len + 2]u8 = undefined;
    for (placed) |info| {
        if (info.directory != index) continue;
        @memcpy(identifier[0..info.name.len], info.name);
        @memcpy(identifier[info.name.len..][0..2], ";1");
        const extent = Extent{ .lba = info.lba, .length = @intCast(info.bytes.len) };
        sink.add(identifier[0 .. info.name.len + 2], extent, false);
    }
}

fn writeRecord(dst: []u8, identifier: []const u8, extent: Extent, is_directory: bool) void {
    @memset(dst, 0);
    dst[0] = @intCast(dst.len);
    writeBoth32(dst[2..][0..8], extent.lba);
    writeBoth32(dst[10..][0..8], extent.length);
    // The recording date and time stay zero: the reader ignores them.
    dst[25] = if (is_directory) flag_directory else 0;
    writeBoth16(dst[28..][0..4], 1);
    dst[32] = @intCast(identifier.len);
    @memcpy(dst[record_fixed_len..][0..identifier.len], identifier);
}

fn writeDescriptors(image: []u8, total_sectors: u32, root: Extent) void {
    const pvd = image[primary_descriptor_lba * sector_size ..][0..sector_size];
    // Character fields are blank-padded; only the fields that the reader uses have values.
    @memset(pvd[8..72], ' ');
    @memset(pvd[190..813], ' ');
    pvd[0] = descriptor_primary;
    @memcpy(pvd[1..6], descriptor_signature);
    pvd[6] = descriptor_version;
    @memcpy(pvd[40..51], "TEST_VOLUME");
    writeBoth32(pvd[80..][0..8], total_sectors);
    writeBoth16(pvd[120..][0..4], 1);
    writeBoth16(pvd[124..][0..4], 1);
    writeBoth16(pvd[128..][0..4], sector_size);
    writeRecord(pvd[156..][0..34], &[_]u8{0}, root, true);
    pvd[881] = 1; // file structure version
    const terminator = image[17 * sector_size ..][0..sector_size];
    terminator[0] = descriptor_terminator;
    @memcpy(terminator[1..6], descriptor_signature);
    terminator[6] = descriptor_version;
}

/// ISO 9660 records its numbers twice, little-endian then big-endian.
fn writeBoth32(dst: *[8]u8, value: u32) void {
    std.mem.writeInt(u32, dst[0..4], value, .little);
    std.mem.writeInt(u32, dst[4..8], value, .big);
}

fn writeBoth16(dst: *[4]u8, value: u16) void {
    std.mem.writeInt(u16, dst[0..2], value, .little);
    std.mem.writeInt(u16, dst[2..4], value, .big);
}

const testing = std.testing;

/// The test files: an empty file, one shorter than a sector, one longer than a sector with a
/// length that is not a multiple of the sector size, and one in a subdirectory.
const test_blob = "0123456789abcdef";
const test_config = "VIDEO=VGA\r\nSOUND=SB16\r\n";
const test_nested_len = 3000;

fn nestedBytes(buf: *[test_nested_len]u8) []u8 {
    for (buf, 0..) |*b, i| b.* = @truncate(i * 7 + 3);
    return buf;
}

fn buildFixtureImage(allocator: std.mem.Allocator, nested: []const u8) ![]u8 {
    return buildTestImage(allocator, &.{
        .{ .path = "BLOB.BIN", .bytes = test_blob },
        .{ .path = "EMPTY.BIN", .bytes = "" },
        .{ .path = "GAME.CFG", .bytes = test_config },
        .{ .path = "SUB/NESTED.DAT", .bytes = nested },
    });
}

/// Test support: the offset in `image` of the record with this identifier, in one directory
/// extent. A test needs this address to corrupt a named record.
fn recordOffset(image: []const u8, directory: Extent, identifier: []const u8) ?usize {
    const start: usize = @intCast(directory.start());
    const length: usize = directory.length;
    var at: usize = 0;
    while (at + record_fixed_len <= length) {
        const record_len = image[start + at];
        if (record_len == 0) {
            at = (at / sector_size + 1) * sector_size;
            continue;
        }
        const name_len = image[start + at + 32];
        if (std.mem.eql(u8, image[start + at + record_fixed_len ..][0..name_len], identifier)) return start + at;
        at += record_len;
    }
    return null;
}

/// Expects the image to be refused when it is opened or at the first listing, without a leak.
fn expectMalformed(image: []const u8) !void {
    var bytes = MemoryByteSource.init(image);
    var source = IsoAssetSource.init(testing.allocator, bytes.byteSource()) catch |err| {
        if (err != error.Io) return err;
        return;
    };
    defer source.deinit();
    var names = source.assetSource().list("") catch |err| {
        if (err != error.Io) return err;
        return;
    };
    names.deinit();
    return error.MalformedImageAccepted;
}

test "the primary descriptor names a root whose records carry logical names" {
    var pattern: [test_nested_len]u8 = undefined;
    const image = try buildFixtureImage(testing.allocator, nestedBytes(&pattern));
    defer testing.allocator.free(image);
    var bytes = MemoryByteSource.init(image);
    const volume = try Volume.init(bytes.byteSource());
    try testing.expect(volume.root.is_directory);
    try testing.expectEqual(@as(usize, 0), volume.root.name().len);

    var records = try volume.iterate(volume.root);
    // The subdirectory comes first, then the files; the self and parent records are skipped.
    const sub = (try records.next()).?;
    try testing.expectEqualStrings("SUB", sub.name());
    try testing.expect(sub.is_directory);
    const blob = (try records.next()).?;
    try testing.expectEqualStrings("BLOB.BIN", blob.name()); // the `;1` version suffix is gone
    try testing.expect(!blob.is_directory);
    try testing.expectEqual(@as(u32, test_blob.len), blob.extent.length);
    try testing.expectEqualStrings("EMPTY.BIN", (try records.next()).?.name());
    try testing.expectEqualStrings("GAME.CFG", (try records.next()).?.name());
    try testing.expect((try records.next()) == null);

    // The subdirectory holds only its one file.
    var nested = try volume.iterate(sub);
    try testing.expectEqualStrings("NESTED.DAT", (try nested.next()).?.name());
    try testing.expect((try nested.next()) == null);

    // A file cannot be walked into or enumerated.
    try testing.expectError(error.NotFound, volume.iterate(blob));
    try testing.expectError(error.NotFound, volume.find("BLOB.BIN/X"));
}

test "opening and reading a file follows the asset contract" {
    var pattern: [test_nested_len]u8 = undefined;
    const nested = nestedBytes(&pattern);
    const image = try buildFixtureImage(testing.allocator, nested);
    defer testing.allocator.free(image);
    var bytes = MemoryByteSource.init(image);
    var source = try IsoAssetSource.init(testing.allocator, bytes.byteSource());
    defer source.deinit();
    const a = source.assetSource();

    // DOS matching: any case opens the entry.
    const blob = try a.open("blob.bin");
    try testing.expectEqual(@as(u64, test_blob.len), blob.length);
    var buf: [8]u8 = undefined;
    try testing.expectEqual(@as(usize, 4), try a.readAt(blob.handle, 0, buf[0..4]));
    try testing.expectEqualStrings("0123", buf[0..4]);
    try testing.expectEqual(@as(usize, 2), try a.readAt(blob.handle, 14, &buf));
    try testing.expectEqualStrings("ef", buf[0..2]);
    try testing.expectEqual(@as(usize, 0), try a.readAt(blob.handle, 16, &buf));
    try testing.expectEqual(@as(usize, 0), try a.readAt(blob.handle, 1 << 40, &buf));
    try testing.expectEqual(@as(usize, 0), try a.readAt(blob.handle, 0, buf[0..0]));
    a.close(blob.handle);

    const empty = try a.open("EMPTY.BIN");
    try testing.expectEqual(@as(u64, 0), empty.length);
    try testing.expectEqual(@as(usize, 0), try a.readAt(empty.handle, 0, &buf));
    a.close(empty.handle);
    const config = try a.open("GAME.CFG");
    try testing.expectEqual(@as(u64, test_config.len), config.length);
    a.close(config.handle);

    // A file longer than a sector: read across the boundary and at the end.
    const big = try a.open("SUB/NESTED.DAT");
    try testing.expectEqual(@as(u64, test_nested_len), big.length);
    var span: [16]u8 = undefined;
    try testing.expectEqual(@as(usize, 16), try a.readAt(big.handle, 2040, &span));
    try testing.expectEqualSlices(u8, nested[2040..2056], &span);
    try testing.expectEqual(@as(usize, 8), try a.readAt(big.handle, test_nested_len - 8, &span));
    try testing.expectEqualSlices(u8, nested[test_nested_len - 8 ..], span[0..8]);
    a.close(big.handle);
    try testing.expectEqual(@as(usize, 0), source.openHandles());

    // A directory is not an asset, and components are part of the name.
    try testing.expectError(error.NotFound, a.open("SUB"));
    try testing.expectError(error.NotFound, a.open("NESTED.DAT"));
    try testing.expectError(error.NotFound, a.open("MISSING.BIN"));
    try testing.expectError(error.NotFound, a.open("SUB/MISSING.DAT"));
    try testing.expectError(error.InvalidName, a.open(""));
    try testing.expectError(error.InvalidName, a.open("../GAME.EXE"));
    try testing.expectError(error.InvalidName, a.open("SUB/"));
    try testing.expectError(error.InvalidName, a.open("/BLOB.BIN"));
}

test "read_all loops over short byte-source reads and refuses a file past the limit" {
    var pattern: [test_nested_len]u8 = undefined;
    const nested = nestedBytes(&pattern);
    const image = try buildFixtureImage(testing.allocator, nested);
    defer testing.allocator.free(image);
    var bytes = MemoryByteSource.init(image);
    // Every read is short, so both the descriptor loads and `read_all` must read again.
    bytes.max_read = 7;
    var source = try IsoAssetSource.init(testing.allocator, bytes.byteSource());
    defer source.deinit();
    const a = source.assetSource();

    var got = try a.readAll("sub/nested.dat", 1 << 20);
    defer got.deinit();
    try testing.expectEqualSlices(u8, nested, got.bytes);
    var empty = try a.readAll("EMPTY.BIN", 0);
    defer empty.deinit();
    try testing.expectEqual(@as(usize, 0), empty.bytes.len);
    try testing.expectError(error.TooLarge, a.readAll("BLOB.BIN", test_blob.len - 1));
    try testing.expectError(error.NotFound, a.readAll("MISSING.BIN", 16));
    try testing.expectEqual(@as(usize, 0), source.openHandles());
}

test "handles are independent and invalid once closed" {
    var pattern: [test_nested_len]u8 = undefined;
    const image = try buildFixtureImage(testing.allocator, nestedBytes(&pattern));
    defer testing.allocator.free(image);
    var bytes = MemoryByteSource.init(image);
    var source = try IsoAssetSource.init(testing.allocator, bytes.byteSource());
    defer source.deinit();
    const a = source.assetSource();

    const first = try a.open("BLOB.BIN");
    const second = try a.open("GAME.CFG");
    try testing.expectEqual(@as(usize, 2), source.openHandles());
    a.close(first.handle);
    var buf: [2]u8 = undefined;
    try testing.expectError(error.InvalidHandle, a.readAt(first.handle, 0, &buf));
    try testing.expectEqual(@as(usize, 2), try a.readAt(second.handle, 0, &buf));
    try testing.expectEqualStrings(test_config[0..2], &buf);
    a.close(first.handle); // closing twice is harmless
    // The free slot is used again: the new handle has the same value as the closed one.
    const third = try a.open("BLOB.BIN");
    try testing.expectEqual(first.handle, third.handle);
    a.close(third.handle);
    a.close(second.handle);
    try testing.expectError(error.InvalidHandle, a.readAt(@fromBackingInt(0), 0, &buf));
    try testing.expectError(error.InvalidHandle, a.readAt(@fromBackingInt(0xffff), 0, &buf));
    try testing.expectEqual(@as(usize, 0), source.openHandles());
}

test "listings are canonical, sorted, owned and matched by prefix" {
    var pattern: [test_nested_len]u8 = undefined;
    const image = try buildFixtureImage(testing.allocator, nestedBytes(&pattern));
    defer testing.allocator.free(image);
    var bytes = MemoryByteSource.init(image);
    var source = try IsoAssetSource.init(testing.allocator, bytes.byteSource());
    defer source.deinit();
    const a = source.assetSource();

    var all = try a.list("");
    defer all.deinit();
    const expected = [_][]const u8{ "BLOB.BIN", "EMPTY.BIN", "GAME.CFG", "SUB/NESTED.DAT" };
    try testing.expectEqual(expected.len, all.names.len);
    for (expected, all.names) |want, got| try testing.expectEqualStrings(want, got);

    var subdirectory = try a.list("sub/");
    defer subdirectory.deinit();
    try testing.expectEqual(@as(usize, 1), subdirectory.names.len);
    try testing.expectEqualStrings("SUB/NESTED.DAT", subdirectory.names[0]);
    var none = try a.list("ZZZ");
    defer none.deinit();
    try testing.expectEqual(@as(usize, 0), none.names.len);

    // The owned listing stays valid after later provider calls.
    const opened = try a.open("BLOB.BIN");
    a.close(opened.handle);
    try testing.expectEqualStrings("BLOB.BIN", all.names[0]);
}

test "a directory extent spanning two sectors finds the records after the padding" {
    // Twenty-four records of 100 bytes each do not fit in one sector. The first sector ends
    // with padding, and the reader must skip to the next sector.
    var names: [24][platform.max_name_len]u8 = undefined;
    var files: [24]TestFile = undefined;
    for (&names, &files, 0..) |*name, *file, index| {
        name.* = @splat('A');
        name[0] = 'F';
        name[1] = '0' + @as(u8, @intCast(index / 10));
        name[2] = '0' + @as(u8, @intCast(index % 10));
        @memcpy(name[60..64], ".DAT");
        file.* = .{ .path = name, .bytes = "x" };
    }
    const image = try buildTestImage(testing.allocator, &files);
    defer testing.allocator.free(image);
    var bytes = MemoryByteSource.init(image);
    var source = try IsoAssetSource.init(testing.allocator, bytes.byteSource());
    defer source.deinit();
    try testing.expectEqual(@as(u32, 2 * sector_size), source.volume.root.extent.length);

    var all = try source.assetSource().list("");
    defer all.deinit();
    try testing.expectEqual(@as(usize, 24), all.names.len);
    for (&names, all.names) |want, got| try testing.expectEqualStrings(&want, got);
}

test "an identifier that is not a logical component is invisible" {
    var pattern: [test_nested_len]u8 = undefined;
    const image = try buildFixtureImage(testing.allocator, nestedBytes(&pattern));
    defer testing.allocator.free(image);
    var bytes = MemoryByteSource.init(image);
    const root = (try Volume.init(bytes.byteSource())).root.extent;
    // `GAME.CFG;1` becomes `gamecfg.;1`: lower case, and an extension-less name's trailing
    // dot, in an identifier of the same length.
    const config = recordOffset(image, root, "GAME.CFG;1").?;
    @memcpy(image[config + record_fixed_len ..][0..10], "gamecfg.;1");
    // `EMPTY.BIN;1` gets a space, which the shared name rules reject.
    const empty = recordOffset(image, root, "EMPTY.BIN;1").?;
    image[empty + record_fixed_len + 5] = ' ';

    var source = try IsoAssetSource.init(testing.allocator, bytes.byteSource());
    defer source.deinit();
    const a = source.assetSource();
    var all = try a.list("");
    defer all.deinit();
    const expected = [_][]const u8{ "BLOB.BIN", "GAMECFG", "SUB/NESTED.DAT" };
    try testing.expectEqual(expected.len, all.names.len);
    for (expected, all.names) |want, got| try testing.expectEqualStrings(want, got);
    const opened = try a.open("gamecfg");
    try testing.expectEqual(@as(u64, test_config.len), opened.length);
    a.close(opened.handle);
    try testing.expectError(error.NotFound, a.open("EMPTY.BIN"));
}

test "a malformed image is rejected rather than parsed" {
    var pattern: [test_nested_len]u8 = undefined;
    const good = try buildFixtureImage(testing.allocator, nestedBytes(&pattern));
    defer testing.allocator.free(good);
    var probe = MemoryByteSource.init(good);
    const root = (try Volume.init(probe.byteSource())).root.extent;
    const blob = recordOffset(good, root, "BLOB.BIN;1").?;
    const pvd = primary_descriptor_lba * sector_size;

    // A truncated image: the descriptor is missing, or only partly present.
    try expectMalformed(good[0 .. 8 * sector_size]);
    try expectMalformed(good[0 .. pvd + 100]);

    const Corruption = struct { at: usize, value: u8 };
    for ([_]Corruption{
        .{ .at = pvd, .value = 0x02 }, // not the primary descriptor
        .{ .at = pvd + 1, .value = 'X' }, // not CD001
        .{ .at = pvd + 6, .value = 2 }, // a descriptor version this reader does not know
        .{ .at = pvd + 156 + 25, .value = 0 }, // a root that is not a directory
        .{ .at = blob, .value = record_fixed_len - 1 }, // a record shorter than its fixed part
        .{ .at = blob + 32, .value = 0 }, // an empty identifier
        .{ .at = blob + 32, .value = 200 }, // an identifier running past the record
        .{ .at = blob + 25, .value = flag_multi_extent }, // a file this reader cannot open
    }) |corruption| {
        const bad = try testing.allocator.dupe(u8, good);
        defer testing.allocator.free(bad);
        bad[corruption.at] = corruption.value;
        try expectMalformed(bad);
    }

    {
        // A logical block size other than 2048 would change what every address means.
        const bad = try testing.allocator.dupe(u8, good);
        defer testing.allocator.free(bad);
        writeBoth16(bad[pvd + 128 ..][0..4], 512);
        try expectMalformed(bad);
    }
    {
        // A root extent ending in the middle of its second record.
        const bad = try testing.allocator.dupe(u8, good);
        defer testing.allocator.free(bad);
        writeBoth32(bad[pvd + 156 + 10 ..][0..8], 40);
        try expectMalformed(bad);
    }
    {
        // An extent longer than the image, then one starting past its end.
        const bad = try testing.allocator.dupe(u8, good);
        defer testing.allocator.free(bad);
        writeBoth32(bad[blob + 10 ..][0..8], 0x0f00_0000);
        try expectMalformed(bad);
        @memcpy(bad, good);
        writeBoth32(bad[blob + 2 ..][0..8], 0xffff_0000);
        try expectMalformed(bad);
    }
}

test "a directory larger than the sanity bound is rejected" {
    const big = try testing.allocator.alloc(u8, max_directory_bytes + sector_size);
    defer testing.allocator.free(big);
    @memset(big, 0);
    const image = try buildTestImage(testing.allocator, &.{.{ .path = "BIG.BIN", .bytes = big }});
    defer testing.allocator.free(image);
    // The root claims more directory bytes than any real image holds. The bytes are present,
    // so only the reader's own limit refuses them.
    writeBoth32(image[primary_descriptor_lba * sector_size + 156 + 10 ..][0..8], max_directory_bytes + sector_size);
    try expectMalformed(image);
}

test "a directory pointing at its own ancestor is bounded by the asset depth" {
    var pattern: [test_nested_len]u8 = undefined;
    const image = try buildFixtureImage(testing.allocator, nestedBytes(&pattern));
    defer testing.allocator.free(image);
    var bytes = MemoryByteSource.init(image);
    const root = (try Volume.init(bytes.byteSource())).root.extent;
    // SUB now points at the root, so the tree it describes is infinite.
    const sub = recordOffset(image, root, "SUB").?;
    writeBoth32(image[sub + 2 ..][0..8], root.lba);
    writeBoth32(image[sub + 10 ..][0..8], root.length);

    var source = try IsoAssetSource.init(testing.allocator, bytes.byteSource());
    defer source.deinit();
    var all = try source.assetSource().list("");
    defer all.deinit();
    // The three root files at each of the eight depths a logical name may have, and no more.
    try testing.expectEqual(@as(usize, 3 * platform.max_asset_depth), all.names.len);
    for (all.names) |name| try platform.validateAssetName(name);
}

fn readerUnderAllocator(allocator: std.mem.Allocator, image: []const u8) !void {
    var bytes = MemoryByteSource.init(image);
    var source = try IsoAssetSource.init(allocator, bytes.byteSource());
    defer source.deinit();
    const a = source.assetSource();
    var got = try a.readAll("SUB/NESTED.DAT", 1 << 20);
    defer got.deinit();
    var all = try a.list("");
    defer all.deinit();
    const opened = try a.open("BLOB.BIN");
    defer a.close(opened.handle);
    var buf: [4]u8 = undefined;
    _ = try a.readAt(opened.handle, 0, &buf);
}

fn builderUnderAllocator(allocator: std.mem.Allocator) !void {
    const image = try buildTestImage(allocator, &.{
        .{ .path = "BLOB.BIN", .bytes = test_blob },
        .{ .path = "SUB/NESTED.DAT", .bytes = test_config },
    });
    allocator.free(image);
}

test "the reader and the image builder survive every allocation failure without leaking" {
    var pattern: [test_nested_len]u8 = undefined;
    const image = try buildFixtureImage(testing.allocator, nestedBytes(&pattern));
    defer testing.allocator.free(image);
    try testing.checkAllAllocationFailures(testing.allocator, readerUnderAllocator, .{image});
    try testing.checkAllAllocationFailures(testing.allocator, builderUnderAllocator, .{});
}

test "the image builder refuses names the shared rules reject" {
    try testing.expectError(error.InvalidName, buildTestImage(testing.allocator, &.{.{ .path = "../X", .bytes = "" }}));
    try testing.expectError(error.TooDeep, buildTestImage(testing.allocator, &.{.{ .path = "A/B/C", .bytes = "" }}));
}
