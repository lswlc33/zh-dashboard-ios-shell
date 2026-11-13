// Offline verifier models and Swift source contracts only. No Swift execution, HTTP, BLE, device or credentials.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const renewal = fs.readFileSync(path.join(root, 'ios-shell/SessionRenewal.swift'), 'utf8');
const secrets = fs.readFileSync(path.join(root, 'ios-shell/SecretHandles.swift'), 'utf8');
let checks = 0;
function check(name, fn) { fn(); checks++; console.log(`PASS ${name}`); }

// Deliberately independent model: documents safety cases, not a simulated Swift test pass.
class VerifierModel {
  constructor() {
    this.owner = 'synthetic-owner-vin-epoch'; this.conn = 'gatt-1'; this.expires = 300000;
    this.lastFresh = 0; this.authorized = false; this.inFlight = false; this.ticket = 0;
    this.baseline = ['fixture-key', 'fixture-vector', 'fixture-cipher']; this.events = [];
  }
  begin(now, initial = false) {
    if (this.inFlight || now >= this.expires || (!initial && (!this.authorized || now - this.lastFresh < 240000))) return null;
    this.inFlight = true; return { ticket: ++this.ticket, owner: this.owner, conn: this.conn, initial };
  }
  revoke(reason) { this.authorized = false; this.inFlight = false; ++this.ticket; this.events.push(reason); }
  reply(request, now, { owner = this.owner, http = 200, asserts = true, material = this.baseline, issuer = true, ack = false } = {}) {
    if (!request || request.ticket !== this.ticket || request.owner !== this.owner || request.conn !== this.conn || !this.inFlight) return false;
    if (now >= this.expires || http !== 200 || !asserts || owner !== this.owner) { this.revoke('gap'); return false; }
    const changed = material.some((v, i) => v !== this.baseline[i]);
    if (request.initial && changed) { this.revoke('initial_material_mismatch'); return false; }
    if (request.initial || changed) {
      this.authorized = false; this.events.push('revoke_before_handshake');
      if (!ack || !issuer) { this.revoke('reauthentication_required'); return false; }
      this.baseline = [...material]; this.events.push('native_ack');
    } else if (!issuer) { this.revoke('issuer_rejected'); return false; }
    this.authorized = true; this.lastFresh = now; this.expires = now + 300000; this.inFlight = false;
    return true;
  }
  observe(now) { if (now >= this.expires) this.revoke('deadline'); return this.authorized; }
}
check('initial fresh matching response is not authentication without native ACK', () => {
  const model = new VerifierModel();
  assert.equal(model.reply(model.begin(1000, true), 1100), false);
  assert.equal(model.authorized, false);
  const good = new VerifierModel(); assert.equal(good.reply(good.begin(1000, true), 1100, { ack: true }), true);
  assert.deepEqual(good.events, ['revoke_before_handshake', 'native_ack']);
});
check('4 minute fresh success preserves GATT generation, only actual issuer extends authorization', () => {
  const model = new VerifierModel(); model.authorized = true;
  assert.equal(model.begin(239999), null); const req = model.begin(240000);
  assert.equal(model.begin(240001), null);
  assert.equal(model.reply(req, 241000), true); assert.equal(model.conn, 'gatt-1'); assert.equal(model.expires, 541000);
  const rejected = new VerifierModel(); rejected.authorized = true;
  assert.equal(rejected.reply(rejected.begin(240000), 241000, { issuer: false }), false);
});
check('changed material revokes before handshake and cannot resume on transport write alone', () => {
  const model = new VerifierModel(); model.authorized = true;
  assert.equal(model.reply(model.begin(240000), 241000, { material: ['changed', 'fixture-vector', 'fixture-cipher'] }), false);
  assert.equal(model.authorized, false); assert.equal(model.events[0], 'revoke_before_handshake');
  const acked = new VerifierModel(); acked.authorized = true;
  assert.equal(acked.reply(acked.begin(240000), 241000, { material: ['changed', 'fixture-vector', 'fixture-cipher'], ack: true }), true);
});
check('late success, 401, wrong owner and failed assertion cannot revive old authorization', () => {
  for (const [at, options] of [[300000, {}], [240001, { http: 401 }], [240001, { owner: 'foreign' }], [240001, { asserts: false }]]) {
    const model = new VerifierModel(); model.authorized = true;
    assert.equal(model.reply(model.begin(240000), at, options), false); assert.equal(model.authorized, false);
  }
  const model = new VerifierModel(); model.authorized = true; const old = model.begin(240000);
  model.revoke('cancel'); assert.equal(model.reply(old, 241000, { ack: true }), false);
});
check('idle background cannot extend TTL without fresh response and exact deadline gates samples', () => {
  const model = new VerifierModel(); model.authorized = true;
  assert.equal(model.observe(299999), true); assert.equal(model.observe(300000), false); assert.equal(model.expires, 300000);
});
check('signature fixture uses sorted raw nonempty query and SHA1 hex then MD5 hex, not encoded wire URL', () => {
  const pairs = [['z', 'two words'], ['a', '/'], ['empty', '']].filter(([, v]) => v).sort(([a], [b]) => a < b ? -1 : 1);
  const raw = pairs.map(([k, v]) => `${k}=${v}`).join('&');
  assert.equal(raw, 'a=/&z=two words');
  const param = 'appId=fixture&nonce=123fixture&timestamp=123';
  const signature = createHash('md5').update(createHash('sha1').update(raw + param + 'synthetic-only').digest('hex')).digest('hex');
  assert.equal(signature.length, 32);
  assert.notEqual(signature, createHash('md5').update(createHash('sha1').update('a=%2F&z=two%20words' + param + 'synthetic-only').digest('hex')).digest('hex'));
  assert.match(renewal, /digest\.update\(data: Data\(\(rawQuery \+ param\)\.utf8\)\)/);
  assert.match(renewal, /digest\.update\(bufferPointer: secret\)/);
  assert.match(renewal, /Insecure\.MD5\.hash\(data: sha\)/);
  assert.match(renewal, /SecRandomCopyBytes/); assert.match(renewal, /Int\(byte\) < ceiling/);
});
check('only opaque import/release RPC, bounded separate memory grant never disk/AppGroup/key export', () => {
  assert.match(secrets, /let methods = \["secret\.import", "secret\.release"\]/);
  assert.match(secrets, /maxBytes = 32_768/); assert.match(secrets, /maxHandles = 12/);
  assert.match(secrets, /maxRecordingHandles = 20/); assert.match(secrets, /maxTotalBytes = 262_144/);
  assert.match(secrets, /recordingTTL: Double = 7_200/); assert.match(secrets, /NSLock\(\)/);
  assert.match(secrets, /memset_s\(bytes, count, 0, count\)/);
  assert.match(secrets, /entry\.scope == scope/); assert.match(secrets, /entry\.recordingID == recordingID/);
  for (const source of [secrets, renewal]) assert.doesNotMatch(source, /IOSDiagnostics|IOSStore|UserDefaults|SecItemAdd|FileManager|write\(to:|suiteName:|APP_SECRET\s*=|H5_SECRET\s*=/);
  assert.doesNotMatch(secrets, /"secret\.(?:export|read)"/);
  const reply = secrets.slice(secrets.indexOf('reply(["ok": true, "handle"'), secrets.indexOf('} else if method == "secret.release"'));
  assert.doesNotMatch(reply, /importBase64|bytes|plain|token|secret/);
});
check('native persisted owner epoch, actual recording and cancellable native consent are required', () => {
  assert.match(secrets, /String\(epoch\) == scope\.generation/);
  assert.match(secrets, /metadata\["accountId"\] as\? String == scope\.accountID/);
  assert.match(renewal, /typealias ConsentProvider = .*-> \(\(\) -> Void\)/);
  assert.match(renewal, /lease\.recordingID == id, lease\.scope == scope, validWindow\(lease\)/);
  assert.match(renewal, /let cancel = consent\(id, scope\)/);
  assert.match(renewal, /cancel\?\(\)/); assert.doesNotMatch(renewal, /options\["confirmed"\]/);
  assert.match(renewal, /held\.owned && held\.active && held\.prepareReply == nil && current\(held\)/);
});
check('prepare immediately fetches and performs native initial handshake before supported/active flags', () => {
  assert.match(renewal, /self\.fetch\(held, initial: true\)/);
  assert.match(renewal, /if initial && changed \{ stop\(held, reason: "initial_material_mismatch"\)/);
  assert.match(renewal, /reason: initial \? "initial_authorization" : "material_changed"/);
  assert.match(renewal, /lease\.nativeAuthenticated, self\.validWindow\(lease\)/);
  assert.match(renewal, /issued\.nativeAuthenticated, self\.validWindow\(issued\)/);
  assert.match(renewal, /held\.recipeComplete = true; held\.phase = "active"/);
  assert.match(renewal, /"connectionGeneration": fresh \? held\.connection : ""/);
  assert.match(renewal, /"nativeAdmission": fresh/);
});
check('event driven single inflight renewal, all results guarded by OLD expiry and explicit issuer receipt', () => {
  assert.match(renewal, /systemUptime - held\.refreshedAt >= Self\.interval/);
  assert.match(renewal, /!held\.inFlight/); assert.match(renewal, /Self\.interval|interval: Double = 240/);
  assert.match(renewal, /ProcessInfo\.processInfo\.systemUptime < held\.expiry/);
  assert.match(renewal, /issuer\(held\.id, held\.scope, held\.connection, next\)/);
  assert.match(renewal, /invalidateLateLease\(lease\)/);
  assert.match(renewal, /private func revoke/); assert.match(renewal, /authorizationExpired\?\(held\.id/);
  assert.doesNotMatch(renewal, /Timer\.scheduledTimer|UIApplication\.shared|generation \+=/);
});
check('GET recipe is bounded to official HTTPS, 2 requests, paths 8 deep/24 total, no body/eval/regexp', () => {
  for (const token of ['descriptors.count <= 2', 'path.count <= 8', 'totalPaths <= 24', '== 240_000', '== 300_000', '65_536']) assert.ok(renewal.includes(token), token);
  assert.match(renewal, /parts\.scheme == "https"/);
  assert.match(renewal, /\["tapi\.zeehoev\.com", "h5\.zeehoev\.com"\]/);
  assert.match(renewal, /descriptor\["method"\] as\? String == "GET"/);
  assert.match(renewal, /parts\.query == nil, parts\.fragment == nil/);
  assert.match(renewal, /secretBaselineRef/); assert.match(renewal, /ambiguous_material_baseline/);
  assert.doesNotMatch(renewal, /NSRegularExpression|regularExpression|evaluateJavaScript|httpBody\s*=/);
});
check('streamed responses cap 512KiB, strict duplicate/finite/depth gates, no redirect/cache/cookies', () => {
  assert.match(renewal, /chunk\.count <= 524_288 - data\.count/);
  assert.match(renewal, /keys\.insert\(key\)\.inserted/);
  assert.match(renewal, /duplicate_response_key/); assert.match(renewal, /number\.isFinite/);
  assert.match(renewal, /depth <= 32/); assert.match(renewal, /completionHandler\(nil\)/);
  assert.match(renewal, /URLSessionConfiguration\.ephemeral/);
  assert.match(renewal, /config\.httpCookieStorage = nil/); assert.match(renewal, /config\.urlCache = nil/);
  assert.match(renewal, /http\.statusCode == 401 \|\| http\.statusCode == 403 \? "auth_rejected"/);
  assert.match(renewal, /deinit \{ value\.resetBytes/);
});
check('business success alternatives are finite number-or-string literals, never boolean coercion or owner proof alone', () => {
  const matches = value => (typeof value === 'number' && Number.isFinite(value) && value === 12345) || (typeof value === 'string' && value === '12345');
  assert.equal(matches(12345), true); assert.equal(matches('12345'), true);
  for (const value of [true, false, 1, 'true', 'error', Infinity, NaN]) assert.equal(matches(value), false);
  assert.match(renewal, /values\.count <= 8/);
  assert.match(renewal, /hasEquals != hasAny/);
  assert.match(renewal, /CFGetTypeID\(a\) == CFBooleanGetTypeID\(\)/);
  assert.match(renewal, /\$0\.equalsAny == nil && \$0\.type != "numberOrString"/);
});
check('8 distinct material replacement slots and 4KiB material budget are reserved before initial authorization', () => {
  const prepareBudget = (materialCount, handles = 12, bytes = 120000) => materialCount <= 8
    && handles + materialCount <= 20 && bytes + materialCount * 4096 <= 262144;
  assert.equal(prepareBudget(8), true); assert.equal(prepareBudget(9), false);
  assert.equal(prepareBudget(8, 12, 240000), false);
  let entries = 12, reservedSlots = 8, total = 120000, reservedBytes = 8 * 4096;
  for (let n = 0; n < 8; n++) { entries++; reservedSlots--; total += 4096; reservedBytes -= 4096; }
  assert.equal(entries, 20); assert.equal(reservedSlots, 0); assert.ok(total + reservedBytes <= 262144);
  entries -= 8; total -= 8 * 4096; reservedSlots = 8; reservedBytes = 8 * 4096;
  assert.equal(entries + reservedSlots, 20); assert.ok(total + reservedBytes <= 262144);
  // Second changed cycle consumes the replenished reservation, not an exhausted first-cycle budget.
  for (let n = 0; n < 8; n++) { entries++; reservedSlots--; total += 4096; reservedBytes -= 4096; }
  assert.equal(entries, 20); assert.equal(reservedSlots, 0);
  entries -= 8; total -= 8 * 4096; reservedSlots = 8; reservedBytes = 8 * 4096;
  assert.equal(entries + reservedSlots, 20);
  // Recording end wipes BOTH live entries and reservation; next run cannot inherit a grant.
  entries = 0; total = 0; reservedSlots = 0; reservedBytes = 0;
  assert.equal(entries + reservedSlots, 0); assert.equal(total + reservedBytes, 0);
  assert.match(renewal, /materials\.count <= 8/); assert.match(renewal, /materials\.isDisjoint\(with: ownerBaselines\)/);
  assert.match(renewal, /text\.utf8\.count <= 4096/);
  assert.match(renewal, /replacementMaterials: held\.recipe\.materialHandles/);
  assert.match(renewal, /reserveReplacements\(scope: held\.scope/);
  assert.match(renewal, /checkReplacementBudget\(scope: scope/);
  assert.match(secrets, /try replacementBudgetLocked\(scope: scope, recordingID: recordingID, materials: replacementMaterials\)/);
  assert.match(secrets, /reservations\.removeValue\(forKey: recordingId\)/);
});
check('prepare rejects near-capacity tiny material before consent, covering worst steady size AND next replacement', () => {
  const cap = 262144, worst = 4096;
  const reserved = (count, currentBytes) => count * worst * 2 - currentBytes;
  const nearCap = 258048, tinyMaterial = 1;
  assert.equal(nearCap + worst <= cap, true); // The insufficient old one-cycle formula accepted this.
  assert.equal(nearCap + reserved(1, tinyMaterial) <= cap, false);
  const nonMaterial = 120000;
  let materialBytes = 8;
  for (let cycle = 0; cycle < 3; cycle++) {
    const total = nonMaterial + materialBytes;
    const budget = reserved(8, materialBytes);
    assert.equal(total + budget, nonMaterial + 8 * worst * 2);
    assert.ok(total + budget <= cap);
    // Native replacement consumes 4KiB budget per slot while both generations exist.
    assert.ok(total + 8 * worst + (budget - 8 * worst) <= cap);
    materialBytes = 8 * worst; // Release tiny/previous old generation, then replenish reservation.
    assert.ok(nonMaterial + materialBytes + reserved(8, materialBytes) <= cap);
  }
  assert.match(secrets, /reservedBytes = slots \* 4096 \* 2 - currentMaterialBytes/);
  assert.match(renewal, /try secrets\.checkReplacementBudget/);
  assert.ok(renewal.indexOf('let recipe = try IOSRenewalRecipe.parse') < renewal.indexOf('let cancel = consent(id, scope)'));
});
console.log(`OK ${checks} offline model/source groups. Swift compilation, native runtime, server and vehicle validation NOT performed.`);
