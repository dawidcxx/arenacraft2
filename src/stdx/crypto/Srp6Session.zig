const std = @import("std");
const Sha1 = std.crypto.hash.Sha1;
const SrpMod256 = std.crypto.ff.Modulus(256);
const SrpFe = SrpMod256.Fe;

const WOTLK_G: u8 = 7;
const WOTLK_K: u8 = 3;
const WOTLK_N_LE: [32]u8 = .{
    0xB7, 0x9B, 0x3E, 0x2A, 0x87, 0x82, 0x3C, 0xAB,
    0x8F, 0x5E, 0xBF, 0xBF, 0x8E, 0xB1, 0x01, 0x08,
    0x53, 0x50, 0x06, 0x29, 0x8B, 0x5B, 0xAD, 0xBD,
    0x5B, 0x53, 0xE1, 0x89, 0x5E, 0x64, 0x4B, 0x89,
};
const WOTLK_MODULUS = blk: {
    @setEvalBranchQuota(10_000);
    break :blk SrpMod256.fromBytes(&WOTLK_N_LE, .little) catch unreachable;
};

pub const InitOptions = struct {
    /// Must be uppercase login used in M1 (I hash)
    username: []const u8,
    salt: [32]u8,
    /// verifier as encoded integer bytes (little-endian)
    verifier_le: [32]u8,
};

pub const Challenge = struct {
    b_pub_le: [32]u8, // B
    g: u8,
    n_le: [32]u8, // N
    salt: [32]u8, // s
    security_flags: u8,
};

pub const ClientProof = struct {
    a_pub_le: [32]u8, // A
    m1: [20]u8, // client M
};

pub const VerifySuccess = struct {
    m2: [20]u8,
    /// WoW strong session key (SHA1 interleave)
    k: [40]u8,
};

pub const State = enum {
    empty,
    init,
    challenge_ready, // B computed, waiting for proof
    authenticated, // verified; k/m2 available
    failed, // terminal failure
};

pub const Error = error{
    InvalidState,
    InvalidInput,
    InvalidA,
    BadProof,
    CryptoFailure,
};

