import Foundation

public final class SyncEngine: ObservableObject, @unchecked Sendable {
    public static let shared = SyncEngine()

    @Published public var syncStatus: SyncStatus = .idle

    private let store: LocalDatabaseStore
    private var backendBaseURL: URL
    private let session = URLSession(configuration: .default)
    private var syncTimer: Timer?
    private let queue = DispatchQueue(label: "com.sidebrief.sync.engine", qos: .utility)
    private var isSyncing = false

    public init(
        store: LocalDatabaseStore = .shared,
        backendBaseURL: URL = URL(string: "http://localhost:3100")!
    ) {
        self.store = store
        self.backendBaseURL = backendBaseURL
    }

    public func setBackendURL(_ url: URL) {
        queue.sync {
            self.backendBaseURL = url
        }
    }

    public func startPeriodicSync(interval: TimeInterval = 15.0) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.syncTimer?.invalidate()
            self.syncTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                Task {
                    await self?.syncAll()
                }
            }
        }
    }

    public func stopPeriodicSync() {
        DispatchQueue.main.async {
            self.syncTimer?.invalidate()
            self.syncTimer = nil
        }
    }

    public func syncAll(spaceId: String = "space-work") async {
        await syncPendingOutbox()
        await syncPendingAudioChunks(spaceId: spaceId)
    }

    public func syncPendingOutbox() async {
        let shouldSync: Bool = queue.sync {
            if isSyncing { return false }
            isSyncing = true
            return true
        }
        guard shouldSync else { return }
        defer {
            queue.sync { self.isSyncing = false }
        }

        let pending = store.getPendingOutboxEntries(limit: 50)
        guard !pending.isEmpty else {
            await updateSyncStatus(.synced)
            return
        }

        await updateSyncStatus(.syncing(chunksRemaining: pending.count))

        // Group by space
        let grouped = Dictionary(grouping: pending, by: { $0.spaceId })

        for (spaceId, entries) in grouped {
            var meetings: [Meeting] = []
            var clearedIds: [String] = []

            for entry in entries {
                if entry.entityType == "meeting", let data = entry.payloadJson.data(using: .utf8) {
                    if let m = try? JSONDecoder().decode(Meeting.self, from: data) {
                        meetings.append(m)
                        clearedIds.append(entry.id)
                    }
                }
            }

            guard !meetings.isEmpty else { continue }

            let payload: [String: Any] = [
                "spaceId": spaceId,
                "meetings": meetings.map { [
                    "id": $0.id,
                    "title": $0.title,
                    "state": $0.state.rawValue,
                    "agenda": $0.agenda,
                    "sensitivity": $0.sensitivity,
                    "version": $0.version,
                    "totalPromptTokens": $0.totalPromptTokens,
                    "totalCompletionTokens": $0.totalCompletionTokens,
                    "estimatedCostUSD": $0.estimatedCostUSD,
                    "actualStartTime": ($0.actualStartTime?.ISO8601Format() ?? "") as Any,
                    "actualEndTime": ($0.actualEndTime?.ISO8601Format() ?? "") as Any
                ]}
            ]

            let targetURL: URL = queue.sync {
                self.backendBaseURL.appendingPathComponent("api/v1/sync")
            }

            var request = URLRequest(url: targetURL)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            do {
                request.httpBody = try JSONSerialization.data(withJSONObject: payload)
                let (_, response) = try await session.data(for: request)
                if let httpRes = response as? HTTPURLResponse, (200...299).contains(httpRes.statusCode) {
                    store.markOutboxSuccess(ids: clearedIds)
                    await updateSyncStatus(.synced)
                } else {
                    await updateSyncStatus(.offline(pendingCount: pending.count))
                }
            } catch {
                // Network failure: keep items in outbox to retry next time
                await updateSyncStatus(.offline(pendingCount: pending.count))
            }
        }
    }

    /// Uploads encrypted audio chunks to Cloudflare R2 bucket via backend storage grant
    public func syncPendingAudioChunks(spaceId: String = "space-work") async {
        let pendingChunks = store.getPendingUploadChunks(limit: 10)
        guard !pendingChunks.isEmpty else {
            return
        }

        await updateSyncStatus(.syncing(chunksRemaining: pendingChunks.count))

        for chunk in pendingChunks {
            let fileURL = URL(fileURLWithPath: chunk.localEncryptedFilePath)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                continue
            }

            store.updateChunkUploadState(id: chunk.id, state: .uploading)

            let grantURL: URL = queue.sync {
                self.backendBaseURL.appendingPathComponent("api/v1/storage/grant-upload")
            }

            var grantReq = URLRequest(url: grantURL)
            grantReq.httpMethod = "POST"
            grantReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let grantPayload: [String: Any] = [
                "meetingId": chunk.meetingId,
                "chunkId": chunk.id,
                "spaceId": spaceId
            ]

            do {
                grantReq.httpBody = try JSONSerialization.data(withJSONObject: grantPayload)
                let (grantData, grantRes) = try await session.data(for: grantReq)

                guard let httpGrant = grantRes as? HTTPURLResponse, (200...299).contains(httpGrant.statusCode),
                      let grantJson = try? JSONSerialization.jsonObject(with: grantData) as? [String: Any],
                      let uploadUrlString = grantJson["uploadUrl"] as? String,
                      let uploadUrl = URL(string: uploadUrlString),
                      let objectKey = grantJson["objectKey"] as? String else {
                    // Backend unavailable or grant failed: mark failed/queued
                    store.updateChunkUploadState(id: chunk.id, state: .failed)
                    await updateSyncStatus(.offline(pendingCount: pendingChunks.count))
                    continue
                }

                // Upload encrypted .enc payload
                let fileData = try Data(contentsOf: fileURL)
                var uploadReq = URLRequest(url: uploadUrl)
                uploadReq.httpMethod = "PUT"
                uploadReq.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                uploadReq.setValue(chunk.checksumSha256, forHTTPHeaderField: "x-amz-checksum-sha256")
                uploadReq.httpBody = fileData

                let (_, uploadRes) = try await session.data(for: uploadReq)
                if let httpUpload = uploadRes as? HTTPURLResponse, (200...299).contains(httpUpload.statusCode) {
                    store.updateChunkUploadState(id: chunk.id, state: .uploaded, remoteObjectKey: objectKey)
                } else {
                    store.updateChunkUploadState(id: chunk.id, state: .failed)
                }
            } catch {
                store.updateChunkUploadState(id: chunk.id, state: .failed)
                await updateSyncStatus(.offline(pendingCount: pendingChunks.count))
            }
        }

        let remaining = store.getPendingUploadChunks(limit: 10)
        if remaining.isEmpty {
            await updateSyncStatus(.synced)
        } else {
            await updateSyncStatus(.syncing(chunksRemaining: remaining.count))
        }
    }

    private func updateSyncStatus(_ newStatus: SyncStatus) async {
        await MainActor.run {
            self.syncStatus = newStatus
        }
    }
}
