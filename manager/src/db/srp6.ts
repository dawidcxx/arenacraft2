import { createHash, randomBytes } from "node:crypto";

const generator = 7n;
const modulus = BigInt("0x894B645E89E1535BBDAD5B8B290650530801B18EBFBF5E8FAB3C82872A3E9BB7");

export type RegistrationData = {
  salt: Uint8Array;
  verifier: Uint8Array;
};

export function makeRegistrationData(username: string, password: string): RegistrationData {
  const normalizedUsername = normalizeAccountSecret(username);
  const normalizedPassword = normalizeAccountSecret(password);
  const salt = randomBytes(32);
  const identityHash = sha1(Buffer.from(`${normalizedUsername}:${normalizedPassword}`, "utf8"));
  const verifierHash = sha1(Buffer.concat([salt, identityHash]));
  const verifier = bigIntToLittleEndianBytes(modPow(generator, littleEndianBytesToBigInt(verifierHash), modulus), 32);

  return { salt, verifier };
}

export function normalizeAccountSecret(value: string) {
  return value.toUpperCase();
}

function sha1(value: Uint8Array) {
  return createHash("sha1").update(value).digest();
}

function littleEndianBytesToBigInt(bytes: Uint8Array) {
  let value = 0n;

  for (let index = bytes.length - 1; index >= 0; index -= 1) {
    value = (value << 8n) + BigInt(bytes[index] ?? 0);
  }

  return value;
}

function bigIntToLittleEndianBytes(value: bigint, byteLength: number) {
  const bytes = new Uint8Array(byteLength);
  let remaining = value;

  for (let index = 0; index < byteLength; index += 1) {
    bytes[index] = Number(remaining & 0xffn);
    remaining >>= 8n;
  }

  return bytes;
}

function modPow(base: bigint, exponent: bigint, mod: bigint) {
  let result = 1n;
  let currentBase = base % mod;
  let currentExponent = exponent;

  while (currentExponent > 0n) {
    if (currentExponent & 1n) {
      result = (result * currentBase) % mod;
    }

    currentExponent >>= 1n;
    currentBase = (currentBase * currentBase) % mod;
  }

  return result;
}
