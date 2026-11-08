// SHA-256 和 HMAC-SHA256
'use strict';
import * as fs from 'fs';

const K = [
	0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
	0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
	0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
	0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
	0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
	0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
	0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
	0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
];
const M = 0xffffffff;

function rotr(x, n) { return ((x >> n) | (x << (32 - n))) & M; }

const NATIVE_MIN = 512;
let native = null;

const HEX = '0123456789abcdef';
function unhex(h) {
	let out = '';
	for (let i = 0; i < 64; i += 2) out += chr(index(HEX, substr(h, i, 1)) * 16 + index(HEX, substr(h, i + 1, 1)));
	return out;
}

function sha256native(msg) {
	if (native === false) return null;
	const dir = fs.stat('/tmp/doti')?.type == 'directory' ? '/tmp/doti' : '/tmp';
	const out = sprintf('%s/.sha-%s', dir, trim(fs.readfile('/proc/sys/kernel/random/uuid') ?? '' + time()));
	const p = fs.popen(sprintf("sha256sum > '%s' 2>/dev/null", out), 'w');
	let h = null;
	if (p) {
		p.write(msg);
		p.close();
		h = substr(trim(fs.readfile(out) ?? ''), 0, 64);
		fs.unlink(out);
	}
	if (!match(h ?? '', /^[0-9a-f]{64}$/)) { native = false; return null; }
	native = true;
	return unhex(h);
}

// 返回 32 字节的原始摘要
function sha256raw(msg) {
	const L = length(msg);
	if (L >= NATIVE_MIN) {
		const r = sha256native(msg);
		if (r != null) return r;
	}
	let bytes = [];
	for (let i = 0; i < L; i++) push(bytes, ord(msg, i));
	push(bytes, 0x80);
	while (length(bytes) % 64 != 56) push(bytes, 0);
	const bits = L * 8;
	for (let i = 7; i >= 0; i--) push(bytes, (bits >> (i * 8)) & 0xff);

	let h = [ 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 ];
	for (let off = 0; off < length(bytes); off += 64) {
		const w = [];
		for (let i = 0; i < 16; i++)
			w[i] = (bytes[off + i * 4] << 24) | (bytes[off + i * 4 + 1] << 16) | (bytes[off + i * 4 + 2] << 8) | bytes[off + i * 4 + 3];
		for (let i = 16; i < 64; i++) {
			const s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
			const s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
			w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & M;
		}
		let a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
		for (let i = 0; i < 64; i++) {
			const S1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25);
			const ch = (e & f) ^ ((e ^ M) & g);
			const t1 = (hh + S1 + ch + K[i] + w[i]) & M;
			const S0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22);
			const maj = (a & b) ^ (a & c) ^ (b & c);
			const t2 = (S0 + maj) & M;
			hh = g; g = f; f = e; e = (d + t1) & M; d = c; c = b; b = a; a = (t1 + t2) & M;
		}
		h = [ (h[0] + a) & M, (h[1] + b) & M, (h[2] + c) & M, (h[3] + d) & M, (h[4] + e) & M, (h[5] + f) & M, (h[6] + g) & M, (h[7] + hh) & M ];
	}
	let out = '';
	for (let x in h) out += chr((x >> 24) & 0xff, (x >> 16) & 0xff, (x >> 8) & 0xff, x & 0xff);
	return out;
}

function hex(raw) {
	let s = '';
	for (let i = 0; i < length(raw); i++) s += sprintf('%02x', ord(raw, i));
	return s;
}

export function sha256(msg) { return hex(sha256raw(msg)); };

export function hmacSha256(key, msg) {
	if (length(key) > 64) key = sha256raw(key);
	let ipad = '', opad = '';
	for (let i = 0; i < 64; i++) {
		const k = i < length(key) ? ord(key, i) : 0;
		ipad += chr(k ^ 0x36);
		opad += chr(k ^ 0x5c);
	}
	return hex(sha256raw(opad + sha256raw(ipad + msg)));
};
