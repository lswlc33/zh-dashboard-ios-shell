"""执行生产 Swift 投屏协议：macOS 必须编译运行；Windows 缺 Swift/Apple SDK 明确 SKIP。

python -I ios-shell/cast-protocol-test.py [--recipe-json private-recipe.json]
默认使用无接收端私有码表的合成配方；--recipe-json 可直接读可信网页 castRecipe() 导出的 JSON。
不创建 socket、不访问车辆/账号、不请求 ReplayKit，不把协议执行通过当设备验收。
"""
import argparse
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile


def extract(source, start, end):
    if source.count(start) != 1 or source.count(end) != 1:
        raise ValueError('production declaration boundary changed: ' + start)
    begin, finish = source.index(start), source.index(end)
    if begin >= finish:
        raise ValueError('production declaration order changed')
    return source[begin:finish]


def production(source):
    # 逐字编译协议/协商/RSA，隔离依赖 iOS App Group、Network 和文件保护的运行时部分。
    # 不替换函数体，不为身份或编码计划提供测试替身。
    error = extract(source, 'enum IOSCastError: Error, LocalizedError {', '    static func network(') + '}\n'
    protocol = extract(source, 'enum IOSCastWire {', 'enum IOSCastTarget {')
    identity = extract(source, 'final class IOSCastIdentity {', '// App Group 只存匿名短期会话')
    return 'import Foundation\nimport CoreFoundation\nimport Security\n\n' + error + protocol + identity


def fixture():
    # 故意不使用 request+1，检验生产执行器按配方指定的非零码表发送。
    return {
        'version': 1,
        'ports': {'data': 21010, 'media': 21011, 'control': 21012, 'probe': 21013},
        'probe': {'requestType': 101, 'responseType': 303, 'requestJSON': '{"phoneType":"${os}"}', 'statusKey': 'status'},
        'control': [
            {'request': 1001, 'action': 'reply', 'replies': [{'type': 4007}]},
            {'request': 1002, 'action': 'rsa', 'inputKeys': ['HUID'], 'replies': [{'type': 4011, 'json': '{"pubkey":"${publicKey}","signature":"${signature}","phoneOs":"${os}"}'}]},
            {'request': 1003, 'action': 'echo', 'defaults': {'sn': ''}, 'replies': [{'type': 4013}, {'type': 4021, 'json': '{"sn":"${input:sn}"}'}]},
            {'request': 1004, 'action': 'ignore', 'replies': []},
        ],
        'media': [{'request': 201, 'action': 'configure', 'reply': 207}, {'request': 301, 'action': 'start', 'reply': 311}],
        'capture': {'minBytes': 32, 'widthOffset': 0, 'heightOffset': 2, 'fpsOffset': 4, 'codecOffset': 8,
                    'bitrateOffset': 20, 'extendedOffset': 29, 'zeroCodec': 2, 'dimensionsOnly': True,
                    'signatureOffset': 32, 'dimensionAlignment': 2,
                    'dimensionAliases': [{'width': 1024, 'height': 488, 'outputHeight': 480}]},
        'captureAck': {'size': 8, 'codecOffset': 0, 'widthOffset': 4, 'heightOffset': 6, 'extendedOffset': -1},
        'fallback': {'width': 1024, 'height': 480, 'fps': 25, 'codec': 2, 'bitrate': 2500000, 'extended': False},
        'tiers': [{'id': 'fixture', 'fps': 25, 'bitrate': 2500000, 'requestedBitrate': False,
                   'widthLimit': 1920, 'heightLimit': 1088, 'maxMacroblocks': 8160, 'compatibilityFPS': False, 'level': 'auto'}],
        'pullCommand': 401,
    }