pub const SrpSession = struct {
    state: State = .empty,

    // immutable account inputs
    salt: [32]u8,
    verifier: SrpFe,

    // modulus cache
    m: *const SrpMod256 = &WOTLK_MODULUS,

    // ephemeral server secrets/publics
    b_priv_le: [32]u8 = @splat(0),
    b_pub_le: [32]u8 = @splat(0),

    // derived caches for proof verification
    i_hash: [20]u8, // SHA1(username_upper), computed in init

    // outputs after auth
    session_k: [40]u8 = @splat(0),
    m2: [20]u8 = @splat(0),

    pub fn empty() SrpSession {
        const zero32: [32]u8 = @splat(0);
        const verifier = SrpFe.fromBytes(WOTLK_MODULUS, &zero32, .little) catch unreachable;

        return SrpSession{
            .salt = zero32,
            .verifier = verifier,
            .i_hash = @splat(0),
        };
    }

    pub fn init(opts: InitOptions) Error!SrpSession {
        const verifier = SrpFe.fromBytes(WOTLK_MODULUS, &opts.verifier_le, .little) catch return Error.InvalidInput;

        const i_hash = sha1One(opts.username);

        return SrpSession{
            .state = .init,
            .salt = opts.salt,
            .verifier = verifier,
            .i_hash = i_hash,
        };
    }

    /// Computes B from a server private key b. Call once per login attempt.
    pub fn beginChallenge(self: *SrpSession, b_priv: [32]u8, security_flags: u8) Error!Challenge {
        if (self.state != .init) return Error.InvalidState;

        self.b_priv_le = b_priv;

        // B = (k*v + g^b) mod N, where k = 3 for WoW
        const g_le = [_]u8{WOTLK_G};
        const g_fe = SrpFe.fromBytes(self.m.*, &g_le, .little) catch return Error.CryptoFailure;
        const k_le = [_]u8{WOTLK_K};
        const k_fe = SrpFe.fromBytes(self.m.*, &k_le, .little) catch return Error.CryptoFailure;

        const gb_fe = self.m.powWithEncodedExponent(g_fe, &self.b_priv_le, .little) catch return Error.CryptoFailure;
        const kv_fe = self.m.mul(k_fe, self.verifier);
        const b_fe = self.m.add(kv_fe, gb_fe);
        b_fe.toBytes(&self.b_pub_le, .little) catch return Error.CryptoFailure;

        self.state = .challenge_ready;

        return Challenge{
            .b_pub_le = self.b_pub_le,
            .g = WOTLK_G,
            .n_le = WOTLK_N_LE,
            .salt = self.salt,
            .security_flags = security_flags,
        };
    }

    /// Verifies client M1 from A and returns M2 + K on success.
    pub fn verifyProof(self: *SrpSession, proof: ClientProof) Error!VerifySuccess {
        if (self.state != .challenge_ready) return Error.InvalidState;

        // Parse A; use reduce to accept non-canonical encodings (reference-consistent)
        const Uint256 = std.crypto.ff.Uint(256);
        const A_uint = Uint256.fromBytes(&proof.a_pub_le, .little) catch return Error.InvalidA;
        const A_fe = self.m.reduce(A_uint);

        if (A_fe.isZero()) return Error.InvalidA;

        // u = SHA1(A || B)
        const u_bytes = sha1Concat2(&proof.a_pub_le, &self.b_pub_le);

        // v^u mod N
        const vu_fe = self.m.powWithEncodedPublicExponent(self.verifier, &u_bytes, .little) catch return Error.CryptoFailure;

        // A * v^u mod N
        const Avu_fe = self.m.mul(A_fe, vu_fe);

        // S = (A * v^u)^b mod N
        const S_fe = self.m.powWithEncodedExponent(Avu_fe, &self.b_priv_le, .little) catch return Error.CryptoFailure;

        var S_bytes: [32]u8 = undefined;
        S_fe.toBytes(&S_bytes, .little) catch return Error.CryptoFailure;

        // K = SHA1Interleave(S) -> 40 bytes
        const K = sha1Interleave(&S_bytes);

        // NgHash = SHA1(N) XOR SHA1(g)
        const g_le = [_]u8{WOTLK_G};
        const N_hash = sha1One(&WOTLK_N_LE);
        const g_hash = sha1One(&g_le);

        var NgHash: [20]u8 = undefined;
        for (&NgHash, N_hash, g_hash) |*dst, n, g| {
            dst.* = n ^ g;
        }

        // M1_expected = SHA1(NgHash || I_hash || s || A || B || K)
        var m1_expected: [20]u8 = undefined;
        {
            var sha = Sha1.init(.{});
            sha.update(&NgHash);
            sha.update(&self.i_hash);
            sha.update(&self.salt);
            sha.update(&proof.a_pub_le);
            sha.update(&self.b_pub_le);
            sha.update(&K);
            sha.final(&m1_expected);
        }

        {
            var diff: u8 = 0;
            for (&m1_expected, &proof.m1) |a, b| {
                diff |= a ^ b;
            }
            if (diff != 0) {
                self.state = .failed;
                return Error.BadProof;
            }
        }

        // M2 = SHA1(A || M1 || K)
        const M2 = sha1Concat3(&proof.a_pub_le, &proof.m1, &K);

        self.session_k = K;
        self.m2 = M2;
        self.state = .authenticated;

        return VerifySuccess{
            .m2 = M2,
            .k = K,
        };
    }

    pub fn getState(self: *const SrpSession) State {
        return self.state;
    }

    pub fn isAuthenticated(self: *const SrpSession) bool {
        return self.state == .authenticated;
    }

    /// Zeroes owned session material and marks the session as terminal.
    pub fn deinit(self: *SrpSession) void {
        @memset(&self.b_priv_le, 0);
        @memset(&self.b_pub_le, 0);
        @memset(&self.session_k, 0);
        @memset(&self.m2, 0);
        self.state = .empty;
    }
};

// ─── SHA1 HELPERS ────────────────────────────────────────────────────────────

fn sha1One(data: []const u8) [Sha1.digest_length]u8 {
    var out: [Sha1.digest_length]u8 = undefined;
    var sha = Sha1.init(.{});
    sha.update(data);
    sha.final(&out);
    return out;
}

fn sha1Concat2(a: []const u8, b: []const u8) [Sha1.digest_length]u8 {
    var out: [Sha1.digest_length]u8 = undefined;
    var sha = Sha1.init(.{});
    sha.update(a);
    sha.update(b);
    sha.final(&out);
    return out;
}

fn sha1Concat3(a: []const u8, b: []const u8, c: []const u8) [Sha1.digest_length]u8 {
    var out: [Sha1.digest_length]u8 = undefined;
    var sha = Sha1.init(.{});
    sha.update(a);
    sha.update(b);
    sha.update(c);
    sha.final(&out);
    return out;
}

