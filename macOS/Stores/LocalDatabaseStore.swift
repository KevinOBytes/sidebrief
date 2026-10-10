import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class LocalDatabaseStore: @unchecked Sendable {
    public static let shared = LocalDatabaseStore()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.sidebrief.local.db", qos: .userInitiated)

    public init(databaseURL: URL? = nil) {
        let fileURL: URL
        if let customURL = databaseURL {
            fileURL = customURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dir = appSupport.appendingPathComponent("Sidebrief", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            fileURL = dir.appendingPathComponent("sidebrief_local.sqlite")
        }

        if sqlite3_open(fileURL.path, &db) == SQLITE_OK {
            createTables()
        }
    }

    deinit {
        if let db = db {
            sqlite3_close(db)
        }
    }

    private func createTables() {
        let sql = """
        CREATE TABLE IF NOT EXISTS local_meetings (
            id TEXT PRIMARY KEY,
            space_id TEXT NOT NULL,
            title TEXT NOT NULL,
            state TEXT NOT NULL,
            agenda TEXT,
            sensitivity TEXT,
            version INTEGER,
            actual_start_time REAL,
            actual_end_time REAL,
            created_at REAL,
            updated_at REAL
        );

        CREATE TABLE IF NOT EXISTS local_transcript_segments (
            id TEXT PRIMARY KEY,
            meeting_id TEXT NOT NULL,
            track_id TEXT NOT NULL,
            speaker_label TEXT NOT NULL,
            text TEXT NOT NULL,
            start_offset_ms INTEGER,
            end_offset_ms INTEGER,
            is_provisional INTEGER,
            revision INTEGER,
            created_at REAL
        );

        CREATE TABLE IF NOT EXISTS local_summaries (
            id TEXT PRIMARY KEY,
            meeting_id TEXT NOT NULL,
            version INTEGER,
            overview TEXT,
            key_points TEXT,
            decisions TEXT,
            action_items TEXT,
            unresolved_questions TEXT,
            email_draft TEXT,
            created_at REAL
        );

        CREATE TABLE IF NOT EXISTS sync_outbox (
            id TEXT PRIMARY KEY,
            entity_type TEXT NOT NULL,
            entity_id TEXT NOT NULL,
            space_id TEXT NOT NULL,
            payload_json TEXT NOT NULL,
            status TEXT NOT NULL,
            retry_count INTEGER DEFAULT 0,
            created_at REAL
        );

        CREATE TABLE IF NOT EXISTS local_memory_facts (
            id TEXT PRIMARY KEY,
            space_id TEXT NOT NULL,
            category TEXT NOT NULL,
            key TEXT NOT NULL,
            value TEXT NOT NULL,
            source TEXT NOT NULL,
            is_pinned INTEGER DEFAULT 0,
            created_at REAL,
            updated_at REAL
        );

        CREATE TABLE IF NOT EXISTS local_email_accounts (
            id TEXT PRIMARY KEY,
            space_id TEXT NOT NULL,
            account_name TEXT NOT NULL,
            email_address TEXT NOT NULL,
            imap_host TEXT NOT NULL,
            imap_port INTEGER DEFAULT 993,
            use_tls INTEGER DEFAULT 1,
            auth_type TEXT NOT NULL,
            sync_folder TEXT DEFAULT 'INBOX',
            is_enabled INTEGER DEFAULT 1,
            created_at REAL
        );

        CREATE TABLE IF NOT EXISTS local_context_spaces (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            description TEXT,
            retention_days INTEGER DEFAULT 365,
            allowed_providers TEXT,
            custom_prompt TEXT,
            created_at REAL,
            updated_at REAL
        );

        CREATE TABLE IF NOT EXISTS local_custom_vocabulary (
            id TEXT PRIMARY KEY,
            space_id TEXT,
            phrase TEXT NOT NULL,
            sounds_like TEXT,
            boost REAL DEFAULT 2.0,
            created_at REAL
        );

        CREATE TABLE IF NOT EXISTS local_audio_chunks (
            id TEXT PRIMARY KEY,
            track_id TEXT NOT NULL,
            meeting_id TEXT NOT NULL,
            sequence_number INTEGER,
            stream_epoch INTEGER,
            start_offset_ms INTEGER,
            end_offset_ms INTEGER,
            sample_count INTEGER,
            byte_count INTEGER,
            checksum_sha256 TEXT,
            encryption_key_version INTEGER,
            encryption_nonce_hex TEXT,
            local_encrypted_file_path TEXT,
            remote_object_key TEXT,
            upload_state TEXT,
            created_at REAL
        );

        CREATE TABLE IF NOT EXISTS local_speaker_profiles (
            id TEXT PRIMARY KEY,
            space_id TEXT,
            name TEXT NOT NULL,
            role_or_title TEXT,
            organization TEXT,
            notes_or_context TEXT,
            aliases TEXT,
            voiceprint_json TEXT,
            voice_sample_blob BLOB,
            gender_estimate TEXT,
            created_at REAL,
            updated_at REAL
        );
        """
        queue.sync {
            sqlite3_exec(db, sql, nil, nil, nil)
            sqlite3_exec(db, "ALTER TABLE local_meetings ADD COLUMN actual_start_time REAL;", nil, nil, nil)
            sqlite3_exec(db, "ALTER TABLE local_meetings ADD COLUMN actual_end_time REAL;", nil, nil, nil)
            sqlite3_exec(db, "ALTER TABLE local_context_spaces ADD COLUMN custom_prompt TEXT;", nil, nil, nil)
            sqlite3_exec(db, "ALTER TABLE local_meetings ADD COLUMN total_prompt_tokens INTEGER DEFAULT 0;", nil, nil, nil)
            sqlite3_exec(db, "ALTER TABLE local_meetings ADD COLUMN total_completion_tokens INTEGER DEFAULT 0;", nil, nil, nil)
            sqlite3_exec(db, "ALTER TABLE local_meetings ADD COLUMN estimated_cost_usd REAL DEFAULT 0.0;", nil, nil, nil)
            sqlite3_exec(db, "ALTER TABLE local_speaker_profiles ADD COLUMN voiceprint_json TEXT;", nil, nil, nil)
            sqlite3_exec(db, "ALTER TABLE local_speaker_profiles ADD COLUMN voice_sample_blob BLOB;", nil, nil, nil)
            sqlite3_exec(db, "ALTER TABLE local_speaker_profiles ADD COLUMN gender_estimate TEXT;", nil, nil, nil)
            sqlite3_exec(db, "DELETE FROM local_speaker_profiles WHERE rowid NOT IN (SELECT min(rowid) FROM local_speaker_profiles GROUP BY name);", nil, nil, nil)
        }
        seedDefaultVocabularyIfNeeded()
    }

    // MARK: - Meeting Operations

    public func saveMeeting(_ meeting: Meeting) {
        let sql = """
        INSERT INTO local_meetings (id, space_id, title, state, agenda, sensitivity, version, actual_start_time, actual_end_time, total_prompt_tokens, total_completion_tokens, estimated_cost_usd, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            title = excluded.title,
            state = excluded.state,
            agenda = excluded.agenda,
            sensitivity = excluded.sensitivity,
            version = excluded.version,
            actual_start_time = excluded.actual_start_time,
            actual_end_time = excluded.actual_end_time,
            total_prompt_tokens = excluded.total_prompt_tokens,
            total_completion_tokens = excluded.total_completion_tokens,
            estimated_cost_usd = excluded.estimated_cost_usd,
            updated_at = excluded.updated_at;
        """

        queue.sync {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (meeting.id as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (meeting.spaceId as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 3, (meeting.title as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 4, (meeting.state.rawValue as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 5, (meeting.agenda as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 6, (meeting.sensitivity as NSString).utf8String, -1, nil)
                sqlite3_bind_int(stmt, 7, Int32(meeting.version))
                if let start = meeting.actualStartTime {
                    sqlite3_bind_double(stmt, 8, start.timeIntervalSince1970)
                } else {
                    sqlite3_bind_null(stmt, 8)
                }
                if let end = meeting.actualEndTime {
                    sqlite3_bind_double(stmt, 9, end.timeIntervalSince1970)
                } else {
                    sqlite3_bind_null(stmt, 9)
                }
                sqlite3_bind_int(stmt, 10, Int32(meeting.totalPromptTokens))
                sqlite3_bind_int(stmt, 11, Int32(meeting.totalCompletionTokens))
                sqlite3_bind_double(stmt, 12, meeting.estimatedCostUSD)
                sqlite3_bind_double(stmt, 13, meeting.createdAt.timeIntervalSince1970)
                sqlite3_bind_double(stmt, 14, meeting.updatedAt.timeIntervalSince1970)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }

        // Enqueue to outbox
        enqueueOutbox(entityType: "meeting", entityId: meeting.id, spaceId: meeting.spaceId, object: meeting)
    }

    public func getMeeting(id: String) -> Meeting? {
        let sql = "SELECT id, space_id, title, state, agenda, sensitivity, version, actual_start_time, actual_end_time, total_prompt_tokens, total_completion_tokens, estimated_cost_usd, created_at, updated_at FROM local_meetings WHERE id = ?;"
        return queue.sync {
            var stmt: OpaquePointer?
            var meeting: Meeting?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
                if sqlite3_step(stmt) == SQLITE_ROW {
                    let mId = String(cString: sqlite3_column_text(stmt, 0))
                    let spaceId = String(cString: sqlite3_column_text(stmt, 1))
                    let title = String(cString: sqlite3_column_text(stmt, 2))
                    let stateStr = String(cString: sqlite3_column_text(stmt, 3))
                    let agenda = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
                    let sens = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? "internal"
                    let ver = Int(sqlite3_column_int(stmt, 6))
                    let actualStart = sqlite3_column_type(stmt, 7) != SQLITE_NULL ? Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7)) : nil
                    let actualEnd = sqlite3_column_type(stmt, 8) != SQLITE_NULL ? Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8)) : nil
                    let promptTokens = Int(sqlite3_column_int(stmt, 9))
                    let compTokens = Int(sqlite3_column_int(stmt, 10))
                    let costUsd = sqlite3_column_double(stmt, 11)
                    let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 12))
                    let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 13))

                    meeting = Meeting(
                        id: mId,
                        spaceId: spaceId,
                        title: title,
                        scheduledStartTime: actualStart,
                        actualStartTime: actualStart,
                        actualEndTime: actualEnd,
                        state: MeetingState(rawValue: stateStr) ?? .scheduled,
                        agenda: agenda,
                        sensitivity: sens,
                        version: ver,
                        totalPromptTokens: promptTokens,
                        totalCompletionTokens: compTokens,
                        estimatedCostUSD: costUsd,
                        createdAt: createdAt,
                        updatedAt: updatedAt
                    )
                }
            }
            sqlite3_finalize(stmt)
            return meeting
        }
    }

    public func getMeetings(spaceId: String? = nil, query: String? = nil) -> [Meeting] {
        var conditions: [String] = []
        if let sp = spaceId, !sp.isEmpty {
            conditions.append("m.space_id = ?")
        }
        let trimmedQuery = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedQuery.isEmpty {
            conditions.append("""
            (
                m.title LIKE ? OR 
                m.agenda LIKE ? OR 
                EXISTS (SELECT 1 FROM local_transcript_segments s WHERE s.meeting_id = m.id AND s.text LIKE ?) OR 
                EXISTS (SELECT 1 FROM local_summaries sum WHERE sum.meeting_id = m.id AND (sum.overview LIKE ? OR sum.key_points LIKE ? OR sum.decisions LIKE ? OR sum.action_items LIKE ?))
            )
            """)
        }

        var sql = "SELECT m.id, m.space_id, m.title, m.state, m.agenda, m.sensitivity, m.version, m.actual_start_time, m.actual_end_time, m.total_prompt_tokens, m.total_completion_tokens, m.estimated_cost_usd, m.created_at, m.updated_at FROM local_meetings m"
        if !conditions.isEmpty {
            sql += " WHERE " + conditions.joined(separator: " AND ")
        }
        sql += " ORDER BY m.created_at DESC;"

        return queue.sync {
            var stmt: OpaquePointer?
            var meetings: [Meeting] = []
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                var bindIndex: Int32 = 1
                if let sp = spaceId, !sp.isEmpty {
                    sqlite3_bind_text(stmt, bindIndex, (sp as NSString).utf8String, -1, nil)
                    bindIndex += 1
                }
                if !trimmedQuery.isEmpty {
                    let wildcard = "%\(trimmedQuery)%"
                    for _ in 0..<7 {
                        sqlite3_bind_text(stmt, bindIndex, (wildcard as NSString).utf8String, -1, nil)
                        bindIndex += 1
                    }
                }

                while sqlite3_step(stmt) == SQLITE_ROW {
                    let mId = String(cString: sqlite3_column_text(stmt, 0))
                    let spaceId = String(cString: sqlite3_column_text(stmt, 1))
                    let title = String(cString: sqlite3_column_text(stmt, 2))
                    let stateStr = String(cString: sqlite3_column_text(stmt, 3))
                    let agenda = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? ""
                    let sens = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? "internal"
                    let ver = Int(sqlite3_column_int(stmt, 6))
                    let actualStart = sqlite3_column_type(stmt, 7) != SQLITE_NULL ? Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7)) : nil
                    let actualEnd = sqlite3_column_type(stmt, 8) != SQLITE_NULL ? Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8)) : nil
                    let promptTokens = Int(sqlite3_column_int(stmt, 9))
                    let compTokens = Int(sqlite3_column_int(stmt, 10))
                    let costUsd = sqlite3_column_double(stmt, 11)
                    let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 12))
                    let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 13))

                    meetings.append(Meeting(
                        id: mId,
                        spaceId: spaceId,
                        title: title,
                        scheduledStartTime: actualStart,
                        actualStartTime: actualStart,
                        actualEndTime: actualEnd,
                        state: MeetingState(rawValue: stateStr) ?? .scheduled,
                        agenda: agenda,
                        sensitivity: sens,
                        version: ver,
                        totalPromptTokens: promptTokens,
                        totalCompletionTokens: compTokens,
                        estimatedCostUSD: costUsd,
                        createdAt: createdAt,
                        updatedAt: updatedAt
                    ))
                }
            }
            sqlite3_finalize(stmt)
            return meetings
        }
    }

    public func deleteMeeting(id: String, spaceId: String) {
        queue.sync {
            let deleteMeetingSql = "DELETE FROM local_meetings WHERE id = ?;"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, deleteMeetingSql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)

            let deleteSegSql = "DELETE FROM local_transcript_segments WHERE meeting_id = ?;"
            var stmtSeg: OpaquePointer?
            if sqlite3_prepare_v2(db, deleteSegSql, -1, &stmtSeg, nil) == SQLITE_OK {
                sqlite3_bind_text(stmtSeg, 1, (id as NSString).utf8String, -1, nil)
                sqlite3_step(stmtSeg)
            }
            sqlite3_finalize(stmtSeg)

            let deleteSumSql = "DELETE FROM local_summaries WHERE meeting_id = ?;"
            var stmtSum: OpaquePointer?
            if sqlite3_prepare_v2(db, deleteSumSql, -1, &stmtSum, nil) == SQLITE_OK {
                sqlite3_bind_text(stmtSum, 1, (id as NSString).utf8String, -1, nil)
                sqlite3_step(stmtSum)
            }
            sqlite3_finalize(stmtSum)

            let deleteChunksSql = "DELETE FROM local_audio_chunks WHERE meeting_id = ?;"
            var stmtChunks: OpaquePointer?
            if sqlite3_prepare_v2(db, deleteChunksSql, -1, &stmtChunks, nil) == SQLITE_OK {
                sqlite3_bind_text(stmtChunks, 1, (id as NSString).utf8String, -1, nil)
                sqlite3_step(stmtChunks)
            }
            sqlite3_finalize(stmtChunks)
        }
        enqueueOutbox(entityType: "tombstone_meeting", entityId: id, spaceId: spaceId, object: ["id": id])
    }

    // MARK: - Transcript Segments Operations

    public func saveTranscriptSegments(_ segments: [TranscriptSegment]) {
        guard !segments.isEmpty else { return }
        let sql = """
        INSERT INTO local_transcript_segments (id, meeting_id, track_id, speaker_label, text, start_offset_ms, end_offset_ms, is_provisional, revision, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            speaker_label = excluded.speaker_label,
            text = excluded.text,
            start_offset_ms = excluded.start_offset_ms,
            end_offset_ms = excluded.end_offset_ms,
            is_provisional = excluded.is_provisional,
            revision = excluded.revision;
        """

        queue.sync {
            sqlite3_exec(db, "BEGIN TRANSACTION;", nil, nil, nil)
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                for seg in segments {
                    sqlite3_bind_text(stmt, 1, (seg.id as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(stmt, 2, (seg.meetingId as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(stmt, 3, (seg.trackId as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(stmt, 4, (seg.speakerLabel as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(stmt, 5, (seg.text as NSString).utf8String, -1, nil)
                    sqlite3_bind_int64(stmt, 6, seg.startOffsetMs)
                    sqlite3_bind_int64(stmt, 7, seg.endOffsetMs)
                    sqlite3_bind_int(stmt, 8, seg.isProvisional ? 1 : 0)
                    sqlite3_bind_int(stmt, 9, Int32(seg.revision))
                    sqlite3_bind_double(stmt, 10, seg.createdAt.timeIntervalSince1970)
                    sqlite3_step(stmt)
                    sqlite3_reset(stmt)
                }
            }
            sqlite3_finalize(stmt)
            sqlite3_exec(db, "COMMIT;", nil, nil, nil)
        }
    }

    public func getTranscriptSegments(meetingId: String) -> [TranscriptSegment] {
        let sql = "SELECT id, meeting_id, track_id, speaker_label, text, start_offset_ms, end_offset_ms, is_provisional, revision, created_at FROM local_transcript_segments WHERE meeting_id = ? ORDER BY start_offset_ms ASC, created_at ASC;"
        return queue.sync {
            var segments: [TranscriptSegment] = []
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (meetingId as NSString).utf8String, -1, nil)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let id = String(cString: sqlite3_column_text(stmt, 0))
                    let mId = String(cString: sqlite3_column_text(stmt, 1))
                    let trackId = String(cString: sqlite3_column_text(stmt, 2))
                    let speaker = String(cString: sqlite3_column_text(stmt, 3))
                    let text = String(cString: sqlite3_column_text(stmt, 4))
                    let startMs = sqlite3_column_int64(stmt, 5)
                    let endMs = sqlite3_column_int64(stmt, 6)
                    let prov = sqlite3_column_int(stmt, 7) != 0
                    let rev = Int(sqlite3_column_int(stmt, 8))
                    let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 9))

                    segments.append(TranscriptSegment(
                        id: id,
                        meetingId: mId,
                        trackId: trackId,
                        providerSegmentId: id,
                        speakerLabel: speaker,
                        text: text,
                        startOffsetMs: startMs,
                        endOffsetMs: endMs,
                        isProvisional: prov,
                        revision: rev,
                        createdAt: createdAt,
                        updatedAt: createdAt
                    ))
                }
            }
            sqlite3_finalize(stmt)
            return segments
        }
    }

    public func renameSpeakerInTranscript(meetingId: String, oldLabel: String, newLabel: String) {
        let sql = """
        UPDATE local_transcript_segments
        SET speaker_label = ?, revision = revision + 1
        WHERE meeting_id = ? AND speaker_label = ?;
        """
        queue.sync {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (newLabel as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (meetingId as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 3, (oldLabel as NSString).utf8String, -1, nil)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    public func getUniqueSpeakersInMeeting(meetingId: String) -> [String] {
        let sql = """
        SELECT DISTINCT speaker_label
        FROM local_transcript_segments
        WHERE meeting_id = ? AND speaker_label IS NOT NULL AND speaker_label != ''
        ORDER BY speaker_label ASC;
        """
        return queue.sync {
            var labels: [String] = []
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (meetingId as NSString).utf8String, -1, nil)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let cStr = sqlite3_column_text(stmt, 0) {
                        labels.append(String(cString: cStr))
                    }
                }
            }
            sqlite3_finalize(stmt)
            return labels
        }
    }

    // MARK: - Summaries Operations

    public func saveSummary(_ summary: MeetingSummary) {
        let keyPointsJson = (try? JSONEncoder().encode(summary.keyPoints)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let decisionsJson = (try? JSONEncoder().encode(summary.decisions)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let actionsJson = (try? JSONEncoder().encode(summary.actionItems)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let questionsJson = (try? JSONEncoder().encode(summary.unresolvedQuestions)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        let sql = """
        INSERT INTO local_summaries (id, meeting_id, version, overview, key_points, decisions, action_items, unresolved_questions, email_draft, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            version = excluded.version,
            overview = excluded.overview,
            key_points = excluded.key_points,
            decisions = excluded.decisions,
            action_items = excluded.action_items,
            unresolved_questions = excluded.unresolved_questions,
            email_draft = excluded.email_draft;
        """

        queue.sync {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (summary.id as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (summary.meetingId as NSString).utf8String, -1, nil)
                sqlite3_bind_int(stmt, 3, Int32(summary.version))
                sqlite3_bind_text(stmt, 4, (summary.overview as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 5, (keyPointsJson as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 6, (decisionsJson as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 7, (actionsJson as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 8, (questionsJson as NSString).utf8String, -1, nil)
                if let draft = summary.followUpEmailDraft {
                    sqlite3_bind_text(stmt, 9, (draft as NSString).utf8String, -1, nil)
                } else {
                    sqlite3_bind_null(stmt, 9)
                }
                sqlite3_bind_double(stmt, 10, summary.createdAt.timeIntervalSince1970)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    public func getSummary(meetingId: String) -> MeetingSummary? {
        let sql = "SELECT id, meeting_id, version, overview, key_points, decisions, action_items, unresolved_questions, email_draft, created_at FROM local_summaries WHERE meeting_id = ? ORDER BY version DESC, created_at DESC LIMIT 1;"
        return queue.sync {
            var stmt: OpaquePointer?
            var summary: MeetingSummary?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (meetingId as NSString).utf8String, -1, nil)
                if sqlite3_step(stmt) == SQLITE_ROW {
                    let id = String(cString: sqlite3_column_text(stmt, 0))
                    let mId = String(cString: sqlite3_column_text(stmt, 1))
                    let ver = Int(sqlite3_column_int(stmt, 2))
                    let overview = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
                    let keyPointsStr = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? "[]"
                    let decisionsStr = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? "[]"
                    let actionsStr = sqlite3_column_text(stmt, 6).map { String(cString: $0) } ?? "[]"
                    let questionsStr = sqlite3_column_text(stmt, 7).map { String(cString: $0) } ?? "[]"
                    let emailDraft = sqlite3_column_text(stmt, 8).map { String(cString: $0) }
                    let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 9))

                    let keyPoints = (try? JSONDecoder().decode([String].self, from: Data(keyPointsStr.utf8))) ?? []
                    let decisions = (try? JSONDecoder().decode([DecisionItem].self, from: Data(decisionsStr.utf8))) ?? []
                    let actions = (try? JSONDecoder().decode([ActionItem].self, from: Data(actionsStr.utf8))) ?? []
                    let questions = (try? JSONDecoder().decode([String].self, from: Data(questionsStr.utf8))) ?? []

                    summary = MeetingSummary(
                        id: id,
                        meetingId: mId,
                        version: ver,
                        generatingRevision: 1,
                        overview: overview,
                        keyPoints: keyPoints,
                        decisions: decisions,
                        actionItems: actions,
                        unresolvedQuestions: questions,
                        followUpEmailDraft: emailDraft,
                        createdAt: createdAt
                    )
                }
            }
            sqlite3_finalize(stmt)
            return summary
        }
    }

    // MARK: - Outbox Operations

    private func enqueueOutbox<T: Encodable>(entityType: String, entityId: String, spaceId: String, object: T) {
        guard let data = try? JSONEncoder().encode(object),
              let jsonStr = String(data: data, encoding: .utf8) else { return }

        let outboxId = UUID().uuidString
        let sql = """
        INSERT INTO sync_outbox (id, entity_type, entity_id, space_id, payload_json, status, retry_count, created_at)
        VALUES (?, ?, ?, ?, ?, 'pending', 0, ?);
        """

        queue.sync {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (outboxId as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (entityType as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 3, (entityId as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 4, (spaceId as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 5, (jsonStr as NSString).utf8String, -1, nil)
                sqlite3_bind_double(stmt, 6, Date().timeIntervalSince1970)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    public struct OutboxEntry: Sendable {
        public let id: String
        public let entityType: String
        public let entityId: String
        public let spaceId: String
        public let payloadJson: String
        public let status: String
        public let retryCount: Int
    }

    public func getPendingOutboxEntries(limit: Int = 50) -> [OutboxEntry] {
        let sql = "SELECT id, entity_type, entity_id, space_id, payload_json, status, retry_count FROM sync_outbox WHERE status = 'pending' ORDER BY created_at ASC LIMIT ?;"
        return queue.sync {
            var stmt: OpaquePointer?
            var entries: [OutboxEntry] = []
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int(stmt, 1, Int32(limit))
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let id = String(cString: sqlite3_column_text(stmt, 0))
                    let entityType = String(cString: sqlite3_column_text(stmt, 1))
                    let entityId = String(cString: sqlite3_column_text(stmt, 2))
                    let spaceId = String(cString: sqlite3_column_text(stmt, 3))
                    let payload = String(cString: sqlite3_column_text(stmt, 4))
                    let status = String(cString: sqlite3_column_text(stmt, 5))
                    let retry = Int(sqlite3_column_int(stmt, 6))

                    entries.append(OutboxEntry(
                        id: id,
                        entityType: entityType,
                        entityId: entityId,
                        spaceId: spaceId,
                        payloadJson: payload,
                        status: status,
                        retryCount: retry
                    ))
                }
            }
            sqlite3_finalize(stmt)
            return entries
        }
    }

    public func markOutboxSuccess(ids: [String]) {
        guard !ids.isEmpty else { return }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        let sql = "DELETE FROM sync_outbox WHERE id IN (\(placeholders));"

        queue.sync {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                for (index, id) in ids.enumerated() {
                    sqlite3_bind_text(stmt, Int32(index + 1), (id as NSString).utf8String, -1, nil)
                }
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    // MARK: - Memory Facts Operations (Editable & Bootstrapped)

    public func saveMemoryFact(_ fact: MemoryFact) {
        let sql = """
        INSERT INTO local_memory_facts (id, space_id, category, key, value, source, is_pinned, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            category = excluded.category,
            key = excluded.key,
            value = excluded.value,
            is_pinned = excluded.is_pinned,
            updated_at = excluded.updated_at;
        """

        queue.sync {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (fact.id as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (fact.spaceId as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 3, (fact.category as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 4, (fact.key as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 5, (fact.value as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 6, (fact.source as NSString).utf8String, -1, nil)
                sqlite3_bind_int(stmt, 7, fact.isPinned ? 1 : 0)
                sqlite3_bind_double(stmt, 8, fact.createdAt.timeIntervalSince1970)
                sqlite3_bind_double(stmt, 9, fact.updatedAt.timeIntervalSince1970)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }

        enqueueOutbox(entityType: "memory_fact", entityId: fact.id, spaceId: fact.spaceId, object: fact)
    }

    public func deleteMemoryFact(id: String, spaceId: String) {
        let sql = "DELETE FROM local_memory_facts WHERE id = ?;"
        queue.sync {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
        enqueueOutbox(entityType: "tombstone_memory", entityId: id, spaceId: spaceId, object: ["id": id])
    }

    public func getMemoryFacts(for spaceId: String) -> [MemoryFact] {
        let sql = "SELECT id, space_id, category, key, value, source, is_pinned, created_at, updated_at FROM local_memory_facts WHERE space_id = ? ORDER BY is_pinned DESC, category ASC, updated_at DESC;"
        return queue.sync {
            var facts: [MemoryFact] = []
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (spaceId as NSString).utf8String, -1, nil)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let id = String(cString: sqlite3_column_text(stmt, 0))
                    let spId = String(cString: sqlite3_column_text(stmt, 1))
                    let cat = String(cString: sqlite3_column_text(stmt, 2))
                    let key = String(cString: sqlite3_column_text(stmt, 3))
                    let val = String(cString: sqlite3_column_text(stmt, 4))
                    let src = String(cString: sqlite3_column_text(stmt, 5))
                    let isPinned = sqlite3_column_int(stmt, 6) != 0
                    let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7))
                    let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8))

                    facts.append(MemoryFact(
                        id: id, spaceId: spId, category: cat, key: key, value: val,
                        source: src, isPinned: isPinned, createdAt: createdAt, updatedAt: updatedAt
                    ))
                }
            }
            sqlite3_finalize(stmt)
            return facts
        }
    }

    // MARK: - Email Accounts Operations (Multiple Accounts Support)

    public func saveEmailAccount(_ account: EmailAccountConfig) {
        let sql = """
        INSERT INTO local_email_accounts (id, space_id, account_name, email_address, imap_host, imap_port, use_tls, auth_type, sync_folder, is_enabled, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            account_name = excluded.account_name,
            email_address = excluded.email_address,
            imap_host = excluded.imap_host,
            imap_port = excluded.imap_port,
            use_tls = excluded.use_tls,
            auth_type = excluded.auth_type,
            sync_folder = excluded.sync_folder,
            is_enabled = excluded.is_enabled;
        """

        queue.sync {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (account.id as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (account.spaceId as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 3, (account.accountName as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 4, (account.emailAddress as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 5, (account.imapHost as NSString).utf8String, -1, nil)
                sqlite3_bind_int(stmt, 6, Int32(account.imapPort))
                sqlite3_bind_int(stmt, 7, account.useTls ? 1 : 0)
                sqlite3_bind_text(stmt, 8, (account.authType as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 9, (account.syncFolder as NSString).utf8String, -1, nil)
                sqlite3_bind_int(stmt, 10, account.isEnabled ? 1 : 0)
                sqlite3_bind_double(stmt, 11, account.createdAt.timeIntervalSince1970)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    public func deleteEmailAccount(id: String) {
        let sql = "DELETE FROM local_email_accounts WHERE id = ?;"
        queue.sync {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    public func getEmailAccounts(for spaceId: String) -> [EmailAccountConfig] {
        let sql = "SELECT id, space_id, account_name, email_address, imap_host, imap_port, use_tls, auth_type, sync_folder, is_enabled, created_at FROM local_email_accounts WHERE space_id = ? ORDER BY created_at ASC;"
        return queue.sync {
            var stmt: OpaquePointer?
            var list: [EmailAccountConfig] = []
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (spaceId as NSString).utf8String, -1, nil)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let id = String(cString: sqlite3_column_text(stmt, 0))
                    let spId = String(cString: sqlite3_column_text(stmt, 1))
                    let name = String(cString: sqlite3_column_text(stmt, 2))
                    let email = String(cString: sqlite3_column_text(stmt, 3))
                    let host = String(cString: sqlite3_column_text(stmt, 4))
                    let port = Int(sqlite3_column_int(stmt, 5))
                    let tls = sqlite3_column_int(stmt, 6) == 1
                    let auth = String(cString: sqlite3_column_text(stmt, 7))
                    let folder = String(cString: sqlite3_column_text(stmt, 8))
                    let enabled = sqlite3_column_int(stmt, 9) == 1
                    let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 10))

                    list.append(EmailAccountConfig(
                        id: id,
                        spaceId: spId,
                        accountName: name,
                        emailAddress: email,
                        imapHost: host,
                        imapPort: port,
                        useTls: tls,
                        authType: auth,
                        syncFolder: folder,
                        isEnabled: enabled,
                        createdAt: createdAt
                    ))
                }
            }
            sqlite3_finalize(stmt)
            return list
        }
    }

    // MARK: - Context Spaces Operations (Configurable & Dynamic)

    public func saveContextSpace(_ space: ContextSpace) {
        guard ContextSpace.isValidSpaceId(space.id) else { return }

        let providersJson = (try? JSONEncoder().encode(space.allowedProviders)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        let sql = """
        INSERT INTO local_context_spaces (id, name, description, retention_days, allowed_providers, custom_prompt, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            name = excluded.name,
            description = excluded.description,
            retention_days = excluded.retention_days,
            allowed_providers = excluded.allowed_providers,
            custom_prompt = excluded.custom_prompt,
            updated_at = excluded.updated_at;
        """

        queue.sync {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (space.id as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (space.name as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 3, (space.description as NSString).utf8String, -1, nil)
                sqlite3_bind_int(stmt, 4, Int32(space.retentionDays))
                sqlite3_bind_text(stmt, 5, (providersJson as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 6, (space.customPrompt as NSString).utf8String, -1, nil)
                sqlite3_bind_double(stmt, 7, space.createdAt.timeIntervalSince1970)
                sqlite3_bind_double(stmt, 8, space.updatedAt.timeIntervalSince1970)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }

        enqueueOutbox(entityType: "context_space", entityId: space.id, spaceId: space.id, object: space)
    }

    public func deleteContextSpace(id: String) {
        // Protect default Work space from deletion
        guard id != "space-work", ContextSpace.isValidSpaceId(id) else { return }

        let sql = "DELETE FROM local_context_spaces WHERE id = ?;"
        queue.sync {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }

        enqueueOutbox(entityType: "context_space_tombstone", entityId: id, spaceId: id, object: ["deletedId": id])
    }

    public func getContextSpaces() -> [ContextSpace] {
        let sql = "SELECT id, name, description, retention_days, allowed_providers, custom_prompt, created_at, updated_at FROM local_context_spaces ORDER BY CASE id WHEN 'space-work' THEN 1 ELSE 2 END ASC, created_at ASC;"

        return queue.sync {
            var spaces: [ContextSpace] = []
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let id = String(cString: sqlite3_column_text(stmt, 0))
                    guard ContextSpace.isValidSpaceId(id) else { continue }
                    let name = String(cString: sqlite3_column_text(stmt, 1))
                    let desc = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                    let retention = Int(sqlite3_column_int(stmt, 3))
                    let providersStr = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? "[]"
                    let prompt = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? ""
                    let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
                    let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7))

                    let providers = (try? JSONDecoder().decode([String].self, from: Data(providersStr.utf8))) ?? ["elevenlabs", "openrouter"]

                    spaces.append(ContextSpace(
                        id: id,
                        name: name,
                        description: desc,
                        retentionDays: retention,
                        allowedProviders: providers,
                        customPrompt: prompt,
                        createdAt: createdAt,
                        updatedAt: updatedAt
                    ))
                }
            }
            sqlite3_finalize(stmt)
            return spaces
        }
    }

    public func getContextSpace(id: String) -> ContextSpace? {
        guard ContextSpace.isValidSpaceId(id) else { return nil }
        let sql = "SELECT id, name, description, retention_days, allowed_providers, custom_prompt, created_at, updated_at FROM local_context_spaces WHERE id = ?;"

        return queue.sync {
            var space: ContextSpace?
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
                if sqlite3_step(stmt) == SQLITE_ROW {
                    let spaceId = String(cString: sqlite3_column_text(stmt, 0))
                    let name = String(cString: sqlite3_column_text(stmt, 1))
                    let desc = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
                    let retention = Int(sqlite3_column_int(stmt, 3))
                    let providersStr = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? "[]"
                    let prompt = sqlite3_column_text(stmt, 5).map { String(cString: $0) } ?? ""
                    let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
                    let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7))

                    let providers = (try? JSONDecoder().decode([String].self, from: Data(providersStr.utf8))) ?? ["elevenlabs", "openrouter"]

                    space = ContextSpace(
                        id: spaceId,
                        name: name,
                        description: desc,
                        retentionDays: retention,
                        allowedProviders: providers,
                        customPrompt: prompt,
                        createdAt: createdAt,
                        updatedAt: updatedAt
                    )
                }
            }
            sqlite3_finalize(stmt)
            return space
        }
    }

    // MARK: - Custom Vocabulary Operations

    public func seedDefaultVocabularyIfNeeded() {
        let existing = getVocabulary()
        guard existing.isEmpty else { return }

        let defaults: [(String, String?, String?)] = [
            ("Sidebrief", "sighd-breef", nil)
        ]

        for (phrase, soundsLike, spaceId) in defaults {
            saveVocabularyItem(CustomVocabularyItem(
                spaceId: spaceId,
                phrase: phrase,
                soundsLike: soundsLike,
                boost: 2.0
            ))
        }
    }

    public func getVocabulary(spaceId: String? = nil) -> [CustomVocabularyItem] {
        var sql = "SELECT id, space_id, phrase, sounds_like, boost, created_at FROM local_custom_vocabulary"
        if let sp = spaceId, !sp.isEmpty {
            sql += " WHERE space_id IS NULL OR space_id = ?"
        }
        sql += " ORDER BY phrase ASC;"

        return queue.sync {
            var items: [CustomVocabularyItem] = []
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                if let sp = spaceId, !sp.isEmpty {
                    sqlite3_bind_text(stmt, 1, (sp as NSString).utf8String, -1, nil)
                }
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let id = String(cString: sqlite3_column_text(stmt, 0))
                    let sId = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
                    let phrase = String(cString: sqlite3_column_text(stmt, 2))
                    let soundsLike = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
                    let boost = sqlite3_column_double(stmt, 4)
                    let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))

                    items.append(CustomVocabularyItem(
                        id: id,
                        spaceId: sId,
                        phrase: phrase,
                        soundsLike: soundsLike,
                        boost: boost,
                        createdAt: createdAt
                    ))
                }
            }
            sqlite3_finalize(stmt)
            return items
        }
    }

    public func saveVocabularyItem(_ item: CustomVocabularyItem) {
        let sql = """
        INSERT INTO local_custom_vocabulary (id, space_id, phrase, sounds_like, boost, created_at)
        VALUES (?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            space_id = excluded.space_id,
            phrase = excluded.phrase,
            sounds_like = excluded.sounds_like,
            boost = excluded.boost;
        """
        queue.sync {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (item.id as NSString).utf8String, -1, nil)
                if let sp = item.spaceId {
                    sqlite3_bind_text(stmt, 2, (sp as NSString).utf8String, -1, nil)
                } else {
                    sqlite3_bind_null(stmt, 2)
                }
                sqlite3_bind_text(stmt, 3, (item.phrase as NSString).utf8String, -1, nil)
                if let sl = item.soundsLike {
                    sqlite3_bind_text(stmt, 4, (sl as NSString).utf8String, -1, nil)
                } else {
                    sqlite3_bind_null(stmt, 4)
                }
                sqlite3_bind_double(stmt, 5, item.boost)
                sqlite3_bind_double(stmt, 6, item.createdAt.timeIntervalSince1970)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    public func deleteVocabularyItem(id: String) {
        queue.sync {
            let sql = "DELETE FROM local_custom_vocabulary WHERE id = ?;"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    // MARK: - Speaker Profile Operations

    public func seedDefaultSpeakerProfilesIfNeeded(force: Bool = false) {
        let existing = getSpeakerProfiles()
        guard existing.isEmpty || force else { return }

        let savedName = UserDefaults.standard.string(forKey: "user_name") ?? ""
        let defaultName = !savedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? savedName.trimmingCharacters(in: .whitespacesAndNewlines)
            : (NSFullUserName().isEmpty ? "User" : NSFullUserName())

        let defaults: [SpeakerProfile] = [
            SpeakerProfile(
                id: "speaker-user-profile",
                spaceId: nil,
                name: defaultName,
                roleOrTitle: "Founder & Lead Architect",
                organization: "Sidebrief",
                notesOrContext: "Speaks as primary user/operator in meetings.",
                aliases: ["You"]
            ),
            SpeakerProfile(
                id: "sample-speaker-elena",
                spaceId: "space-work",
                name: "Elena Rostova",
                roleOrTitle: "VP of Engineering",
                organization: "Acme Labs",
                notesOrContext: "Technical leadership; focused on architecture and deliverables.",
                aliases: ["Elena"]
            ),
            SpeakerProfile(
                id: "sample-speaker-marcus",
                spaceId: "space-work",
                name: "Marcus Vance",
                roleOrTitle: "Managing Director",
                organization: "Vance Partners",
                notesOrContext: "Business strategy and timelines.",
                aliases: ["Marcus"]
            )
        ]

        for profile in defaults {
            saveSpeakerProfile(profile)
        }
    }

    public func getSpeakerProfiles(spaceId: String? = nil) -> [SpeakerProfile] {
        var sql = "SELECT id, space_id, name, role_or_title, organization, notes_or_context, aliases, created_at, updated_at, voiceprint_json, voice_sample_blob, gender_estimate FROM local_speaker_profiles"
        if let sp = spaceId, !sp.isEmpty {
            sql += " WHERE space_id IS NULL OR space_id = ?"
        }
        sql += " ORDER BY name ASC;"

        return queue.sync {
            var profiles: [SpeakerProfile] = []
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                if let sp = spaceId, !sp.isEmpty {
                    sqlite3_bind_text(stmt, 1, (sp as NSString).utf8String, -1, nil)
                }
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let id = String(cString: sqlite3_column_text(stmt, 0))
                    let spId = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
                    let name = String(cString: sqlite3_column_text(stmt, 2))
                    let role = sqlite3_column_text(stmt, 3).map { String(cString: $0) }
                    let org = sqlite3_column_text(stmt, 4).map { String(cString: $0) }
                    let notes = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
                    var aliases: [String] = []
                    if let rawAliases = sqlite3_column_text(stmt, 6) {
                        let jsonStr = String(cString: rawAliases)
                        aliases = (try? JSONDecoder().decode([String].self, from: Data(jsonStr.utf8))) ?? []
                    }
                    let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7))
                    let updatedAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8))

                    var voiceprint: Voiceprint? = nil
                    if let rawVp = sqlite3_column_text(stmt, 9) {
                        let jsonStr = String(cString: rawVp)
                        voiceprint = try? JSONDecoder().decode(Voiceprint.self, from: Data(jsonStr.utf8))
                    }

                    var voiceSampleWavData: Data? = nil
                    if let blobPtr = sqlite3_column_blob(stmt, 10) {
                        let bytes = sqlite3_column_bytes(stmt, 10)
                        if bytes > 0 {
                            voiceSampleWavData = Data(bytes: blobPtr, count: Int(bytes))
                        }
                    }

                    let genderEstimate = sqlite3_column_text(stmt, 11).map { String(cString: $0) }

                    profiles.append(SpeakerProfile(
                        id: id,
                        spaceId: spId,
                        name: name,
                        roleOrTitle: role,
                        organization: org,
                        notesOrContext: notes,
                        aliases: aliases,
                        voiceprint: voiceprint,
                        genderEstimate: genderEstimate,
                        voiceSampleWavData: voiceSampleWavData,
                        createdAt: createdAt,
                        updatedAt: updatedAt
                    ))
                }
            }
            sqlite3_finalize(stmt)
            return profiles
        }
    }

    public func saveSpeakerProfile(_ profile: SpeakerProfile) {
        let sql = """
        INSERT INTO local_speaker_profiles (id, space_id, name, role_or_title, organization, notes_or_context, aliases, created_at, updated_at, voiceprint_json, voice_sample_blob, gender_estimate)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            space_id = excluded.space_id,
            name = excluded.name,
            role_or_title = excluded.role_or_title,
            organization = excluded.organization,
            notes_or_context = excluded.notes_or_context,
            aliases = excluded.aliases,
            updated_at = excluded.updated_at,
            voiceprint_json = excluded.voiceprint_json,
            voice_sample_blob = excluded.voice_sample_blob,
            gender_estimate = excluded.gender_estimate;
        """
        let aliasesData = (try? JSONEncoder().encode(profile.aliases)) ?? Data()
        let aliasesJson = String(data: aliasesData, encoding: .utf8) ?? "[]"

        let voiceprintJson: String?
        if let vp = profile.voiceprint, let vpData = try? JSONEncoder().encode(vp) {
            voiceprintJson = String(data: vpData, encoding: .utf8)
        } else {
            voiceprintJson = nil
        }

        queue.sync {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (profile.id as NSString).utf8String, -1, nil)
                if let sp = profile.spaceId {
                    sqlite3_bind_text(stmt, 2, (sp as NSString).utf8String, -1, nil)
                } else {
                    sqlite3_bind_null(stmt, 2)
                }
                sqlite3_bind_text(stmt, 3, (profile.name as NSString).utf8String, -1, nil)
                if let r = profile.roleOrTitle {
                    sqlite3_bind_text(stmt, 4, (r as NSString).utf8String, -1, nil)
                } else {
                    sqlite3_bind_null(stmt, 4)
                }
                if let o = profile.organization {
                    sqlite3_bind_text(stmt, 5, (o as NSString).utf8String, -1, nil)
                } else {
                    sqlite3_bind_null(stmt, 5)
                }
                if let n = profile.notesOrContext {
                    sqlite3_bind_text(stmt, 6, (n as NSString).utf8String, -1, nil)
                } else {
                    sqlite3_bind_null(stmt, 6)
                }
                sqlite3_bind_text(stmt, 7, (aliasesJson as NSString).utf8String, -1, nil)
                sqlite3_bind_double(stmt, 8, profile.createdAt.timeIntervalSince1970)
                sqlite3_bind_double(stmt, 9, profile.updatedAt.timeIntervalSince1970)

                if let vpStr = voiceprintJson {
                    sqlite3_bind_text(stmt, 10, (vpStr as NSString).utf8String, -1, nil)
                } else {
                    sqlite3_bind_null(stmt, 10)
                }

                if let wav = profile.voiceSampleWavData, !wav.isEmpty {
                    _ = wav.withUnsafeBytes { rawPtr in
                        sqlite3_bind_blob(stmt, 11, rawPtr.baseAddress, Int32(wav.count), SQLITE_TRANSIENT)
                    }
                } else {
                    sqlite3_bind_null(stmt, 11)
                }

                if let g = profile.genderEstimate {
                    sqlite3_bind_text(stmt, 12, (g as NSString).utf8String, -1, nil)
                } else {
                    sqlite3_bind_null(stmt, 12)
                }

                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    public func batchRenameSpeakersInTranscript(meetingId: String, renames: [String: String]) {
        queue.sync {
            let sql = """
            UPDATE local_transcript_segments
            SET speaker_label = ?, revision = revision + 1
            WHERE meeting_id = ? AND speaker_label = ?;
            """
            for (oldLabel, newLabel) in renames {
                let trimmedNew = newLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                guard oldLabel != trimmedNew, !trimmedNew.isEmpty else { continue }
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(stmt, 1, (trimmedNew as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(stmt, 2, (meetingId as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(stmt, 3, (oldLabel as NSString).utf8String, -1, nil)
                    sqlite3_step(stmt)
                }
                sqlite3_finalize(stmt)
            }
        }
    }

    public func deleteSpeakerProfile(id: String) {
        queue.sync {
            let sql = "DELETE FROM local_speaker_profiles WHERE id = ?;"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    // MARK: - Audio Chunks Operations

    public func saveAudioChunks(_ chunks: [AudioChunk]) {
        guard !chunks.isEmpty else { return }
        let sql = """
        INSERT INTO local_audio_chunks (
            id, track_id, meeting_id, sequence_number, stream_epoch,
            start_offset_ms, end_offset_ms, sample_count, byte_count,
            checksum_sha256, encryption_key_version, encryption_nonce_hex,
            local_encrypted_file_path, remote_object_key, upload_state, created_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            remote_object_key = excluded.remote_object_key,
            upload_state = excluded.upload_state;
        """

        queue.sync {
            sqlite3_exec(db, "BEGIN TRANSACTION;", nil, nil, nil)
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                for chunk in chunks {
                    sqlite3_bind_text(stmt, 1, (chunk.id as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(stmt, 2, (chunk.trackId as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(stmt, 3, (chunk.meetingId as NSString).utf8String, -1, nil)
                    sqlite3_bind_int(stmt, 4, Int32(chunk.sequenceNumber))
                    sqlite3_bind_int64(stmt, 5, chunk.streamEpoch)
                    sqlite3_bind_int64(stmt, 6, chunk.startOffsetMs)
                    sqlite3_bind_int64(stmt, 7, chunk.endOffsetMs)
                    sqlite3_bind_int(stmt, 8, Int32(chunk.sampleCount))
                    sqlite3_bind_int(stmt, 9, Int32(chunk.byteCount))
                    sqlite3_bind_text(stmt, 10, (chunk.checksumSha256 as NSString).utf8String, -1, nil)
                    sqlite3_bind_int(stmt, 11, Int32(chunk.encryptionKeyVersion))
                    sqlite3_bind_text(stmt, 12, (chunk.encryptionNonceHex as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(stmt, 13, (chunk.localEncryptedFilePath as NSString).utf8String, -1, nil)
                    if let remote = chunk.remoteObjectKey {
                        sqlite3_bind_text(stmt, 14, (remote as NSString).utf8String, -1, nil)
                    } else {
                        sqlite3_bind_null(stmt, 14)
                    }
                    sqlite3_bind_text(stmt, 15, (chunk.uploadState.rawValue as NSString).utf8String, -1, nil)
                    sqlite3_bind_double(stmt, 16, chunk.createdAt.timeIntervalSince1970)
                    sqlite3_step(stmt)
                    sqlite3_reset(stmt)
                }
            }
            sqlite3_finalize(stmt)
            sqlite3_exec(db, "COMMIT;", nil, nil, nil)
        }
    }

    public func saveAudioChunk(_ chunk: AudioChunk) {
        saveAudioChunks([chunk])
    }

    public func getAudioChunks(meetingId: String) -> [AudioChunk] {
        let sql = """
        SELECT id, track_id, meeting_id, sequence_number, stream_epoch,
               start_offset_ms, end_offset_ms, sample_count, byte_count,
               checksum_sha256, encryption_key_version, encryption_nonce_hex,
               local_encrypted_file_path, remote_object_key, upload_state, created_at
        FROM local_audio_chunks
        WHERE meeting_id = ?
        ORDER BY sequence_number ASC;
        """

        return queue.sync {
            var chunks: [AudioChunk] = []
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (meetingId as NSString).utf8String, -1, nil)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let id = String(cString: sqlite3_column_text(stmt, 0))
                    let trackId = String(cString: sqlite3_column_text(stmt, 1))
                    let mId = String(cString: sqlite3_column_text(stmt, 2))
                    let seq = Int(sqlite3_column_int(stmt, 3))
                    let epoch = sqlite3_column_int64(stmt, 4)
                    let startMs = sqlite3_column_int64(stmt, 5)
                    let endMs = sqlite3_column_int64(stmt, 6)
                    let sampleCount = Int(sqlite3_column_int(stmt, 7))
                    let byteCount = Int(sqlite3_column_int(stmt, 8))
                    let checksum = String(cString: sqlite3_column_text(stmt, 9))
                    let keyVer = Int(sqlite3_column_int(stmt, 10))
                    let nonce = String(cString: sqlite3_column_text(stmt, 11))
                    let localPath = String(cString: sqlite3_column_text(stmt, 12))
                    let remoteKey = sqlite3_column_text(stmt, 13).map { String(cString: $0) }
                    let stateStr = String(cString: sqlite3_column_text(stmt, 14))
                    let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 15))

                    chunks.append(AudioChunk(
                        id: id,
                        trackId: trackId,
                        meetingId: mId,
                        sequenceNumber: seq,
                        streamEpoch: epoch,
                        startOffsetMs: startMs,
                        endOffsetMs: endMs,
                        sampleCount: sampleCount,
                        byteCount: byteCount,
                        checksumSha256: checksum,
                        encryptionKeyVersion: keyVer,
                        encryptionNonceHex: nonce,
                        localEncryptedFilePath: localPath,
                        remoteObjectKey: remoteKey,
                        uploadState: ChunkUploadState(rawValue: stateStr) ?? .localOnly,
                        createdAt: createdAt
                    ))
                }
            }
            sqlite3_finalize(stmt)
            return chunks
        }
    }

    public func getPendingUploadChunks(limit: Int = 25) -> [AudioChunk] {
        let sql = """
        SELECT id, track_id, meeting_id, sequence_number, stream_epoch,
               start_offset_ms, end_offset_ms, sample_count, byte_count,
               checksum_sha256, encryption_key_version, encryption_nonce_hex,
               local_encrypted_file_path, remote_object_key, upload_state, created_at
        FROM local_audio_chunks
        WHERE upload_state = 'localOnly' OR upload_state = 'queued' OR upload_state = 'failed'
        ORDER BY created_at ASC
        LIMIT ?;
        """

        return queue.sync {
            var chunks: [AudioChunk] = []
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_int(stmt, 1, Int32(limit))
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let id = String(cString: sqlite3_column_text(stmt, 0))
                    let trackId = String(cString: sqlite3_column_text(stmt, 1))
                    let mId = String(cString: sqlite3_column_text(stmt, 2))
                    let seq = Int(sqlite3_column_int(stmt, 3))
                    let epoch = sqlite3_column_int64(stmt, 4)
                    let startMs = sqlite3_column_int64(stmt, 5)
                    let endMs = sqlite3_column_int64(stmt, 6)
                    let sampleCount = Int(sqlite3_column_int(stmt, 7))
                    let byteCount = Int(sqlite3_column_int(stmt, 8))
                    let checksum = String(cString: sqlite3_column_text(stmt, 9))
                    let keyVer = Int(sqlite3_column_int(stmt, 10))
                    let nonce = String(cString: sqlite3_column_text(stmt, 11))
                    let localPath = String(cString: sqlite3_column_text(stmt, 12))
                    let remoteKey = sqlite3_column_text(stmt, 13).map { String(cString: $0) }
                    let stateStr = String(cString: sqlite3_column_text(stmt, 14))
                    let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 15))

                    chunks.append(AudioChunk(
                        id: id,
                        trackId: trackId,
                        meetingId: mId,
                        sequenceNumber: seq,
                        streamEpoch: epoch,
                        startOffsetMs: startMs,
                        endOffsetMs: endMs,
                        sampleCount: sampleCount,
                        byteCount: byteCount,
                        checksumSha256: checksum,
                        encryptionKeyVersion: keyVer,
                        encryptionNonceHex: nonce,
                        localEncryptedFilePath: localPath,
                        remoteObjectKey: remoteKey,
                        uploadState: ChunkUploadState(rawValue: stateStr) ?? .localOnly,
                        createdAt: createdAt
                    ))
                }
            }
            sqlite3_finalize(stmt)
            return chunks
        }
    }

    public func updateChunkUploadState(id: String, state: ChunkUploadState, remoteObjectKey: String? = nil) {
        let sql = """
        UPDATE local_audio_chunks
        SET upload_state = ?, remote_object_key = COALESCE(?, remote_object_key)
        WHERE id = ?;
        """
        queue.sync {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (state.rawValue as NSString).utf8String, -1, nil)
                if let r = remoteObjectKey {
                    sqlite3_bind_text(stmt, 2, (r as NSString).utf8String, -1, nil)
                } else {
                    sqlite3_bind_null(stmt, 2)
                }
                sqlite3_bind_text(stmt, 3, (id as NSString).utf8String, -1, nil)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }
}
