//
//  CloudKitExchange+HandlingCloudChanges.swift
//  Forked
//
//  Created by Drew McCormack on 27/08/2024.
//
import CloudKit
import Forked
import os.log

@available(iOS 17.0, tvOS 17.0, watchOS 9.0, macOS 14.0, *)
extension CloudKitExchange {
    
    func handleAccountChange(_ event: CKSyncEngine.Event.AccountChange) {
        do {
            try forkedResource.performAtomically {
                switch event.changeType {
                case .signIn, .switchAccounts:
                    try removeForks()
                    try createForks()
                case .signOut:
                    try removeForks()
                @unknown default:
                    Logger.exchange.log("Unknown account change type: \(event)")
                }
            }
            delegate?.exchangeDidUpdateAllForks(self)
        } catch {
            Logger.exchange.error("Failure during handling of account change: \(error)")
        }
    }
    
    func handleFetchedDatabaseChanges(_ event: CKSyncEngine.Event.FetchedDatabaseChanges) {
        for deletion in event.deletions {
            switch deletion.zoneID.zoneName {
            case zoneID.zoneName:
                do {
                    try removeForks()
                } catch {
                    Logger.exchange.error("Failed to delete content when zone removed: \(error)")
                }
            default:
                Logger.exchange.info("Received deletion for unknown zone: \(deletion.zoneID)")
            }
        }
    }
    
    func handleFetchedRecordZoneChanges(_ event: CKSyncEngine.Event.FetchedRecordZoneChanges) {
        for modification in event.modifications {
            let record = modification.record
            let id = record.recordID.recordName
            guard self.id == id else { continue }
            
            guard let data = record.encryptedValues[CKRecord.resourceDataKey] as? Data else {
                Logger.exchange.error("No data found in CKRecord")
                continue
            }
            
            do {
                let resource = try JSONDecoder().decode(R.Resource.self, from: data)
                try forkedResource.update(.cloudKitReceive, with: resource)
                try forkedResource.mergeIntoMain(from: .cloudKitReceive)
            } catch {
                Logger.exchange.error("Failed to update resource with downloaded data: \(error)")
            }
        }
        
        for deletion in event.deletions {
            let id = deletion.recordID.recordName
            guard self.id == id else { continue }
            do {
                try forkedResource.update(.cloudKitReceive, with: .none)
                try forkedResource.mergeIntoMain(from: .cloudKitReceive)
            } catch {
                Logger.exchange.error("Failed to update resource with downloaded data: \(error)")
            }
        }
    }
    
    func handleSentRecordZoneChanges(_ event: CKSyncEngine.Event.SentRecordZoneChanges) {
        for savedRecord in event.savedRecords {
            let id = savedRecord.recordID.recordName
            guard self.id == id else { continue }

            guard let data = savedRecord.encryptedValues[CKRecord.resourceDataKey] as? Data else {
                Logger.exchange.error("No data found in CKRecord")
                continue
            }
            
            do {
                let resource = try JSONDecoder().decode(R.Resource.self, from: data)
                try forkedResource.update(.cloudKitSend, with: resource)
            } catch {
                Logger.exchange.error("Failed to update resource with downloaded data: \(error)")
            }
        }
        
        for failedRecordSave in event.failedRecordSaves {
            let failedRecord = failedRecordSave.record
            let id = failedRecord.recordID.recordName
            guard self.id == id else { continue }
            
            switch failedRecordSave.error.code {
            case .serverRecordChanged:
                break // Conflict. Just wait for the new record to download
            case .zoneNotFound:
                do {
                    try removeForks()
                    try createForks()
                    let zone = CKRecordZone(zoneID: failedRecord.recordID.zoneID)
                    engine.state.add(pendingDatabaseChanges: [.saveZone(zone)])
                } catch {
                    Logger.exchange.error("Failed to recover from missing zone: \(error)")
                }
            case .unknownItem:
                engine.state.add(pendingRecordZoneChanges: [.saveRecord(failedRecord.recordID)]) // Reupload
            case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .notAuthenticated, .operationCancelled:
                Logger.exchange.debug("Retryable error saving \(failedRecord.recordID): \(failedRecordSave.error)")
            default:
                Logger.exchange.fault("Unknown error saving record \(failedRecord.recordID): \(failedRecordSave.error)")
            }
        }
    }
}
