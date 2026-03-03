//
//  TranscriptionRecordSchema.swift
//  Pindrop
//
//  Created on 2026-01-28.
//  Schema versioning for TranscriptionRecord to support migrations
//

import Foundation
import SwiftData

enum TranscriptionRecordSchema: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 2)
    
    static var models: [any PersistentModel.Type] {
        [TranscriptionRecord.self]
    }
    
    // V1: Original schema without AI enhancement metadata
    @Model
    final class TranscriptionRecordV1 {
        @Attribute(.unique) var id: UUID
        var text: String
        var timestamp: Date
        var duration: TimeInterval
        var modelUsed: String
        
        init(
            id: UUID = UUID(),
            text: String,
            timestamp: Date = Date(),
            duration: TimeInterval,
            modelUsed: String
        ) {
            self.id = id
            self.text = text
            self.timestamp = timestamp
            self.duration = duration
            self.modelUsed = modelUsed
        }
    }
    
    // V3: Current schema with AI enhancement + diarization metadata
    @Model
    final class TranscriptionRecord {
        @Attribute(.unique) var id: UUID
        var text: String
        var originalText: String?
        var timestamp: Date
        var duration: TimeInterval
        var modelUsed: String
        var enhancedWith: String?
        var diarizationSegmentsJSON: String?
        @Transient var wasEnhanced: Bool = false
        
        init(
            id: UUID = UUID(),
            text: String,
            originalText: String? = nil,
            timestamp: Date = Date(),
            duration: TimeInterval,
            modelUsed: String,
            enhancedWith: String? = nil,
            diarizationSegmentsJSON: String? = nil
        ) {
            self.id = id
            self.text = text
            self.originalText = originalText
            self.timestamp = timestamp
            self.duration = duration
            self.modelUsed = modelUsed
            self.enhancedWith = enhancedWith
            self.diarizationSegmentsJSON = diarizationSegmentsJSON
            self.wasEnhanced = originalText != nil && originalText != text
        }
    }
}

// V1 Schema Version
enum TranscriptionRecordSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)
    
    static var models: [any PersistentModel.Type] {
        [TranscriptionRecordV1.self]
    }
    
    @Model
    final class TranscriptionRecordV1 {
        @Attribute(.unique) var id: UUID
        var text: String
        var timestamp: Date
        var duration: TimeInterval
        var modelUsed: String
        
        init(
            id: UUID = UUID(),
            text: String,
            timestamp: Date = Date(),
            duration: TimeInterval,
            modelUsed: String
        ) {
            self.id = id
            self.text = text
            self.timestamp = timestamp
            self.duration = duration
            self.modelUsed = modelUsed
        }
    }
}

// V2 Schema Version
enum TranscriptionRecordSchemaV2: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 1)

    static var models: [any PersistentModel.Type] {
        [TranscriptionRecord.self]
    }

    @Model
    final class TranscriptionRecord {
        @Attribute(.unique) var id: UUID
        var text: String
        var originalText: String?
        var timestamp: Date
        var duration: TimeInterval
        var modelUsed: String
        var enhancedWith: String?
        @Transient var wasEnhanced: Bool = false
        
        init(
            id: UUID = UUID(),
            text: String,
            originalText: String? = nil,
            timestamp: Date = Date(),
            duration: TimeInterval,
            modelUsed: String,
            enhancedWith: String? = nil
        ) {
            self.id = id
            self.text = text
            self.originalText = originalText
            self.timestamp = timestamp
            self.duration = duration
            self.modelUsed = modelUsed
            self.enhancedWith = enhancedWith
            self.wasEnhanced = originalText != nil && originalText != text
        }
    }
}

// V3 Schema Version (Current)
enum TranscriptionRecordSchemaV3: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 2)

    static var models: [any PersistentModel.Type] {
        [TranscriptionRecord.self]
    }

    @Model
    final class TranscriptionRecord {
        @Attribute(.unique) var id: UUID
        var text: String
        var originalText: String?
        var timestamp: Date
        var duration: TimeInterval
        var modelUsed: String
        var enhancedWith: String?
        var diarizationSegmentsJSON: String?
        @Transient var wasEnhanced: Bool = false
        
        init(
            id: UUID = UUID(),
            text: String,
            originalText: String? = nil,
            timestamp: Date = Date(),
            duration: TimeInterval,
            modelUsed: String,
            enhancedWith: String? = nil,
            diarizationSegmentsJSON: String? = nil
        ) {
            self.id = id
            self.text = text
            self.originalText = originalText
            self.timestamp = timestamp
            self.duration = duration
            self.modelUsed = modelUsed
            self.enhancedWith = enhancedWith
            self.diarizationSegmentsJSON = diarizationSegmentsJSON
            self.wasEnhanced = originalText != nil && originalText != text
        }
    }
}

// Migration Plan
enum TranscriptionRecordMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [TranscriptionRecordSchemaV1.self, TranscriptionRecordSchemaV2.self, TranscriptionRecordSchemaV3.self]
    }

    static var stages: [MigrationStage] {
        [migrateV1toV2, migrateV2toV3]
    }

    // Lightweight migration from V1 to V2
    // Adds optional originalText and enhancedWith fields
    // Existing records will have nil values for new fields
    static let migrateV1toV2 = MigrationStage.lightweight(
        fromVersion: TranscriptionRecordSchemaV1.self,
        toVersion: TranscriptionRecordSchemaV2.self
    )

    // Lightweight migration from V2 to V3
    // Adds optional diarizationSegmentsJSON field
    // Existing records will have nil values for the new field
    static let migrateV2toV3 = MigrationStage.lightweight(
        fromVersion: TranscriptionRecordSchemaV2.self,
        toVersion: TranscriptionRecordSchemaV3.self
    )
}
