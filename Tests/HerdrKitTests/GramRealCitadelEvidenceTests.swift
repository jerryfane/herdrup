import XCTest
import Foundation
import Dispatch
import Crypto
import HerdrKit

/// Temporary, opt-in hosted Linux evidence. The runner owns the disposable daemon,
/// SSH account/keys and network emulator; this consumer uses only public APIs.
final class GramRealCitadelEvidenceTests: XCTestCase {
    func testRealCitadelRoundTrip() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["GRAM_EVIDENCE_ENABLE"] == "1" else {
            throw XCTSkip("Disposable real-Citadel evidence is not enabled")
        }

        var stage = "configuration"
        var transport: CitadelTransport?
        var payloadDirectory: URL?
        var receiptURL: URL?
        var receipt: [String: Any] = [
            "schema_version": 1,
            "status": "running",
            "label": "measured real Citadel Linux; emulated RTT120ms/100Mbit; not phone/relay",
            "transport": "production HerdrClient + CitadelTransport over loopback SSH",
            "network": ["emulated_rtt_ms": 120, "bandwidth_mbit_per_second": 100],
            "timing_clock": "DispatchTime monotonic uptime",
            "timing_notes": "First-use ping is separate. Upload is the first upload after ping; finalize is gramPost only. Full download precedes chunked download; neither is a cold-cache claim. Payload generation and checksum verification are outside API timings.",
            "upload_path": "Selected by production capability handling; not overridden or instrumented by this test",
            "test_retries": 0,
        ]
        defer {
            if let payloadDirectory {
                try? FileManager.default.removeItem(at: payloadDirectory)
            }
        }

        do {
            #if !os(Linux)
            throw EvidenceFailure("This enabled evidence consumer requires Linux")
            #endif
            receiptURL = URL(fileURLWithPath: try required("GRAM_EVIDENCE_RECEIPT", in: environment))
            let host = try required("GRAM_EVIDENCE_HOST", in: environment)
            guard host == "127.0.0.1" else {
                throw EvidenceFailure("TOFU is permitted only for the disposable IPv4 loopback endpoint")
            }
            guard let port = UInt16(try required("GRAM_EVIDENCE_PORT", in: environment)), port != 0 else {
                throw EvidenceFailure("GRAM_EVIDENCE_PORT must be a nonzero UInt16")
            }
            guard try required("GRAM_EVIDENCE_SIZES", in: environment) == "10" else {
                throw EvidenceFailure("GRAM_EVIDENCE_SIZES must be 10 (exactly 10485760 bytes)")
            }
            receipt["app_sha"] = try revision("GRAM_EVIDENCE_APP_SHA", in: environment)
            receipt["server_sha"] = try revision("GRAM_EVIDENCE_SERVER_SHA", in: environment)
            let username = try required("GRAM_EVIDENCE_USER", in: environment)
            let keyPath = try required("GRAM_EVIDENCE_PRIVATE_KEY_FILE", in: environment)

            stage = "read_ephemeral_private_key"
            let pem = try String(contentsOfFile: keyPath, encoding: .utf8)
            guard !pem.isEmpty else { throw EvidenceFailure("Ephemeral private key is empty") }
            let credentials = SSHCredentials(host: host, port: port, username: username,
                                             privateKeyPEM: pem, remoteSocketPath: "")
            // The host is checked above BEFORE constructing the production TOFU policy.
            // No shared pin store, persistent credentials or accept-anything validator.
            let policy = PinningHostKeyPolicy(store: PinningHostKeyPolicy.PinStore())
            let connection = CitadelTransport(credentials: credentials, hostKeyPolicy: policy)
            transport = connection
            let client = HerdrClient(transport: connection)

            stage = "first_use_ping_and_capabilities"
            let warmupStart = DispatchTime.now().uptimeNanoseconds
            let server = try await client.serverVersionAndCapabilities()
            let warmupSeconds = seconds(since: warmupStart)
            guard policy.pinnedFingerprint(for: host, port: port) != nil else {
                throw EvidenceFailure("Production handshake did not pin the loopback host key")
            }
            var warmup: [String: Any] = [
                "duration_seconds": warmupSeconds,
                "includes_first_ssh_connection": true,
                "populates_production_capability_cache": true,
                "host_key_pinned_in_isolated_memory_store": true,
                "server_version": server.version,
            ]
            if let capabilities = server.capabilities {
                warmup["capabilities"] = [
                    "gram_upload_stream": capabilities.gramUploadStream,
                    "api_bridge_multi": capabilities.apiBridgeMulti,
                    "pane_input_stream": capabilities.paneInputStream,
                ]
            } else {
                warmup["capabilities"] = NSNull()
            }
            receipt["warmup"] = warmup

            stage = "prepare_payload"
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("gram-real-citadel-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            payloadDirectory = directory
            let name = "gram-real-citadel-10MiB.bin"
            let mime = "application/octet-stream"
            let fileURL = directory.appendingPathComponent(name)
            let payload = makePayload(byteCount: 10 * 1024 * 1024)
            let expectedHash = checksum(payload)
            try payload.write(to: fileURL, options: .atomic)
            var scenario: [String: Any] = [
                "size_mib": 10, "bytes": payload.count, "sha256": expectedHash,
                "name": name, "mime": mime,
                "payload_generator": "SplitMix64 seed 0x4752414d43495441, little-endian words",
            ]
            receipt["scenarios"] = [scenario]

            stage = "gramUploadFile"
            let uploadStart = DispatchTime.now().uptimeNanoseconds
            let uploadID = try await client.gramUploadFile(fileURL: fileURL)
            scenario["upload"] = measurement(bytes: payload.count, since: uploadStart)
            receipt["scenarios"] = [scenario]

            stage = "gramPost_finalize"
            let attachment = HerdrClient.GramFileAttachment(uploadID: uploadID, name: name, mime: mime)
            let finalizeStart = DispatchTime.now().uptimeNanoseconds
            let message = try await client.gramPost(text: "Disposable real Citadel Linux evidence", attachment: attachment)
            // Finalization sends metadata, not the file again: zero payload bytes.
            scenario["finalize"] = measurement(bytes: 0, since: finalizeStart)
            receipt["scenarios"] = [scenario]
            stage = "verify_posted_metadata"
            guard let file = message.file, file.name == name, file.mime == mime,
                  file.size == UInt64(payload.count), file.sha256.lowercased() == expectedHash else {
                throw EvidenceFailure("Posted attachment metadata or SHA256 differs from the payload")
            }
            scenario["posted_metadata_verified"] = true

            stage = "gramGetFile"
            let downloadStart = DispatchTime.now().uptimeNanoseconds
            let downloaded = try await client.gramGetFile(id: message.id)
            scenario["download"] = measurement(bytes: downloaded.data.count, since: downloadStart)
            receipt["scenarios"] = [scenario]
            stage = "verify_gramGetFile"
            let downloadHash = checksum(downloaded.data)
            guard downloaded.name == name, downloaded.mime == mime,
                  downloaded.data == payload, downloadHash == expectedHash else {
                throw EvidenceFailure("gramGetFile bytes, metadata or SHA256 differs from the payload")
            }
            scenario["download_sha256"] = downloadHash
            scenario["download_verified"] = true

            stage = "gramGetFileChunked"
            let chunkedStart = DispatchTime.now().uptimeNanoseconds
            let chunked = try await client.gramGetFileChunked(id: message.id, expectedSize: UInt64(payload.count))
            scenario["chunked"] = measurement(bytes: chunked.data.count, since: chunkedStart)
            receipt["scenarios"] = [scenario]
            stage = "verify_gramGetFileChunked"
            let chunkedHash = checksum(chunked.data)
            guard chunked.name == name, chunked.mime == mime,
                  chunked.data == payload, chunkedHash == expectedHash else {
                throw EvidenceFailure("gramGetFileChunked bytes, metadata or SHA256 differs from the payload")
            }
            scenario["chunked_sha256"] = chunkedHash
            scenario["chunked_verified"] = true
            receipt["scenarios"] = [scenario]

            stage = "close_transport"
            await connection.close()
            transport = nil
            stage = "remove_local_payload"
            try FileManager.default.removeItem(at: directory)
            payloadDirectory = nil
            receipt["cleanup"] = "Transport closed and local payload removed; disposable remote sandbox is runner-owned"
            stage = "write_receipt"
            receipt["status"] = "passed"
            try emit(receipt, to: receiptURL)
        } catch {
            if let transport { await transport.close() }
            receipt["status"] = "failed"
            receipt["failed_stage"] = stage
            // Never stringify arbitrary transport/decoder errors: they can contain
            // the request, response or credentials. Only our static diagnostics print.
            let reason = (error as? EvidenceFailure)?.description ?? "Operation failed; underlying error contents suppressed"
            receipt["failure_reason"] = reason
            receipt["error_type"] = String(reflecting: type(of: error))
            do {
                try emit(receipt, to: receiptURL)
            } catch {
                print("GRAM_REAL_CITADEL_EVIDENCE receipt write failed; details suppressed")
            }
            XCTFail("Real Citadel Linux evidence failed at \(stage): \(reason)")
        }
    }