SWIFT_TESTS = r'''
import Foundation

private struct Failure: Error, CustomStringConvertible { let description: String }

@main
private enum CastProtocolTests {
    static var groups = 0
    static func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(description: message) }
    }
    static func rejects(_ code: String, _ action: () throws -> Void) throws {
        do { try action() } catch {
            try check(IOSCastError.code(error) == code, "expected \(code), got \(error)")
            return
        }
        throw Failure(description: "expected rejection: " + code)
    }
    static func group(_ title: String, _ action: () throws -> Void) throws {
        try action(); groups += 1; print("PASS: " + title)
    }
    static func replace(_ bytes: inout Data, _ value: UInt32, at offset: Int, size: Int) {
        var field = Data(); IOSCastWire.append32(value, to: &field)
        bytes.replaceSubrange(offset..<(offset + size), with: field.prefix(size))
    }
    static func capture(_ recipe: IOSCastRecipe, width: Int, height: Int, signature: Data) -> Data {
        var bytes = Data(repeating: 0, count: recipe.capture.signatureOffset ?? recipe.capture.minBytes)
        replace(&bytes, UInt32(width), at: recipe.capture.widthOffset, size: 2)
        replace(&bytes, UInt32(height), at: recipe.capture.heightOffset, size: 2)
        if recipe.capture.dimensionsOnly != true {
            replace(&bytes, 25, at: recipe.capture.fpsOffset, size: 4)
            replace(&bytes, 2, at: recipe.capture.codecOffset, size: 4)
            replace(&bytes, 2500000, at: recipe.capture.bitrateOffset, size: 4)
        }
        if recipe.capture.signatureOffset != nil { bytes.append(Data(signature.base64EncodedString().utf8)); bytes.append(0) }
        return bytes
    }
    static func main() throws {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
        let recipe = try IOSCastRecipe.from(object)
        let identity = try IOSCastIdentity(bits: recipe.session?.rsaBits ?? 2048)
        var settings = IOSCastSettings(); settings.tier = recipe.tiers[0].id
        let signature = Data(base64Encoded: try identity.sign("fixture-HUID"))!
        // 临时会话公钥/签名交给独立 OpenSSL 恢复，确认线上签名没有多加摘要层。
        let directory = URL(fileURLWithPath: CommandLine.arguments[1]).deletingLastPathComponent()
        try Data(base64Encoded: identity.publicKey)!.write(to: directory.appendingPathComponent("public.der"))
        try signature.write(to: directory.appendingPathComponent("signature.bin"))
        try group("production recipe control opcode table / nonzero identifier / empty ACK / no reply loops") {
            for rule in recipe.control {
                var input: [String: Any] = ["HUID": "fixture-HUID", "huid": "fixture-HUID", "sn": "quote\"-slash\\-测试"]
                for key in rule.inputKeys ?? [] { input[key] = "fixture-HUID" }
                let request = IOSCastWire.Control(type: rule.request, identifier: 0xfedcba98, body: try IOSCastWire.json(input))
                let result = try recipe.controlReplies(rule, frame: request, identity: identity)
                try check(result.frames.count == rule.replies.count, "reply count")
                for (bytes, reply) in zip(result.frames, rule.replies) {
                    let size = try IOSCastWire.controlLength(Data(bytes.prefix(16)))
                    try check(IOSCastWire.u32(bytes, 0) == reply.type, "response opcode must follow recipe")
                    try check(IOSCastWire.u32(bytes, 12) == request.identifier, "identifier truncated")
                    try check(size == bytes.count - 16, "control length")
                    if reply.json == nil { try check(bytes.count == 16, "empty ACK has body") }
                    else { _ = try IOSCastWire.object(Data(bytes.dropFirst(16))) }
                }
                if rule.action == "rsa" { try check(result.signature == signature, "control/media RSA identity diverged") }
            }
            try check(recipe.control.first { $0.request == UInt32.max } == nil, "unknown command fixture collision")
        }
        try group("actual media opcode table / high serial echo") {
            for rule in recipe.media where rule.action != "ignore" {
                guard let response = rule.reply else { throw Failure(description: "missing media reply") }
                let bytes = try IOSCastWire.media(response, serial: 0xfedcba98, body: Data([0x11, 0x80]))
                try check(IOSCastWire.u16(bytes, 0) == response && IOSCastWire.u16(bytes, 2) == 2, "media opcode/length")
                try check(IOSCastWire.u32(bytes, 4) == 0xfedcba98, "media serial truncated")
            }
        }
        try group("actual capture layout / signature / ACK size / changed live dimensions") {
            let bytes = capture(recipe, width: 1024, height: 480, signature: signature)
            let plan = try recipe.capturePlan(bytes, settings: settings, identity: signature)
            let repeated = try recipe.capturePlan(bytes, settings: settings, identity: signature, active: plan)
            try check(repeated == plan, "same configuration rejected")
            let ack = recipe.acknowledgement(plan)
            try check(ack.count == recipe.captureAck.size, "ACK size")
            try check(IOSCastWire.u32(ack, recipe.captureAck.codecOffset) == plan.codec, "ACK codec")
            try check(Int(IOSCastWire.u16(ack, recipe.captureAck.widthOffset)) == plan.width, "ACK width")
            try check(Int(IOSCastWire.u16(ack, recipe.captureAck.heightOffset)) == plan.height, "ACK height")
            try rejects("media_config_changed") {
                _ = try recipe.capturePlan(capture(recipe, width: 800, height: 480, signature: signature), settings: settings, identity: signature, active: plan)
            }
            for alias in recipe.capture.dimensionAliases ?? [] {
                let parsed = try recipe.parseCapture(capture(recipe, width: alias.width, height: alias.height, signature: signature))
                try check(parsed.width == alias.width && parsed.height == alias.outputHeight, "explicit alias was not applied")
            }
            if recipe.capture.signatureOffset != nil {
                try rejects("media_identity_missing") { _ = try recipe.capturePlan(bytes, settings: settings, identity: nil) }
                try rejects("media_identity_mismatch") { _ = try recipe.capturePlan(bytes, settings: settings, identity: Data([1, 2])) }
            }
            try rejects("media_config_invalid") { _ = try recipe.parseCapture(Data(repeating: 0, count: recipe.capture.minBytes - 1)) }
        }
        try group("even canvas 1600x770 / ceil macroblocks / AutoLevel and fixed level / legacy alignment") {
            var value = object
            var layout = value["capture"] as! [String: Any]; layout["dimensionAlignment"] = 2; value["capture"] = layout
            var tiers = value["tiers"] as! [[String: Any]]
            tiers[0]["widthLimit"] = 1920; tiers[0]["heightLimit"] = 1088; tiers[0]["maxMacroblocks"] = 8160
            tiers[0]["fps"] = 25; tiers[0]["level"] = "auto"; value["tiers"] = tiers
            let even = try IOSCastRecipe.from(value)
            let config = IOSCastCapture(width: 1600, height: 770, fps: 25, codec: 2, bitrate: 2500000, extended: false)
            let plan = try even.capturePlan(capture(even, width: 1600, height: 770, signature: signature), settings: settings, identity: signature)
            try check(plan.width == 1600 && plan.height == 770 && plan.level == "auto", "even canvas rounded/cropped or level changed")
            try check(IOSCastPlan.macroblocks(width: 1600, height: 770) == 4900, "macroblocks must ceil")
            try IOSCastPlan.validateLevel("3.2", width: 1600, height: 770, fps: 25)
            try rejects("h264_level_load_invalid") { try IOSCastPlan.validateLevel("3.1", width: 1600, height: 770, fps: 25) }
            let odd = try even.capturePlan(capture(even, width: 855, height: 481, signature: signature), settings: settings, identity: signature)
            try check(odd.width == 854 && odd.height == 480, "odd reported canvas must normalize to even dimensions")
            let oddAck = even.acknowledgement(odd)
            try check(IOSCastWire.u16(oddAck, even.captureAck.widthOffset) == 854 && IOSCastWire.u16(oddAck, even.captureAck.heightOffset) == 480,
                      "odd canvas ACK must match actual encoded dimensions")
            tiers[0]["maxMacroblocks"] = 4800; value["tiers"] = tiers
            let bounded = try IOSCastRecipe.from(value).plan(config, settings)
            try check(IOSCastPlan.macroblocks(width: bounded.width, height: bounded.height) <= 4800, "macroblock cap floored")
            layout.removeValue(forKey: "dimensionAlignment"); value["capture"] = layout
            let legacy = try IOSCastRecipe.from(value).plan(config, settings)
            try check(legacy.width % 16 == 0 && legacy.height % 16 == 0, "legacy alignment changed")
            layout["dimensionAlignment"] = 3; value["capture"] = layout
            try rejects("cast_recipe_invalid") { _ = try IOSCastRecipe.from(value) }
        }
        try group("production H264 AVCC / Annex B / raw and extended pull packet") {
            let avcc = Data([0, 0, 0, 2, 0x65, 0x80])
            let frame = try IOSCastWire.annexB(avcc, allowAnnexB: false)
            try check(frame == Data([0, 0, 0, 1, 0x65, 0x80]), "AVCC conversion")
            for extended in [false, true] {
                let empty = try IOSCastWire.packet(nil, index: UInt32.max, extended: extended)
                try check(empty == Data([0, 0, 0, 0]), "empty pull must be four zeros")
                let packet = try IOSCastWire.packet(frame, index: 0xfedcba98, extended: extended)
                try check(IOSCastWire.u32(packet, 0) == UInt32(frame.count + (extended ? 4 : 0)), "raw packet length")
                if extended { try check(IOSCastWire.u32(packet, 4) == 0xfedcba98, "frame index truncated") }
            }
            try rejects("h264_frame_invalid") { _ = try IOSCastWire.annexB(Data([0, 0, 0, 9, 0x65]), allowAnnexB: false) }
            var header = try IOSCastWire.control(123, identifier: UInt32.max)
            header[8] ^= 1
            try rejects("control_frame_invalid") { _ = try IOSCastWire.controlLength(header) }
        }
        print("PASS: \(groups) production Swift cast protocol groups (ReplayKit / hardware encoder / sockets / vehicle NOT tested)")
    }
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--swiftc')
    parser.add_argument('--require-swift', action='store_true')
    parser.add_argument('--recipe-json', type=pathlib.Path)
    args = parser.parse_args()
    root = pathlib.Path(__file__).resolve().parent
    swift = production((root / 'CastProtocol.swift').read_text(encoding='utf-8-sig'))
    recipe = json.loads(args.recipe_json.read_text(encoding='utf-8-sig')) if args.recipe_json else fixture()
    compiler = shutil.which(args.swiftc or 'swiftc')
    if compiler is None or sys.platform != 'darwin':
        message = 'production Swift cast protocol NOT executed; macOS Swift + Security required'
        if args.require_swift or args.swiftc or sys.platform == 'darwin':
            raise RuntimeError(message)
        print('SKIP: ' + message)
        return
    with tempfile.TemporaryDirectory(prefix='zeeho-cast-protocol-') as directory:
        work = pathlib.Path(directory)
        (work / 'Production.swift').write_text(swift, encoding='utf-8')
        (work / 'Tests.swift').write_text(SWIFT_TESTS, encoding='utf-8')
        (work / 'recipe.json').write_text(json.dumps(recipe, ensure_ascii=False), encoding='utf-8')
        executable = work / 'cast-protocol-test'
        subprocess.run([compiler, '-swift-version', '5', '-parse-as-library', str(work / 'Production.swift'),
                        str(work / 'Tests.swift'), '-o', str(executable)], cwd=work, check=True, timeout=60)
        subprocess.run([str(executable), str(work / 'recipe.json')], cwd=work, check=True, timeout=20)
        openssl = shutil.which('openssl')
        if not openssl:
            raise RuntimeError('OpenSSL required to verify raw RSA interoperability')
        recovered = subprocess.run([openssl, 'pkeyutl', '-verifyrecover', '-pubin', '-keyform', 'DER',
                                    '-inkey', str(work / 'public.der'), '-in', str(work / 'signature.bin'),
                                    '-pkeyopt', 'rsa_padding_mode:pkcs1'],
                                   capture_output=True, check=True, timeout=10).stdout
        if recovered != b'fixture-HUID':
            raise RuntimeError('raw RSA signature changed: recovered payload does not match HUID')
        print('PASS: production Swift signature recovered by independent OpenSSL (raw HUID / PKCS1 type-1)')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print('FAIL: ' + str(error), file=sys.stderr)
        sys.exit(1)