/// SRP SHA1 interleave: splits S[32] into even/odd halves, skips leading zero
/// pairs, then computes SHA1 on each half and interleaves the digests into K[40].
fn sha1Interleave(S: *const [32]u8) [40]u8 {
    var buf0: [16]u8 = undefined;
    var buf1: [16]u8 = undefined;
    for (0..16) |i| {
        buf0[i] = S[2 * i];
        buf1[i] = S[2 * i + 1];
    }

    // Skip leading zero bytes in S (must skip in pairs)
    var p: usize = 0;
    while (p < 32 and S[p] == 0) : (p += 1) {}
    if (p & 1 == 1) p += 1;
    p /= 2;

    const h0 = sha1One(buf0[p..]);
    const h1 = sha1One(buf1[p..]);

    var K: [40]u8 = undefined;
    for (0..20) |i| {
        K[2 * i] = h0[i];
        K[2 * i + 1] = h1[i];
    }
    return K;
}

// ─── TESTS ────────────────────────────────────────────────────────────────────

const t = std.testing;

fn fakeTestSalt() [32]u8 {
    var s: [32]u8 = undefined;
    for (&s, 0..) |*b, i| {
        b.* = @intCast((0xF0 + i) & 0xFF);
    }
    return s;
}

fn fakeTestVerifier(user: []const u8, pass: []const u8) [32]u8 {
    const g_le = [_]u8{WOTLK_G};
    const m = SrpMod256.fromBytes(&WOTLK_N_LE, .little) catch unreachable;
    const g_fe = SrpFe.fromBytes(m, &g_le, .little) catch unreachable;
    const identity_hash = sha1Concat3(user, ":", pass);
    const salt = fakeTestSalt();
    const x = sha1Concat2(&salt, &identity_hash);
    const v_fe = m.powWithEncodedPublicExponent(g_fe, &x, .little) catch unreachable;
    var v_bytes: [32]u8 = undefined;
    v_fe.toBytes(&v_bytes, .little) catch unreachable;
    return v_bytes;
}

fn fixedRandom(targetSlice: []u8) void {
    // Deterministic "random" = sequential bytes from 0x01
    for (targetSlice, 0..) |*b, i| {
        b.* = @intCast((0x01 + (i * 7)) & 0xFF);
    }
}

fn fixedRandomB() [32]u8 {
    var b: [32]u8 = undefined;
    fixedRandom(&b);
    return b;
}

fn fixedRandomBad(targetSlice: []u8) void {
    for (targetSlice, 0..) |*b, i| {
        b.* = @intCast((0xFF - (i * 3)) & 0xFF);
    }
}

const test_username = "ALICE";
const test_password = "alice_password";

fn testAccount() InitOptions {
    const salt = fakeTestSalt();
    return .{
        .username = test_username,
        .salt = salt,
        .verifier_le = fakeTestVerifier(test_username, test_password),
    };
}

fn testSession() Error!SrpSession {
    return SrpSession.init(testAccount());
}

fn challengedTestSession() Error!SrpSession {
    var session = try testSession();
    _ = try session.beginChallenge(fixedRandomB(), 0);
    return session;
}

test "SRP session state transitions" {
    var empty = SrpSession.empty();
    try t.expectEqual(State.empty, empty.getState());
    try t.expectError(Error.InvalidState, empty.beginChallenge(fixedRandomB(), 0));

    const account = testAccount();
    var session = try SrpSession.init(account);
    try t.expectEqual(State.init, session.getState());
    try t.expect(!session.isAuthenticated());
    try t.expect(std.mem.allEqual(u8, session.b_priv_le[0..], 0));
    try t.expect(std.mem.allEqual(u8, session.session_k[0..], 0));
    try t.expectError(Error.InvalidState, session.verifyProof(.{
        .a_pub_le = @splat(1),
        .m1 = @splat(0),
    }));

    const challenge = try session.beginChallenge(fixedRandomB(), 0);
    try t.expectEqual(State.challenge_ready, session.getState());
    try t.expectEqual(WOTLK_G, challenge.g);
    try t.expectEqual(account.salt, challenge.salt);
    try t.expectEqual(@as(u8, 0), challenge.security_flags);
    try t.expectError(Error.InvalidState, session.beginChallenge(fixedRandomB(), 0));
}

