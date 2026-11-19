// 源码契约 + 可选真实 Swift 执行；没有 Swift 时明确 skip，不用 JS 镜像模型代替。
import assert from 'node:assert/strict';
import { readFileSync, mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';

const read = name => readFileSync(new URL('../ios-shell/Shared/' + name, import.meta.url), 'utf8').replace(/\r\n/g, '\n');
const source = read('WidgetDataSource.swift');
const section = (text, start, end) => {
  const from = text.indexOf(start), to = text.indexOf(end, from + start.length);
  assert.ok(from >= 0 && to > from, `source section: ${start}`);
  return text.slice(from, to);
};
const load = section(source, 'public static func load(', 'public static func loadLocal(');
const local = section(source, 'public static func loadLocal(', 'private static func preferredLocal(');
const select = section(source, 'private static func preferredLocal(', 'private static func coreSampleTime(');
const clock = section(source, 'private static func coreSampleTime(', 'private static func currentSnapshot(');
let groups = 0;
function check(name, body) { body(); console.log(`PASS source ${++groups}: ${name}`); }
check('load 命中、失败及 loadLocal 共用整份选取', () => {
  assert.equal((load.match(/return preferredLocal\(cached,/g) || []).length, 2);
  assert.equal((local.match(/return preferredLocal\(cached,/g) || []).length, 1);
  assert.doesNotMatch(load + local, /origin: \.cache/);
  assert.match(select, /return host/);
  assert.match(select, /WidgetDataSourceResult\(snapshot: (?:SystemSnapshotStore\.applyingDualDisplay\(cached\)|cached), origin: \.cache, reason: reason/);
  assert.doesNotMatch(select, /SystemSnapshot\(|SystemVehicleSnapshot\(|WidgetFetchCache\.write/);
});
check('合法同完整 owner 才能比较，cache 补做 schema 校验', () => {
  assert.match(select, /cached\.validated\(expectedOwner: owner, now: date\)/);
  assert.match(select, /snapshot\.owner == owner/);
  assert.match(select, /host\.snapshot\.map\(\{ \$0\.owner == owner \}\) \?\? true/);
  assert.ok(select.indexOf('cached.validated') < select.indexOf('let hostTime'));
});
check('核心字段各自实际时间择新，排除骑行/统计/容器时间', () => {
  for (const [value, time] of [['socPercent', 'socUpdatedAt'], ['charging', 'chargingUpdatedAt'],
    ['chargeProgressPercent', 'chargeProgressUpdatedAt']]) {
    assert.ok(clock.includes(`vehicle.${value} == nil ? nil : vehicle.${time}`));
  }
  const code = clock.replace(/\/\/[^\n]*/g, '');
  assert.doesNotMatch(code, /capturedAt|\.updatedAt|statsUpdatedAt|\.ride|\.gauge/);
  assert.match(clock, /\.compactMap \{ \$0 \}\.max\(\)/);
  assert.match(select, /hostTime > \(coreSampleTime\(cached\) \?\? 0\)/);
});
check('await 成功/失败之前及最终交付前仍全量核验凭据', () => {
  const boundary = section(load, 'let result = await', 'switch result');
  for (const text of [boundary, select]) {
    assert.match(text, /SystemSnapshotStore\.currentOwner\(\)/);
    assert.match(text, /WidgetCredentialStore\.read\(at: (completedAt|date)\) == credential/);
    assert.match(text, /return currentSnapshot\(at: (completedAt|date), reason: "stale_credential"\)/);
  }
  assert.match(boundary, /currentOwner == activeOwner/);
  assert.match(select, /SystemSnapshotStore\.currentOwner\(\)\) == owner/);
  assert.ok(select.indexOf('WidgetCredentialStore.read') < select.indexOf('cached.validated'));
  assert.match(local, /WidgetCredentialStore\.read\(at: date\) == credential/);
});
check('live 继续拒绝空核心，写入缓存保留完整 owner', () => {
  assert.match(load, /if !vehicle\.hasCoreMeasurements/);
  assert.match(load, /makeSnapshot\(vehicle, credential: credential, owner: currentOwner,/);
  const make = source.slice(source.indexOf('private static func makeSnapshot('));
  assert.match(make, /owner: SystemSnapshotOwner/);
  assert.match(make, /owner\.isValid, owner\.ownerIdentifierString == credential\.ownerID/);
  assert.match(make, /SystemSnapshot\(owner: owner/);
  assert.doesNotMatch(make, /SystemSnapshotStore\.ownerIdentifier\(/);
  assert.match(source, /SystemSnapshotStore\.readCurrent\(now: date\)/);
});

// 下方 fixture 只替代磁盘/网络 I/O；schema、凭据、fetch 数据类型和整个 DataSource
// 均直接使用生产 Swift 源码。fixture 不重写择新/授权逻辑，不发真实请求。
const compiler = process.env.SWIFTC || 'swiftc';
const probe = spawnSync(compiler, ['--version'], { encoding: 'utf8' });
if (probe.error?.code === 'ENOENT') {
  console.log(`SKIP real Swift boundary tests: ${compiler} unavailable; ${groups} source contract groups passed. No Swift runtime/Xcode/device claim.`);
  if (process.argv.includes('--require-swift')) process.exitCode = 1;
} else {
  assert.equal(probe.status, 0, probe.stderr || probe.error?.message);
  const credential = section(read('WidgetCredential.swift'), 'public struct WidgetCredential:', '/// App Group 里的凭据存储');
  const client = section(read('WidgetVehicleClient.swift'), 'public struct WidgetFetchedVehicle:', '/// 扩展进程里的取数器');
  const fixture = String.raw`
// 可替换的 I/O 边界；全部为合成数据。
enum SystemSnapshotStore {
    static var active: SystemSnapshotOwner? = ownerA
    static var host: SystemSnapshot?
    static var onHostRead: (() -> Void)?
    static func currentOwner() throws -> SystemSnapshotOwner? { active }
    static func readCurrent(now: Date) throws -> SystemSnapshot? {
        onHostRead?(); onHostRead = nil
        guard let active = active, let host = host else { return nil }
        return try host.validated(expectedOwner: active, now: now)
    }
    // 固定单电（false）：本测试只校验择新/授权，倍率投影另有 Widget 契约覆盖。
    static func dualDisplay(expectedOwner: SystemSnapshotOwner) -> Bool { false }
    static func applyingDualDisplay(_ snapshot: SystemSnapshot?) -> SystemSnapshot? { snapshot }
    static func ownerIdentifier(_ id: String) -> SystemSnapshotOwner? {
        let parts = id.split(separator: ".")
        guard parts.count == 2 else { return nil }
        return SystemSnapshotOwner(scopeID: String(parts[1]), accountVINHash: String(parts[0]))
    }
}
enum WidgetCredentialStore {
    static var value: WidgetCredential? = credentialA
    static func read(at date: Date) -> WidgetCredential? {
        guard let value = value, value.isUsable(at: date) else { return nil }
        return value
    }
}
enum WidgetFetchCache {
    static var value: SystemSnapshot?
    static var writes = 0
    static func read(ownerID: String, at date: Date, maxAgeSeconds: Double) -> SystemSnapshot? {
        guard let value = value, value.owner.ownerIdentifierString == ownerID, value.vehicle != nil,
              SystemSnapshotFreshness.isFresh(value.capturedAt, at: date, maxAgeSeconds: maxAgeSeconds) else { return nil }
        return value
    }
    static func write(_ snapshot: SystemSnapshot) { value = snapshot; writes += 1 }
}
enum WidgetVehicleClient {
    static var reply: Result<WidgetFetchedVehicle, WidgetFetchError> = .failure(.network)
    static var onFetch: (() -> Void)?
    static var calls = 0
    static func fetch(_ credential: WidgetCredential, at date: Date) async -> Result<WidgetFetchedVehicle, WidgetFetchError> {
        calls += 1; onFetch?(); onFetch = nil; return reply
    }
}
let now = Date()
let ms = Int64(now.timeIntervalSince1970 * 1000)
let ownerA = SystemSnapshotOwner(scopeID: "car-A", accountVINHash: String(repeating: "a", count: 64), accountHash: String(repeating: "b", count: 64))
let ownerB = SystemSnapshotOwner(scopeID: "car-B", accountVINHash: String(repeating: "c", count: 64), accountHash: ownerA.accountHash)
let credentialA = WidgetCredential(ownerID: ownerA.ownerIdentifierString, vin: "SYNTHETICVINA", token: "synthetic-token", appID: "synthetic-app", appSecret: "synthetic-secret", updatedAt: ms)
func snapshot(_ age: Int64?, owner: SystemSnapshotOwner = ownerA, capturedAge: Int64 = 0,
              statsAge: Int64? = nil, invalid: Bool = false) -> SystemSnapshot {
    let core = age.map { ms - $0 }
    return SystemSnapshot(owner: owner, capturedAt: ms - capturedAge, expiresAt: ms - capturedAge + 900_000,
        vehicle: SystemVehicleSnapshot(socPercent: age == nil ? nil : (invalid ? 101 : 55), socUpdatedAt: core,
            updatedAt: max(core ?? 0, statsAge.map { ms - $0 } ?? 0),
            integral: statsAge == nil ? nil : 8, statsUpdatedAt: statsAge.map { ms - $0 }))
}
func reset(_ cached: SystemSnapshot?, _ host: SystemSnapshot?) {
    SystemSnapshotStore.active = ownerA; SystemSnapshotStore.host = host; SystemSnapshotStore.onHostRead = nil
    WidgetCredentialStore.value = credentialA; WidgetFetchCache.value = cached; WidgetFetchCache.writes = 0
    WidgetVehicleClient.calls = 0; WidgetVehicleClient.onFetch = nil; WidgetVehicleClient.reply = .failure(.network)
}
func run(_ mode: Int) async -> WidgetDataSourceResult {
    if mode == 1 { return WidgetDataSource.loadLocal(at: now) }
    return await WidgetDataSource.load(at: now, force: mode == 2)
}
@main struct ContractTests {
    static func main() async {
        var count = 0
        func expect(_ result: WidgetDataSourceResult, _ selected: SystemSnapshot?, _ origin: WidgetDataSourceResult.Origin, _ label: String) {
            precondition(result.snapshot == selected && result.origin == origin, label)
            count += 1
        }
        // 每条场景都跑 load 命中、loadLocal 和强制请求失败兜底。
        for mode in 0...2 {
            let old = snapshot(600_000, capturedAge: 500_000), fresh = snapshot(60_000)
            reset(old, fresh); expect(await run(mode), fresh, .snapshot, "new host / old cache")
            reset(fresh, old); expect(await run(mode), fresh, .cache, "new cache / old host")
            reset(fresh, nil); expect(await run(mode), fresh, .cache, "no host")
            reset(fresh, fresh); expect(await run(mode), fresh, .cache, "equal core time keeps cache")
            let boosted = snapshot(700_000, statsAge: 0)
            reset(boosted, fresh); expect(await run(mode), fresh, .snapshot, "cache stats do not refresh core")
            reset(fresh, boosted); expect(await run(mode), fresh, .cache, "host stats do not refresh core")
            let rideBoosted = SystemSnapshot(owner: ownerA, capturedAt: ms, expiresAt: ms + 900_000,
                vehicle: old.vehicle, ride: SystemRideSnapshot(state: .recording, startedAt: ms - 900_000,
                    updatedAt: ms, speedKph: 15, speedUpdatedAt: ms))
            reset(rideBoosted, fresh); expect(await run(mode), fresh, .snapshot, "cache ride does not refresh core")
            reset(fresh, rideBoosted); expect(await run(mode), fresh, .cache, "host ride does not refresh core")
            for vehicle in [SystemVehicleSnapshot(charging: false, chargingUpdatedAt: ms - 1_000, updatedAt: ms - 1_000),
                            SystemVehicleSnapshot(chargeProgressPercent: 20, chargeProgressUpdatedAt: ms - 1_000, updatedAt: ms - 1_000)] {
                let charging = SystemSnapshot(owner: ownerA, capturedAt: ms, expiresAt: ms + 900_000, vehicle: vehicle)
                reset(fresh, charging); expect(await run(mode), charging, .snapshot, "charging/progress sample time")
            }
            let onlyStats = snapshot(nil, statsAge: 0)
            reset(onlyStats, fresh); expect(await run(mode), fresh, .snapshot, "missing cache core time")
            reset(fresh, onlyStats); expect(await run(mode), fresh, .cache, "missing host core time")
            reset(snapshot(10_000, invalid: true), old); expect(await run(mode), old, .snapshot, "invalid cache")
            let sameIDOtherAccount = SystemSnapshotOwner(scopeID: ownerA.scopeID, accountVINHash: ownerA.accountVINHash, accountHash: String(repeating: "d", count: 64))
            reset(snapshot(10_000, owner: sameIDOtherAccount), old)
            expect(await run(mode), old, .snapshot, "same short ID is not complete owner")
            reset(snapshot(10_000, owner: ownerB), old)
            expect(await run(mode), old, .snapshot, "other vehicle cache")
            reset(fresh, snapshot(10_000, owner: ownerB))
            expect(await run(mode), fresh, .cache, "invalid host owner cannot enter comparison")
            reset(fresh, nil); WidgetCredentialStore.value = nil
            expect(await run(mode), nil, .none, "revoked credential cannot deliver cache")
            reset(fresh, fresh); SystemSnapshotStore.active = nil
            expect(await run(mode), nil, .none, "revoked owner cannot deliver either")
            reset(fresh, old); SystemSnapshotStore.onHostRead = { WidgetCredentialStore.value = nil }
            let revoked = await run(mode)
            expect(revoked, old, .snapshot, "revoked during host read falls back only to host")
            precondition(revoked.reason == "stale_credential")
            reset(fresh, old); SystemSnapshotStore.onHostRead = { SystemSnapshotStore.active = ownerB; SystemSnapshotStore.host = nil }
            expect(await run(mode), nil, .none, "vehicle switch during host read")
            if mode == 2 {
                reset(old, fresh); let failed = await run(mode)
                precondition(failed.reason == "network" && WidgetVehicleClient.calls == 1 && WidgetFetchCache.writes == 0)
            }
        }
        // await 返回前同 owner 的任何凭据字段改变，都不许写入/交付旧凭据缓存。
        for key in 0...5 {
            reset(snapshot(10_000), nil)
            WidgetVehicleClient.onFetch = {
                var changed = credentialA
                switch key {
                case 0: changed.ownerID = ownerB.ownerIdentifierString
                case 1: changed.vin += "B"
                case 2: changed.token += "B"
                case 3: changed.appID += "B"
                case 4: changed.appSecret += "B"
                default: changed.updatedAt += 1
                }
                WidgetCredentialStore.value = changed
            }
            let changed = await run(2)
            expect(changed, nil, .none, "complete credential recheck after await")
            precondition(changed.reason == "stale_credential" && WidgetFetchCache.writes == 0)
        }
        reset(nil, nil)
        WidgetVehicleClient.reply = .success(WidgetFetchedVehicle(socPercent: 66, sampledAt: ms))
        let live = await run(2)
        precondition(live.origin == .live && live.snapshot?.owner == ownerA && WidgetFetchCache.value?.owner == ownerA)
        count += 1
        print("PASS real Swift DataSource boundary assertions: \(count); I/O fixtures only, no Apple runtime/device")
    }
}
`;
  const temp = mkdtempSync(join(tmpdir(), 'ios-widget-data-source-'));
  try {
    const input = join(temp, 'contract.swift'), binary = join(temp, process.platform === 'win32' ? 'contract.exe' : 'contract');
    writeFileSync(input, [read('SystemSnapshot.swift'), credential, client, source, fixture].join('\n'));
    const built = spawnSync(compiler, ['-swift-version', '5', '-parse-as-library', input, '-o', binary], { encoding: 'utf8', timeout: 120_000 });
    assert.equal(built.status, 0, built.stdout + built.stderr + (built.error?.message || ''));
    const ran = spawnSync(binary, [], { encoding: 'utf8', timeout: 30_000 });
    assert.equal(ran.status, 0, ran.stdout + ran.stderr + (ran.error?.message || ''));
    process.stdout.write(ran.stdout);
  } finally { rmSync(temp, { recursive: true, force: true }); }
}