    private struct EvidenceFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    private func required(_ key: String, in environment: [String: String]) throws -> String {
        guard let value = environment[key], !value.isEmpty else {
            throw EvidenceFailure("Missing required environment variable \(key)")
        }
        return value
    }

    private func revision(_ key: String, in environment: [String: String]) throws -> String {
        let value = try required(key, in: environment)
        guard value.utf8.count == 40, value.utf8.allSatisfy({
            (48...57).contains($0) || (97...102).contains($0)
        }) else { throw EvidenceFailure("\(key) must be a full lowercase hexadecimal Git SHA") }
        return value
    }

    private func seconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
    }

    private func measurement(bytes: Int, since start: UInt64) -> [String: Any] {
        let duration = seconds(since: start)
        return ["bytes": bytes, "duration_seconds": duration,
                "throughput_mib_per_second": Double(bytes) / 1_048_576 / duration,
                "throughput_mb_per_second": Double(bytes) / 1_000_000 / duration]
    }

    private func checksum(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func makePayload(byteCount: Int) -> Data {
        var data = Data(count: byteCount)
        data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            var state: UInt64 = 0x4752414d43495441
            for offset in stride(from: 0, to: byteCount, by: 8) {
                state &+= 0x9e3779b97f4a7c15
                var word = state
                word = (word ^ (word >> 30)) &* 0xbf58476d1ce4e5b9
                word = (word ^ (word >> 27)) &* 0x94d049bb133111eb
                word ^= word >> 31
                for byte in 0..<min(8, byteCount - offset) {
                    buffer[offset + byte] = UInt8(truncatingIfNeeded: word >> (byte * 8))
                }
            }
        }
        return data
    }

    private func emit(_ receipt: [String: Any], to destination: URL?) throws {
        let data = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
        // This JSON is the visible summary as well as the durable sanitized artifact.
        print("GRAM_REAL_CITADEL_EVIDENCE \(String(decoding: data, as: UTF8.self))")
        if let destination { try data.write(to: destination, options: .atomic) }
    }
}