test "SRP rejects invalid proofs and becomes terminal" {
    var session = try challengedTestSession();

    try t.expectError(Error.InvalidA, session.verifyProof(.{
        .a_pub_le = WOTLK_N_LE,
        .m1 = @splat(0),
    }));
    try t.expectError(Error.BadProof, session.verifyProof(.{
        .a_pub_le = @splat(1),
        .m1 = @splat(0xCC),
    }));
    try t.expectEqual(State.failed, session.getState());
    try t.expectError(Error.InvalidState, session.verifyProof(.{
        .a_pub_le = @splat(1),
        .m1 = @splat(0xCC),
    }));
}

const ClientProofFixture = struct {
    proof: ClientProof,
    k: [40]u8,
};

fn makeClientProof(account: InitOptions, challenge: Challenge) ClientProofFixture {
    const m = SrpMod256.fromBytes(&WOTLK_N_LE, .little) catch unreachable;
    const g_le = [_]u8{WOTLK_G};
    const g_fe = SrpFe.fromBytes(m, &g_le, .little) catch unreachable;
    const k_le = [_]u8{WOTLK_K};
    const k_fe = SrpFe.fromBytes(m, &k_le, .little) catch unreachable;

    var a_priv: [32]u8 = undefined;
    fixedRandomBad(&a_priv);

    const A_fe = m.powWithEncodedExponent(g_fe, &a_priv, .little) catch unreachable;
    var A_bytes: [32]u8 = undefined;
    A_fe.toBytes(&A_bytes, .little) catch unreachable;

    const u = sha1Concat2(&A_bytes, &challenge.b_pub_le);
    const identity_hash = sha1Concat3(account.username, ":", test_password);
    const x = sha1Concat2(&account.salt, &identity_hash);
    const v_fe = m.powWithEncodedPublicExponent(g_fe, &x, .little) catch unreachable;
    const kv_fe = m.mul(k_fe, v_fe);
    const B_fe = SrpFe.fromBytes(m, &challenge.b_pub_le, .little) catch unreachable;
    const base_fe = m.sub(B_fe, kv_fe);

    const S_part1 = m.powWithEncodedExponent(base_fe, &a_priv, .little) catch unreachable;
    const baseU_fe = m.powWithEncodedPublicExponent(base_fe, &u, .little) catch unreachable;
    const S_part2 = m.powWithEncodedPublicExponent(baseU_fe, &x, .little) catch unreachable;
    const S_client_fe = m.mul(S_part1, S_part2);

    var S_client: [32]u8 = undefined;
    S_client_fe.toBytes(&S_client, .little) catch unreachable;
    const k = sha1Interleave(&S_client);

    const N_hash = sha1One(&WOTLK_N_LE);
    const g_hash = sha1One(&g_le);
    var NgHash: [20]u8 = undefined;
    for (&NgHash, N_hash, g_hash) |*dst, n, g| dst.* = n ^ g;

    const I_hash = sha1One(account.username);
    var m1: [20]u8 = undefined;
    var sha = Sha1.init(.{});
    sha.update(&NgHash);
    sha.update(&I_hash);
    sha.update(&account.salt);
    sha.update(&A_bytes);
    sha.update(&challenge.b_pub_le);
    sha.update(&k);
    sha.final(&m1);

    return .{
        .proof = .{ .a_pub_le = A_bytes, .m1 = m1 },
        .k = k,
    };
}

test "SRP round trip authenticates a client" {
    const account = testAccount();
    var session = try SrpSession.init(account);
    const chal = try session.beginChallenge(fixedRandomB(), 0);

    const client = makeClientProof(account, chal);
    const result = try session.verifyProof(client.proof);
    try t.expectEqual(State.authenticated, session.getState());
    try t.expect(session.isAuthenticated());
    try t.expectEqualSlices(u8, &client.k, &result.k);
    const expected_m2 = sha1Concat3(&client.proof.a_pub_le, &client.proof.m1, &client.k);
    try t.expectEqualSlices(u8, &expected_m2, &result.m2);
}

test "deinit clears sensitive data" {
    var session = try challengedTestSession();

    // Verify b_priv_le is not all zeros
    const zero32: [32]u8 = @splat(0);
    const zero40: [40]u8 = @splat(0);
    const zero20: [20]u8 = @splat(0);
    try t.expect(!std.mem.eql(u8, &session.b_priv_le, &zero32));

    session.deinit();
    try t.expectEqual(State.empty, session.getState());
    try t.expect(std.mem.eql(u8, &session.b_priv_le, &zero32));
    try t.expect(std.mem.eql(u8, &session.b_pub_le, &zero32));
    try t.expect(std.mem.eql(u8, &session.session_k, &zero40));
    try t.expect(std.mem.eql(u8, &session.m2, &zero20));
}
