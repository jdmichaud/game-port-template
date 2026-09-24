//! The probe of `zig build web-check`: the operations for which the browser module imports a
//! helper, here `__multi3`. The build makes it twice, with compiler-rt and without, and
//! `helpers_check.cjs` runs both over the same inputs, the second with the helpers of
//! `gameport.js`. A port whose module imports another helper adds its operation here.

/// Where a 128-bit result goes, low half first.
var result: [2]u64 = .{ 0, 0 };

export fn probe_result() *[2]u64 {
    return &result;
}

export fn probe_mul(a_lo: u64, a_hi: u64, b_lo: u64, b_hi: u64) void {
    put(join(a_lo, a_hi) *% join(b_lo, b_hi));
}

fn join(lo: u64, hi: u64) u128 {
    return @as(u128, hi) << 64 | lo;
}

fn put(value: u128) void {
    result = .{ @truncate(value), @truncate(value >> 64) };
}
