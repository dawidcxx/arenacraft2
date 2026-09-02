const std = @import("std");

const HmacSha1 = std.crypto.auth.hmac.HmacSha1;
const Sha1 = std.crypto.hash.Sha1;

const server_encryption_key = [_]u8{ 0xCC, 0x98, 0xAE, 0x04, 0xE8, 0x97, 0xEA, 0xCA, 0x12, 0xDD, 0xC0, 0x93, 0x42, 0x91, 0x53, 0x57 };
const server_decryption_key = [_]u8{ 0xC2, 0xB3, 0x72, 0x3C, 0xC6, 0xAE, 0xD9, 0xB5, 0x34, 0x3C, 0x53, 0xEE, 0x2F, 0x43, 0x67, 0xCE };

pub const session_key_len: usize = 40;

pub const AuthCrypt = struct {
    server_encrypt: Rc4,
    client_decrypt: Rc4,

    pub fn init(session_key: [session_key_len]u8) AuthCrypt {
        var k = session_key;
        defer @memset(&k, 0);

        var server_seed = deriveServerSeed(k);
        var client_seed = deriveClientSeed(k);
        defer @memset(&server_seed, 0);
        defer @memset(&client_seed, 0);

        var crypt = AuthCrypt{
            .server_encrypt = Rc4.init(&server_seed),
            .client_decrypt = Rc4.init(&client_seed),
        };

        var sync = [_]u8{0} ** 1024;
        crypt.server_encrypt.update(&sync);
        @memset(&sync, 0);
        crypt.client_decrypt.update(&sync);

        return crypt;
    }

    pub fn deinit(self: *AuthCrypt) void {
        self.server_encrypt.deinit();
        self.client_decrypt.deinit();
    }
};

pub fn computeWorldAuthDigest(
    account: []const u8,
    client_seed: [4]u8,
    server_seed: [4]u8,
    session_key: [session_key_len]u8,
) [Sha1.digest_length]u8 {
    const zero = [_]u8{0} ** 4;
    var sha = Sha1.init(.{});
    sha.update(account);
    sha.update(&zero);
    sha.update(&client_seed);
    sha.update(&server_seed);
    sha.update(&session_key);

    var out: [Sha1.digest_length]u8 = undefined;
    sha.final(&out);
    return out;
}

fn deriveServerSeed(session_key: [session_key_len]u8) [HmacSha1.mac_length]u8 {
    var out: [HmacSha1.mac_length]u8 = undefined;
    HmacSha1.create(&out, &session_key, &server_encryption_key);
    return out;
}

fn deriveClientSeed(session_key: [session_key_len]u8) [HmacSha1.mac_length]u8 {
    var out: [HmacSha1.mac_length]u8 = undefined;
    HmacSha1.create(&out, &session_key, &server_decryption_key);
    return out;
}

pub const Rc4 = struct {
    s: [256]u8,
    i: u8,
    j: u8,

    pub fn init(key: []const u8) Rc4 {
        std.debug.assert(key.len > 0);

        var rc4 = Rc4{
            .s = undefined,
            .i = 0,
            .j = 0,
        };

        for (&rc4.s, 0..) |*slot, idx| {
            slot.* = @intCast(idx);
        }

        var j: u8 = 0;
        var idx: usize = 0;
        while (idx < rc4.s.len) : (idx += 1) {
            j +%= rc4.s[idx];
            j +%= key[idx % key.len];
            swap(&rc4.s[idx], &rc4.s[@intCast(j)]);
        }

        return rc4;
    }

    pub fn deinit(self: *Rc4) void {
        @memset(&self.s, 0);
        self.i = 0;
        self.j = 0;
    }

    pub fn update(self: *Rc4, data: []u8) void {
        for (data) |*byte| {
            self.i +%= 1;
            self.j +%= self.s[@intCast(self.i)];

            swap(&self.s[@intCast(self.i)], &self.s[@intCast(self.j)]);

            const key_index = self.s[@intCast(self.i)] +% self.s[@intCast(self.j)];
            byte.* ^= self.s[@intCast(key_index)];
        }
    }
};

fn swap(a: *u8, b: *u8) void {
    const tmp = a.*;
    a.* = b.*;
    b.* = tmp;
}

test "rc4 known vector" {
    const t = std.testing;
    var rc4 = Rc4.init("Key");
    var text = [_]u8{ 'P', 'l', 'a', 'i', 'n', 't', 'e', 'x', 't' };
    rc4.update(&text);

    try t.expectEqualSlices(u8, &.{ 0xBB, 0xF3, 0x16, 0xE8, 0xD9, 0x40, 0xAF, 0x0A, 0xD3 }, &text);
}

test "world auth digest is stable" {
    const t = std.testing;
    const k = [_]u8{0x11} ** session_key_len;
    const digest = computeWorldAuthDigest("ADMIN", .{ 1, 2, 3, 4 }, .{ 5, 6, 7, 8 }, k);

    try t.expectEqualSlices(u8, &.{
        0x22, 0x42, 0x78, 0xAA, 0xF7, 0x4E, 0x99, 0xAC, 0x52, 0x41,
        0xC7, 0x64, 0xC0, 0x93, 0x28, 0x4C, 0x94, 0xBB, 0x46, 0x87,
    }, &digest);
}

test "auth crypt server receive stream decrypts client stream" {
    const t = std.testing;
    const k = [_]u8{0x22} ** session_key_len;

    var seed = deriveClientSeed(k);
    defer @memset(&seed, 0);
    var client_send = Rc4.init(&seed);
    var sync = [_]u8{0} ** 1024;
    client_send.update(&sync);

    var crypt = AuthCrypt.init(k);
    defer crypt.deinit();

    var header = [_]u8{ 0x00, 0x08, 0xDC, 0x01, 0x00, 0x00 };
    const plain = header;
    client_send.update(&header);
    try t.expect(!std.mem.eql(u8, &plain, &header));

    crypt.client_decrypt.update(&header);
    try t.expectEqualSlices(u8, &plain, &header);
}
