import Foundation
import XCTest
@testable import AagedalFTPSync

final class ConfigurationTransferCoordinatorTests: XCTestCase {
    private let coordinator = ConfigurationTransferCoordinator()

    func testPackageImportRemapsJobIDNameAndProgrammingTarget() throws {
        let fixture = makeFixture(jobName: "News Desk", prefix: "ND")
        let existingJob = SyncJob(name: "news desk")
        let currentState = ConfigurationTransferState(
            jobs: [existingJob],
            metadataPresets: [],
            photographers: []
        )
        let data = try coordinator.exportData(
            scope: .package,
            password: nil,
            state: ConfigurationTransferState(
                jobs: [fixture.job],
                metadataPresets: [fixture.preset],
                photographers: [fixture.photographer]
            )
        )

        let prepared = try coordinator.prepareImport(
            from: data,
            password: nil,
            currentState: currentState
        )

        let remappedID = try XCTUnwrap(prepared.importedJobIDs[fixture.job.id])
        XCTAssertNotEqual(remappedID, fixture.job.id)
        XCTAssertEqual(prepared.selectedJobID, remappedID)
        XCTAssertEqual(prepared.state.jobs.map(\.name), ["news desk", "News Desk (Imported)"])
        let importedJob = try XCTUnwrap(prepared.state.jobs.first { $0.id == remappedID })
        XCTAssertEqual(importedJob.metadataAutomation, fixture.job.metadataAutomation)
        XCTAssertFalse(importedJob.isEnabled)
        XCTAssertFalse(importedJob.startsOnAppLaunch)
        XCTAssertEqual(prepared.result.importedJobs, 1)
        XCTAssertEqual(prepared.result.importedMetadataProgramming, 1)
    }

    func testMetadataImportMatchesAUniqueJobNameIgnoringCaseAndDiacritics() throws {
        let fixture = makeFixture(jobName: "Bérgen Desk", prefix: "BG")
        var existingJob = SyncJob(name: "bergen desk")
        existingJob.id = UUID()
        let data = try coordinator.exportData(
            scope: .metadata,
            password: nil,
            state: ConfigurationTransferState(
                jobs: [fixture.job],
                metadataPresets: [],
                photographers: [fixture.photographer]
            )
        )

        let prepared = try coordinator.prepareImport(
            from: data,
            password: nil,
            currentState: ConfigurationTransferState(
                jobs: [existingJob],
                metadataPresets: [],
                photographers: []
            )
        )

        XCTAssertEqual(prepared.state.jobs.count, 1)
        XCTAssertEqual(prepared.state.jobs[0].id, existingJob.id)
        XCTAssertEqual(prepared.state.jobs[0].metadataAutomation, fixture.job.metadataAutomation)
        XCTAssertNil(prepared.selectedJobID)
        XCTAssertTrue(prepared.importedJobIDs.isEmpty)
        XCTAssertEqual(prepared.result.importedMetadataProgramming, 1)
        XCTAssertEqual(prepared.result.skippedMetadataProgramming, 0)
    }

    func testMetadataImportCountsProgrammingWithoutAUniqueTargetAsSkipped() throws {
        let fixture = makeFixture(jobName: "Shared Desk", prefix: "SD")
        let data = try coordinator.exportData(
            scope: .metadata,
            password: nil,
            state: ConfigurationTransferState(
                jobs: [fixture.job],
                metadataPresets: [],
                photographers: [fixture.photographer]
            )
        )
        let currentState = ConfigurationTransferState(
            jobs: [SyncJob(name: "Shared Desk"), SyncJob(name: "shared desk")],
            metadataPresets: [],
            photographers: []
        )

        let prepared = try coordinator.prepareImport(
            from: data,
            password: nil,
            currentState: currentState
        )

        XCTAssertTrue(prepared.state.jobs.allSatisfy { $0.metadataAutomation == nil })
        XCTAssertEqual(prepared.result.importedMetadataProgramming, 0)
        XCTAssertEqual(prepared.result.skippedMetadataProgramming, 1)
    }

    func testImportRejectsDuplicateJobIDs() throws {
        let fixture = makeFixture(jobName: "Duplicate", prefix: "DU")
        let transfer = ConfigurationTransfer(
            scope: .jobs,
            jobs: [fixture.job, fixture.job],
            metadataPresets: [],
            photographers: []
        )
        let data = try ConfigurationTransferCodec.encode(transfer, password: nil)

        XCTAssertThrowsError(
            try coordinator.prepareImport(from: data, password: nil, currentState: emptyState)
        ) { error in
            XCTAssertEqual(error.localizedDescription, "The package contains the same sync job more than once.")
        }
    }

    func testImportRejectsDuplicateProgrammingJobIDs() throws {
        let fixture = makeFixture(jobName: "Duplicate Programming", prefix: "DP")
        let transfer = ConfigurationTransfer(
            scope: .metadata,
            jobs: [fixture.job, fixture.job],
            metadataPresets: [],
            photographers: [fixture.photographer]
        )
        let data = try ConfigurationTransferCodec.encode(transfer, password: nil)

        XCTAssertThrowsError(
            try coordinator.prepareImport(from: data, password: nil, currentState: emptyState)
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "The package contains metadata programming for the same job more than once."
            )
        }
    }

    func testImportRejectsPhotographerInitialsConflictingWithExistingLibrary() throws {
        let fixture = makeFixture(jobName: "Imported", prefix: "DUP")
        let existingPhotographer = PhotographerProfile(
            name: "Existing",
            filenamePrefix: "dup",
            creator: "Existing",
            copyrightNotice: "Existing copyright"
        )
        let data = try coordinator.exportData(
            scope: .metadata,
            password: nil,
            state: ConfigurationTransferState(
                jobs: [fixture.job],
                metadataPresets: [],
                photographers: [fixture.photographer]
            )
        )
        let currentState = ConfigurationTransferState(
            jobs: [],
            metadataPresets: [],
            photographers: [existingPhotographer]
        )

        XCTAssertThrowsError(
            try coordinator.prepareImport(from: data, password: nil, currentState: currentState)
        ) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "The filename initials DUP conflict with an existing photographer."
            )
        }
        XCTAssertEqual(currentState.photographers, [existingPhotographer])
    }

    private var emptyState: ConfigurationTransferState {
        ConfigurationTransferState(jobs: [], metadataPresets: [], photographers: [])
    }

    private func makeFixture(
        jobName: String,
        prefix: String
    ) -> (job: SyncJob, photographer: PhotographerProfile, preset: MetadataPreset) {
        let photographer = PhotographerProfile(
            name: "Ada Photographer",
            filenamePrefix: prefix,
            creator: "Ada Photographer",
            copyrightNotice: "Copyright Ada"
        )
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let clip = MetadataScheduleClip(
            photographerID: photographer.id,
            name: "Assignment",
            startsAt: start,
            endsAt: start.addingTimeInterval(3_600),
            fields: ScheduledMetadataFields(headline: "City hall")
        )
        let automation = MetadataAutomation(
            isEnabled: true,
            photographers: [photographer],
            clips: [clip]
        )
        var job = SyncJob(name: jobName)
        job.metadataAutomation = automation
        return (
            job,
            photographer,
            MetadataPreset(name: "Preset", fields: clip.fields)
        )
    }
}
