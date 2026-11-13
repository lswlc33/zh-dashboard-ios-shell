// 真实私有 JS 的离线回执/边界检查；不联网，不运行 Swift，不证明 Xcode/设备已通过。
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import { webcrypto, createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
const root = fileURLToPath(new URL('../', import.meta.url));
const files = ['sign.js', 'vehicle-wire.js', 'ios-vehicle-driver.js'];
const scope = { navId: 'fixture-nav', frame: 'fixture-frame', epoch: 7, generation: 3, accountId: 'fixture-account', vin: 'FIXTUREVIN' };
const recordID = '33333333-3333-4333-8333-333333333333';
const lease = { ok: true, leaseId: 'fixture-lease', generation: '11111111-1111-4111-8111-111111111111',
  connected: true, id: '22222222-2222-4222-8222-222222222222', notifySeq: 0, identifierKind: 'corebluetooth_uuid' };
const noop = () => { throw new Error('sensitive_sink_used'); };
let passed = 0;
async function check(name, action) { await action(); passed++; console.log('ok ' + name); }
function fixture({ missing = '', preparedOnly = false, wrongID = false, receiptFailure = false, cancelledConfirmation = false, mutateOnImport = false } = {}) {
  let time = 100000, seq = 0, nativeSeq = 0, current = true, credentialRev = 1, pendingPoll = null;
  const calls = [], imported = [], commands = [], queue = [], nativeActions = [];
  const s = { Uint8Array, DataView, TextEncoder, TextDecoder, btoa, atob, crypto: webcrypto, AbortController, setTimeout, clearTimeout,
    document: { hidden: false, createElement: noop, getElementById: noop }, localStorage: { setItem: noop, getItem: noop },
    console: { log: noop, warn: noop, error: noop }, DIAG: { add: noop, rec: noop }, STORE: { set: noop }, Group: { set: noop } };
  s.window = s; vm.createContext(s);
  for (const file of files) vm.runInContext(readFileSync(root + 'public/js/' + file, 'utf8'), s, { filename: file });
  const W = s.VehicleWire;
  const material = { key: 'fixture-aes-key!', iv: 'fixture-only-iv!', encryptValue: 'ab'.repeat(64) };
  const home = { vinNo: scope.vin, bindingUserId: 'fixture-uid', sharedFlag: 0, bluetoothAddress: 'AA:BB:CC:DD:EE:FF',
    inductiveUnlocking2: 1, encryptInfo: { ...material } };
  const settings = { ...home, encryptInfo: { ...material } };
  const ctx = { navId: scope.navId, frame: scope.frame, scope: { ...scope }, isCurrent: () => current };
  const credential = () => ({ accountId: scope.accountId, uid: 'fixture-uid', token: 'fixture-only-token', credentialRev });
  s.ACC = { byId: () => ({ id: scope.accountId, ...credential() }), current: value => value.credentialRev === credentialRev
    && value.id === scope.accountId && value.token === credential().token && value.uid === credential().uid };
  s.APP = { context: () => ({ vin: scope.vin, owner: { id: scope.accountId } }) };
  const snapshot = (extra = {}) => ({ ok: true, state: preparedOnly ? 'prepared' : 'active', recordingId: wrongID ? '99999999-9999-4999-8999-999999999999' : recordID.toUpperCase(),
    active: !preparedOnly, attachedNative: !preparedOnly, consented: true, recipeComplete: !preparedOnly, backgroundAuthRenewalSupported: !preparedOnly,
    authorizationFresh: !preparedOnly, nativeAuthenticated: !preparedOnly, canAcceptTelemetry: !preparedOnly,
    authorizationRemainingMs: preparedOnly ? 0 : 300000, connectionGeneration: lease.generation, ...extra });
  const notification = (command, payload) => {
    queue.push({ valueB64: W.base64(W.bleFrame(command, payload)), seq: ++seq, at: time, generation: lease.generation,
      characteristic: '0000B357-D6D8-C7EC-BDF0-EAB1BFC6BCBC' });
  };
  const bridge = { available: () => true, isCurrent: () => current, has: method => method !== missing, async call(method, ...args) {
    const a = args[0] || {}; calls.push({ method, args });
    if (method === 'ble.open') return { ...lease };
    if (method === 'ble.close' || method === 'secret.release' || method === 'session.renew.cancel') return { ok: true };
    if (method === 'ble.exchange') {
      const command = new W.BLEStream().feed(W.unbase64(a.valueB64))[0].command; commands.push(command);
      notification(command === 90 ? 91 : command === 92 ? 93 : command === 124 ? 252 : 242,
        command === 90 ? W.bytesField(1, W.utf8('00'.repeat(16))) : command === 92 ? W.intField(1, 0) : new Uint8Array());
      return { ok: true, operationId: a.operationId, leaseId: lease.leaseId, generation: lease.generation,
        notifications: queue.filter(n => n.seq > a.afterSeq) };
    }
    if (method === 'ble.poll') return { ok: true, generation: lease.generation, notifications: queue.filter(n => n.seq > a.afterSeq) };
    if (method === 'crypto.aes.decrypt') return { ok: true, plainB64: W.base64(W.utf8('fixture-challenge')) };
    if (method === 'ui.confirm') return { ok: true, confirmed: !cancelledConfirmation, operation: a.operation, scope: { ...scope } };
    if (method === 'secret.import') {
      assert.equal(a.importBase64.length > 0, true); assert.equal(a.type, 'string'); assert.ok(['signer', 'token', 'baseline'].includes(a.purpose));
      assert.equal(a.epoch, scope.epoch); assert.equal(a.frame, scope.frame); assert.equal(a.navigationId, scope.navId);
      const body = W.unbase64(a.importBase64, 32767);
      const handle = `44444444-4444-4444-8444-${String(++nativeSeq).padStart(12, '0')}`;
      imported.push({ handle, purpose: a.purpose, body: Buffer.from(body).toString('utf8') }); body.fill(0);
      if (mutateOnImport) credentialRev++;
      return { ok: true, handle };
    }
    if (method === 'ble.renew.prepare') return { ok: true, prepared: true, recipeComplete: true, leaseId: lease.leaseId,
      generation: lease.generation, recordingId: recordID, authenticated: false, backgroundGuaranteed: false };
    if (method === 'session.renew.prepare') return snapshot();
    if (method === 'session.renew.poll') { if (pendingPoll) { const reply = pendingPoll; pendingPoll = null; return reply; } return snapshot(); }
    if (method === 'compat.call') return receiptFailure ? { ok: false, accepted: false, ticket: 'ride-ticket', recordingId: recordID }
      : { ok: true, accepted: true, ticket: 'ride-ticket', recordingId: recordID, recordState: 'recording', recordedSamples: 3,
        authenticated: true, nativeAuthenticated: true, authorizationFresh: true, canAcceptTelemetry: true,
        connected: true, connectionGeneration: lease.generation, telemetry: { speedKph: 0 }, telemetryTimes: { speedKph: time } };
    return { ok: true };
  } };
  s.IOSBR = bridge;
  const cloud = async endpoint => { calls.push({ method: 'cloud.' + endpoint }); return endpoint === 'home' ? home
    : endpoint === 'settings' ? settings : [{ functionCode: 'INDUCTIVE_UNLOCKING_2', isSupport: 1 }]; };
  const driver = s.IOSVehicleDriver.create({ bridge, cloud, selectPeripheral: async () => lease.id, now: () => time,
    delay: async ms => { time += ms; }, foreground: () => true });
  return { s, W, ctx, driver, calls, imported, commands, nativeActions,
    start: () => driver.call('beginRideRecording', [scope.navId, scope.vin, scope.frame, false], ctx),
    poll: () => driver.call('pollRideRecording', [scope.navId, 'ride-ticket'], ctx),
    stop: () => driver.call('rideRecordingAction', [scope.navId, 'ride-ticket', 'stop'], ctx),
    time: ms => { time += ms; }, stale: () => { current = false; }, revokeCredential: () => { credentialRev++; },
    reply: value => { pendingPoll = snapshot(value); },
    nativeRound: changed => { nativeActions.push(changed ? 'native_material_reauthentication' : 'native_window_extension'); pendingPoll = snapshot(); } };
}
await check('signer importer requires actual bridge, scope, and confirmation; bytes are scrubbed', async () => {
  const f = fixture(), sign = f.s.ZEEHO_SIGN; let used = 0, held;
  const args = { bridge: f.s.IOSBR, scope, confirmation: { confirmed: true, operation: 'session_renewal', scope: { ...scope } },
    isCurrent: () => true, importNativeSecret: async bytes => { used++; held = bytes; return '44444444-4444-4444-8444-444444444444'; } };
  await assert.rejects(sign.createNativeSigner({ ...args, bridge: { ...f.s.IOSBR } }), /native_signer_unavailable/);
  await assert.rejects(sign.createNativeSigner({ ...args, confirmation: { ...args.confirmation, scope: { ...scope, epoch: 6 } } }), /native_signer_unavailable/);
  await assert.rejects(sign.createNativeSigner({ ...args, confirmation: { ...args.confirmation, confirmed: false } }), /native_signer_unavailable/);
  assert.equal(used, 0);
  const value = await sign.createNativeSigner(args); assert.equal(value.signerSpec.appId, sign.APP_ID); assert.ok(held.every(v => v === 0));
  assert.equal('APP_SECRET' in sign, false); assert.equal(JSON.stringify(value).includes('fixture-only-token'), false);
  await f.driver.dispose();
});
await check('native secret imports precede only real recording ID binding; descriptor is existing GET signer', async () => {
  const f = fixture(), result = await f.start();
  assert.equal(result.recordingId, recordID); assert.equal(result.backgroundAuthRenewalSupported, true);
  const begin = f.calls.findIndex(c => c.method === 'compat.call');
  assert.ok(f.calls.findIndex(c => c.method === 'secret.import') > begin);
  assert.equal(f.imported.length, 6, 'deduplicated signer + token + four material baselines');
  const prepared = f.calls.find(c => c.method === 'session.renew.prepare').args[0];
  assert.equal(prepared.recordingId, recordID); assert.equal(prepared.recipe.requests.length, 2);
  assert.equal(prepared.recipe.intervalMs, 240000); assert.equal(prepared.recipe.validityMs, 300000);
  assert.ok(prepared.recipe.requests.every(r => r.method === 'GET' && r.url.startsWith('https://tapi.zeehoev.com/')));
  assert.ok(prepared.recipe.requests.every(r => r.validation.filter(v => r.materialPaths.some(p => JSON.stringify(p) === JSON.stringify(v.path)))
    .every(v => v.type === 'string' && typeof v.equals.secretBaselineRef === 'string')));
  const raw = JSON.stringify(prepared); for (const imported of f.imported) assert.equal(raw.includes(imported.body), false);
  assert.ok(f.calls.filter(c => c.method === 'secret.import').every(c => c.args[0].importBase64 === ''), 'caller drops transient base64 after import');
  const signed = f.s.ZEEHO_SIGN.sign('app', { z: 'raw space', empty: '', a: 1 }), secret = f.imported.find(i => i.purpose === 'signer').body;
  const sha = createHash('sha1').update(f.s.ZEEHO_SIGN.toQuery({ z: 'raw space', empty: '', a: 1 }) + signed.param + secret).digest('hex');
  assert.equal(signed.sign, createHash('md5').update(sha).digest('hex')); assert.match(signed.nonce.slice(String(signed.ts).length), /^[0-9A-Za-z]{16}$/);
  await f.stop();
  assert.equal(f.calls.filter(c => c.method === 'session.renew.cancel').length, 1);
  assert.equal(f.calls.filter(c => c.method === 'secret.release').length, f.imported.length);
});
await check('private 16-step recipe uses exact existing frames, explicit result zero, bounded plaintext', async () => {
  const f = fixture(); await f.start(); const recipe = f.calls.find(c => c.method === 'ble.renew.prepare').args[0].recipe;
  assert.equal(recipe.steps.length, 16); assert.deepEqual(Array.from(recipe.steps.filter(s => s.op === 'write'), s => s.command), [90, 92, 124, 114]);
  const writes = recipe.steps.filter(s => s.op === 'write');
  for (const write of writes) {
    assert.equal(write.frame.magicHex, 'abcd'); assert.equal(write.frame.tailHex, 'cf'); assert.equal(write.frame.lengthOffset, 3);
    assert.equal(write.frame.payloadOffset, 5); assert.equal(write.frame.maxPayload, 240); assert.equal('sequenceOffset' in write.frame, false);
  }
  const explicit = recipe.steps.find(s => s.op === 'protobufExtract' && s.from === 'result');
  assert.equal(explicit.kind, 'varint'); assert.equal(explicit.requirePresent, true);
  assert.equal(recipe.steps.find(s => s.op === 'checkEqual').right.hex, '00');
  const aes = recipe.steps.find(s => s.op === 'aes'); assert.equal(aes.outputUTF8.noControls, true); assert.equal(aes.outputUTF8.maxBytes, 128);
  assert.equal(recipe.steps.at(-1).optional, true); assert.equal(recipe.steps.at(-3).payloadValidation.kind, 'empty');
  assert.throws(() => f.W.authResult(new Uint8Array()), /auth_rejected/);
  await f.driver.dispose();
});
await check('unchanged material renews only native window; no JS cloud or GATT reconnect', async () => {
  const f = fixture(); await f.start(); const before = f.calls.length; f.time(240000); f.nativeRound(false);
  assert.equal((await f.poll()).backgroundAuthRenewalSupported, true);
  assert.ok(f.calls.slice(before).every(c => !c.method.startsWith('cloud.') && c.method !== 'ble.open' && c.method !== 'ble.exchange'));
  assert.deepEqual(f.nativeActions, ['native_window_extension']); f.time(70000); assert.equal((await f.poll()).authenticated, true);
  await f.driver.dispose();
});
await check('changed material is native-only action and telemetry requires fresh actual receipt', async () => {
  const f = fixture(); await f.start(); const before = f.calls.length; f.nativeRound(true); f.reply({ active: false, nativeAuthenticated: false, canAcceptTelemetry: false, state: 'reauthenticating' });
  const gap = await f.poll(); assert.equal(gap.authenticated, false); assert.deepEqual(f.nativeActions, ['native_material_reauthentication']);
  f.reply({ active: true, nativeAuthenticated: true, canAcceptTelemetry: true }); assert.equal((await f.poll()).authenticated, true);
  assert.ok(f.calls.slice(before).every(c => c.method !== 'ble.open' && c.method !== 'ble.exchange' && !c.method.startsWith('cloud.')));
  await f.driver.dispose();
});
await check('prepared/accepted alone, past scope, or wrong recording never claim support', async () => {
  for (const options of [{ preparedOnly: true }, { wrongID: true }, { mutateOnImport: true }, { cancelledConfirmation: true }]) {
    const f = fixture(options); assert.equal((await f.start()).backgroundAuthRenewalSupported, false);
    assert.ok(!f.calls.some(c => c.method === 'ble.open' && c.args[0].purpose === 'renewal')); await f.driver.dispose();
  }
  const f = fixture(); await f.start(); f.stale(); await assert.rejects(f.poll(), /stale_session/); await f.driver.dispose();
});
await check('old native primitive absent keeps foreground and support false; failed recording imports nothing', async () => {
  const f = fixture({ missing: 'session.renew.prepare' }); assert.equal(f.driver.has('beginInductiveSession'), true);
  assert.equal((await f.start()).backgroundAuthRenewalSupported, false); assert.deepEqual(f.commands, [90, 92, 124, 114]); assert.equal(f.imported.length, 0); await f.driver.dispose();
  const failed = fixture({ receiptFailure: true }); await assert.rejects(failed.start(), /native_failed|recording_receipt_invalid/); assert.equal(failed.imported.length, 0); await failed.driver.dispose();
});
await check('restore uses current native recording receipt only; no import, prepare, cloud or BLE reconnect', async () => {
  const f = fixture();
  const result = await f.driver.call('restoreRideRecording', [scope.navId, 'ride-ticket'], f.ctx);
  assert.equal(result.backgroundAuthRenewalSupported, true); assert.equal(result.authenticated, true); assert.equal(result.telemetry.speedKph, 0);
  assert.ok(f.calls.every(c => ['compat.call', 'session.renew.poll'].includes(c.method))); assert.equal(f.imported.length, 0);
  f.reply({ recordingId: '99999999-9999-4999-8999-999999999999' }); await assert.rejects(f.poll(), /renewal_receipt_invalid/);
  await f.stop(); assert.ok(f.calls.some(c => c.method === 'session.renew.cancel'));
  const old = fixture({ missing: 'session.renew.poll' });
  assert.equal((await old.driver.call('restoreRideRecording', [scope.navId, 'ride-ticket'], old.ctx)).backgroundAuthRenewalSupported, false);
  await old.driver.dispose(); await f.driver.dispose();
});
console.log(`ios renewal driver: ${passed} local JS groups passed; no Swift/Xcode/device verification`);
