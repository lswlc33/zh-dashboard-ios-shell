// Offline callable protocol fixtures + native source contracts, not Swift execution or vehicle validation.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const source = name => fs.readFileSync(path.join(root, 'ios-shell', name), 'utf8');
const ble = source('Bluetooth.swift'), ride = source('Ride.swift'), engine = source('BLERecipe.swift');
const wireSource = fs.readFileSync(path.join(root, 'public/js/vehicle-wire.js'), 'utf8');
const sandbox = { crypto: { randomUUID: crypto.randomUUID }, TextEncoder, TextDecoder, Uint8Array, console };
sandbox.window = sandbox; sandbox.globalThis = sandbox; vm.createContext(sandbox); vm.runInContext(wireSource, sandbox);
const W = sandbox.VehicleWire;
let groups = 0;
const check = (name, fn) => { fn(); groups++; console.log(`PASS ${name}`); };

class LeaseFixture {
  constructor() { this.now = 10; this.id = 'actual-run'; this.scope = 'owner-vin-credential1'; this.conn = 'conn1';
    this.peripheral = 'p1'; this.seq = 30; this.epoch = 1; this.at = 10; this.until = 310;
    this.actual = true; this.configured = true; this.prepared = true; this.auth = false; this.cloud = false;
    this.times = { speedKph: 11000 }; this.gaps = []; this.cap = null; this.gps = []; }
  accept() { return this.actual && this.cloud && this.auth && this.now < this.until && !this.cap; }
  proof() { this.auth = this.cloud = true; }
  renew(expiry) {
    if (!this.accept() || !Number.isFinite(expiry) || expiry <= this.now || expiry - this.now > 300.001) return false;
    this.at = expiry - 300; this.until = expiry; return true;
  }
  changed() { this.cloud = this.auth = false; this.gaps.push('material_changed'); this.cap = { epoch: this.epoch, id: this.id, scope: this.scope, conn: this.conn, expires: this.until }; return this.cap; }
  finish(cap, valid) {
    if (!valid || cap !== this.cap || cap.epoch !== this.epoch || !this.actual || cap.id !== this.id || cap.scope !== this.scope || cap.conn !== this.conn || this.now >= cap.expires) return false;
    this.cap = null; this.auth = this.cloud = true; this.at = this.now; this.until = this.now + 300; return true;
  }
  observe() { if (this.now >= this.until) { this.auth = this.cloud = false; this.cap = null; this.gaps.push('authorization_expired'); } return this.accept(); }
  end() { this.actual = false; this.epoch++; this.cap = null; this.auth = this.cloud = false; }
}
class AckFixture {
  constructor({ generation = 'conn1', operationID = 'op1', seq = 30, uptime = 20 } = {}) {
    Object.assign(this, { generation, operationID, seq, uptime }); this.fragments = []; this.gatt = false; this.cancelled = false;
  }
  notify({ generation, operationID, seq, uptime, bytes }) {
    if (this.cancelled || generation !== this.generation || operationID !== this.operationID || seq <= this.seq || uptime < this.uptime) return false;
    this.fragments.push(bytes); return this.gatt;
  }
  ack() { this.gatt = true; return !this.cancelled && this.fragments.length > 0; }
  cancel() { this.cancelled = true; this.fragments = []; }
}
check('native metadata/prepared recipe is not a BLE authentication proof', () => {
  const l = new LeaseFixture(); assert.equal(l.accept(), false); assert.equal(l.renew(400), false);
  l.proof(); assert.equal(l.accept(), true);
});
check('unchanged native fresh cloud extends 5-minute window without reconnect/seq/sourceTimes', () => {
  const l = new LeaseFixture(); l.proof(); l.now = 250;
  const before = { conn: l.conn, peripheral: l.peripheral, seq: l.seq, epoch: l.epoch, times: structuredClone(l.times) };
  assert.equal(l.renew(550), true); assert.equal(l.at, 250); assert.equal(l.until - l.at, 300);
  assert.deepEqual({ conn: l.conn, peripheral: l.peripheral, seq: l.seq, epoch: l.epoch, times: l.times }, before);
});
check('expiry rejects late cloud and BLE while GPS remains a separate source', () => {
  const l = new LeaseFixture(); l.proof(); l.now = 310;
  assert.equal(l.observe(), false); assert.equal(l.renew(610), false);
  l.gps.push({ at: l.now, speed: 12 }); assert.equal(l.gps.length, 1); assert.equal(l.gaps.at(-1), 'authorization_expired');
});
check('material changed pauses admission and requires capability-bound actual ACK on same connection', () => {
  const l = new LeaseFixture(); l.proof(); l.now = 250; const cap = l.changed();
  assert.equal(l.accept(), false); assert.equal(l.finish({ ...cap }, true), false);
  assert.equal(l.finish(cap, false), false); assert.equal(l.finish(cap, true), true);
  assert.equal(l.conn, 'conn1'); assert.equal(l.peripheral, 'p1'); assert.equal(l.seq, 30); assert.equal(l.accept(), true);
});
check('end, identity epoch and old connection cannot resurrect stale native callbacks', () => {
  for (const mutate of [l => l.end(), l => { l.scope = 'credential2'; }, l => { l.conn = 'conn2'; }, l => { l.now = 310; }]) {
    const l = new LeaseFixture(); l.proof(); const cap = l.changed(); mutate(l); assert.equal(l.finish(cap, true), false);
  }
});
check('early notify is retained but old seq/op/time/generation and GATT alone are not protocol ACK', () => {
  const w = new AckFixture(); assert.equal(w.ack(), false);
  for (const patch of [{ generation: 'conn0' }, { operationID: 'op0' }, { seq: 30 }, { uptime: 19 }])
    assert.equal(w.notify({ generation: 'conn1', operationID: 'op1', seq: 31, uptime: 21, bytes: Buffer.from([0]), ...patch }), false);
  const early = new AckFixture(); assert.equal(early.notify({ generation: 'conn1', operationID: 'op1', seq: 31, uptime: 21, bytes: Buffer.from([0]) }), false);
  assert.equal(early.ack(), true); early.cancel(); assert.equal(early.ack(), false);
});
check('real private builder submits bounded 16-step ABI, explicit status zero and validated optional ACK', () => {
  assert.ok(W?.renewalHandshakeRecipe, 'actual private builder callable');
  const r = JSON.parse(JSON.stringify(W.renewalHandshakeRecipe({ requests: [{ materialPaths: [['data', 'encryptInfo', 'key']] }] })));
  assert.equal(r.steps.length, 16); assert.equal(r.retries, 0); assert.equal(r.timeoutMs, 15000);
  assert.deepEqual(r.materials[0].path, ['data', 'encryptInfo', 'key']);
  for (const s of r.steps.filter(s => ['write', 'wait'].includes(s.op))) {
    assert.equal(s.frame.commandOffset, 2); assert.equal(s.frame.lengthBytes, 2); assert.equal(s.frame.payloadOffset, 5);
    assert.equal(s.frame.command, undefined); assert.equal(s.frame.wireSeq, undefined); assert.equal(s.frame.maxPayload, 240);
  }
  assert.equal(r.steps[10].kind, 'varint'); assert.equal(r.steps[10].requirePresent, true);
  assert.deepEqual(r.steps[11].right, { hex: '00' }); assert.equal(r.steps[15].optional, true);
  assert.deepEqual(r.steps[6].outputUTF8, { minBytes: 1, maxBytes: 128, noControls: true });
  assert.deepEqual(r.steps[15].payloadValidation, { kind: 'emptyOrVarint', field: 1, values: [0, 1] });
});
check('actual wire algorithm roundtrip has no invented sequence byte and explicit zero is not missing', () => {
  const raw = W.bleFrame(93, new Uint8Array([8, 0]));
  assert.equal(raw.length, 9); assert.equal(raw[2], 93); assert.equal(raw[3], 2); assert.equal(raw[4], 0);
  assert.equal(raw[5], 8); assert.equal(raw[6], 0); assert.equal(raw[7], 103);
  assert.equal(W.authResult(new Uint8Array([8, 0])), true);
  assert.throws(() => W.authResult(new Uint8Array()));
});
check('native recording provider is actual run/scope main-thread query and samples trigger observation before admission', () => {
  assert.match(ride, /configureRecordingProvider \{ \[weak self\] in self\?\.currentNativeRecording\(\) \}/);
  assert.match(ride, /func currentNativeRecording\(\) -> IOSNativeRecording\?/);
  assert.match(ride, /guard let run = active, owns\(run\), !run\.userPaused/);
  assert.match(ride, /observeRecordingEvent\(id: run\.id, scope: run\.scope\)/);
  assert.match(ride, /canObserveTelemetry\(recordingId: run\.id, scope: run\.scope, connectionGeneration: sample\.connectionGeneration\)/);
  assert.match(ble, /lease\.connectionGeneration == epoch\.uuidString\.lowercased\(\)/);
  assert.match(ble, /scopeProvider\?\(\) == run\.scope/);
});
check('native lease extension preserves TTL and fresh sample clocks and refuses already-expired cloud reply', () => {
  const renew = ble.slice(ble.indexOf('func renewRecordingLease'), ble.indexOf('func invalidateRecordingAuthorization'));
  assert.match(renew, /now < old\.authorizedUntil/); assert.match(renew, /expiresUptime - now <= 300\.001/);
  assert.match(renew, /authorizedAt: max\(0, expiresUptime - 300\)/);
  assert.doesNotMatch(renew, /epoch =|sequence =|telemetryTimes\[|telemetryUptime\[/);
  assert.match(ble, /systemUptime < lease\.authorizedUntil/);
  assert.match(ride, /"authorization_expired"/);
});
check('actual prepare RPC works after real native run and never sets authenticated', () => {
  const prep = ble.slice(ble.indexOf('func prepareRenewalRecipe'), ble.indexOf('func reauthenticate'));
  assert.doesNotMatch(prep, /guard recordingID == nil/);
  assert.match(prep, /options\["recordingId"\] as\? String == id\.uuidString\.lowercased\(\)/);
  assert.match(prep, /setRecordingContext\(id: id/);
  assert.match(ble, /case "ble\.renew\.prepare"/); assert.match(ble, /"recipeComplete": prepared/);
  assert.match(ble, /authorizedUntil: min\(lease\.authorization\.expiresUptime, lease\.issuedUptime \+ 300\), nativeAuthenticated: false/);
});
check('background internal writes are capability-only at enqueue/pump and exported writes stay read-only', () => {
  for (const name of ['enqueue', 'pump']) {
    const start = ble.indexOf(`private func ${name}(`), next = ble.indexOf('\n    private func ', start + 20);
    const body = ble.slice(start, next); assert.match(body, /internalRenewal/); assert.match(body, /renewalCapability/);
    assert.match(body, /applicationState == \.active \|\| internalRenewal/);
  }
  assert.match(ble, /recording_read_only_lease/); assert.match(ble, /if recordingOwnerLease == nil \{ retirePipe\("background_interrupted"/);
  assert.match(ble, /if recordingOwnerLease == nil \{ retirePipe\("stale_navigation"/);
  assert.match(ble, /currentRequest\?\.renewalCapability != nil/);
});
check('generic native recipe consumes fresh native handles and cannot use vendor opcodes or JS auth booleans', () => {
  assert.match(ble, /submitted == prepared/); assert.match(ble, /\$0\.requestIndex == material\.requestIndex && \$0\.path == material\.path && \$0\.type == material\.type/);
  assert.match(engine, /proof\.operationID == id/); assert.match(engine, /sequence > proof\.startSequence, uptime >= proof\.startedUptime/);
  assert.match(engine, /proofChecked/); assert.match(engine, /requirePresent/); assert.match(engine, /seen\.insert\(number\)\.inserted/);
  assert.match(engine, /CharacterSet\.controlCharacters/); assert.match(engine, /kCCOptionECBMode \| kCCOptionPKCS7Padding/);
  assert.doesNotMatch(engine, /command:\s*(90|91|92|93|114|124)\b|encryptInfo|encryptValue|\/vehicleHomePage|markAuth|evalJS/);
  assert.match(engine, /raw\.count/); assert.match(engine, /\(1\.\.\.16\)\.contains\(raw\.count\)/);
});
// Bounded scanner fixture mirrors the actual generic engine's framing; uses actual private wire encoder.
function scanExpected(chunks, expected) {
  let pending = Buffer.alloc(0), found = false;
  for (const chunk of chunks) {
    pending = Buffer.concat([pending, Buffer.from(chunk)]); assert.ok(pending.length <= 512);
    while (pending.length) {
      if (pending.length < 2) { if (pending[0] === 0xab) break; pending = pending.subarray(1); continue; }
      if (pending[0] !== 0xab || pending[1] !== 0xcd) { pending = pending.subarray(1); continue; }
      if (pending.length < 5) break;
      const command = pending[2], length = pending.readUInt16LE(3);
      if (length > 240) { if (command === expected) throw Error('invalid_expected'); pending = pending.subarray(1); continue; }
      const total = length + 7; if (pending.length < total) break;
      const checksum = (command + (length & 255) + (length >> 8) + [...pending.subarray(5, 5 + length)].reduce((a,b) => a + b, 0)) & 255;
      if (pending[total - 2] !== checksum || pending[total - 1] !== 0xcf) {
        if (command === expected) throw Error('invalid_expected'); pending = pending.subarray(1); continue;
      }
      if (command === expected) {
        const payload = pending.subarray(5, 5 + length);
        if (payload.length && !(payload.length === 2 && payload[0] === 8 && [0,1].includes(payload[1]))) throw Error('invalid_expected_payload');
        found = true;
      }
      pending = pending.subarray(total);
    }
  }
  return { found, optionalAbsentAllowed: !found && pending.length === 0, pending: pending.length };
}
check('interleaved actual F3/FD frames leave no spurious tail and optional F2 absence is allowed', () => {
  const f3 = W.bleFrame(243, new Uint8Array([8, 1])), fd = W.bleFrame(253, new Uint8Array([16, 2]));
  for (const chunks of [[f3, fd], [Buffer.concat([f3,fd])], [f3.subarray(0,4), f3.subarray(4), fd]]) {
    assert.deepEqual(scanExpected(chunks, 242), { found: false, optionalAbsentAllowed: true, pending: 0 });
  }
  assert.equal(scanExpected([f3, W.bleFrame(242, new Uint8Array([8,0]))], 242).found, true);
  const bad = Buffer.from(W.bleFrame(242, new Uint8Array([8,0]))); bad[bad.length - 2] ^= 1;
  assert.throws(() => scanExpected([bad], 242), /invalid_expected/);
  assert.throws(() => scanExpected([W.bleFrame(242, new Uint8Array([8,2]))], 242), /invalid_expected_payload/);
  assert.equal(scanExpected([W.bleFrame(242, new Uint8Array()).subarray(0,5)], 242).optionalAbsentAllowed, false);
  assert.match(engine, /acceptingAnyCommand: true/); assert.match(engine, /buffer\.removeFirst\(result\.consumed\)/);
  assert.match(engine, /if frame\.magic\.starts\(with: buffer\)/);
});
check('grant during a combined F3+F2 or F2+F3 callback cannot backdate telemetry admission', () => {
  for (const order of [[243,242], [242,243]]) {
    const l = new LeaseFixture(); const cap = l.changed(); let count = 0;
    const notify = commands => {
      const admittedAtArrival = l.accept(), scope = l.scope, epoch = l.epoch, conn = l.conn;
      for (const command of commands) if (command === 242) l.finish(cap, true);
      if (admittedAtArrival && l.accept() && l.scope === scope && l.epoch === epoch && l.conn === conn)
        count += commands.filter(c => c === 243).length;
    };
    notify(order); assert.equal(count, 0); assert.equal(l.accept(), true);
    notify([243]); assert.equal(count, 1);
  }
  const start = ble.indexOf('let arrivalAdmitted =');
  assert.ok(start >= 0 && start < ble.indexOf('receiveOpaque(Data(data)', start));
  assert.match(ble, /guard arrivalAdmitted, stillAdmitted, arrivalGeneration == epoch/);
  assert.match(ble, /arrivalRecordingEpoch == recordingEpoch, arrivalScope == connectionScope/);
});
check('legacy foreground read-only observation preserves owner 5min window but cannot become native auth or bypass renewal failure', () => {
  const legacy = { actual: true, foreground: true, nativeScope: true, expires: 300, now: 250, bound: false };
  const observable = () => legacy.actual && legacy.foreground && legacy.nativeScope && legacy.now < legacy.expires && !legacy.bound;
  assert.equal(observable(), true); legacy.bound = true; assert.equal(observable(), false);
  legacy.bound = false; legacy.now = 300; assert.equal(observable(), false);
  const body = ble.slice(ble.indexOf('var canObserveTelemetry:'), ble.indexOf('func canObserveTelemetry('));
  assert.match(body, /renewalBoundRecordingID == nil/); assert.match(body, /applicationState == \.active/);
  assert.match(body, /lease\.issuedUptime \+ 300/); assert.doesNotMatch(body, /nativeAuthenticated: true/);
});
console.log(`OK ${groups} offline fixture/source groups; no Swift compiler, device, cloud request, commit or push.`);
