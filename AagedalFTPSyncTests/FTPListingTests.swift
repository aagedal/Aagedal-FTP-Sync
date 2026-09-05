import Network
import XCTest
@testable import AagedalFTPSync

final class FTPListingTests: XCTestCase {
    func testFailedRollbackRetainsOriginalBackupAndReportsItsLocation() async throws {
        let original = SyncFile(relativePath: "NEWS.CR3", size: 3, modifiedAt: Date())
        let sidecar = SyncFile(relativePath: "NEWS.xmp", size: 4, modifiedAt: Date())
        let destination = PartialFailureDestination(
            files: [original.relativePath: original, sidecar.relativePath: sidecar],
            failedImportPath: sidecar.relativePath,
            failsRollback: true
        )
        let input = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("incoming".utf8).write(to: input)
        defer { try? FileManager.default.removeItem(at: input) }
        var message = ""
        do {
            try await destination.importFilesTransactionally(
                [EndpointFileImport(localURL: input, file: original), EndpointFileImport(localURL: input, file: sidecar)],
                replacing: [original.relativePath: original, sidecar.relativePath: sidecar],
                preserveDate: true, verifySize: true
            )
            XCTFail("Publication and rollback should fail")
        } catch { message = error.localizedDescription }
        let backups = await destination.exportedBackups
        defer { for url in backups.values { try? FileManager.default.removeItem(at: url) } }
        let retained = try XCTUnwrap(backups[original.relativePath])
        XCTAssertEqual(try Data(contentsOf: retained), Data(repeating: 3, count: 3))
        XCTAssertTrue(message.contains(retained.path))
        let unused = try XCTUnwrap(backups[sidecar.relativePath])
        XCTAssertFalse(FileManager.default.fileExists(atPath: unused.path))
    }

    func testCompanionFailureRemovesNewPrimaryFile() async throws {
        let baseDate = Date(timeIntervalSince1970: 1_800_000_000)
        let primary = SyncFile(relativePath: "NEWS.CR3", size: 5, modifiedAt: baseDate)
        let sidecar = SyncFile(relativePath: "NEWS.xmp", size: 6, modifiedAt: baseDate)
        let timeline = FastStartTimeline()
        let source = FastStartSource(
            files: [primary.relativePath: primary, sidecar.relativePath: sidecar],
            timeline: timeline
        )
        let destination = PartialFailureDestination(failedImportPath: sidecar.relativePath)
        let engine = SyncEngine(sessionFactory: { endpoint, _, _ -> any EndpointSession in
            endpoint.kind.isRemote ? source : destination
        })

        do {
            _ = try await engine.run(
                job: partialFailureJob(),
                leftPassword: "secret",
                rightPassword: nil
            )
            XCTFail("The companion import should fail")
        } catch let failure as SyncRunFailure {
            XCTAssertEqual(failure.failureDescription, "Injected import failure for NEWS.xmp")
            XCTAssertEqual(failure.partialResult, SyncResult(transferred: 0, deleted: 0))
        }

        let storedPaths = await destination.storedPaths
        XCTAssertEqual(storedPaths, [])
    }

    func testCompanionFailureRestoresExistingPrimaryAndSidecar() async throws {
        let baseDate = Date(timeIntervalSince1970: 1_800_000_000)
        let existingPrimary = SyncFile(relativePath: "NEWS.CR3", size: 3, modifiedAt: baseDate)
        let existingSidecar = SyncFile(relativePath: "NEWS.xmp", size: 4, modifiedAt: baseDate)
        let incomingPrimary = SyncFile(
            relativePath: existingPrimary.relativePath,
            size: 7,
            modifiedAt: baseDate.addingTimeInterval(10)
        )
        let incomingSidecar = SyncFile(
            relativePath: existingSidecar.relativePath,
            size: 8,
            modifiedAt: baseDate.addingTimeInterval(10)
        )
        let timeline = FastStartTimeline()
        let source = FastStartSource(
            files: [
                incomingPrimary.relativePath: incomingPrimary,
                incomingSidecar.relativePath: incomingSidecar,
            ],
            timeline: timeline
        )
        let originalFiles = [
            existingPrimary.relativePath: existingPrimary,
            existingSidecar.relativePath: existingSidecar,
        ]
        let destination = PartialFailureDestination(
            files: originalFiles,
            failedImportPath: incomingSidecar.relativePath
        )
        let engine = SyncEngine(sessionFactory: { endpoint, _, _ -> any EndpointSession in
            endpoint.kind.isRemote ? source : destination
        })

        do {
            _ = try await engine.run(
                job: partialFailureJob(),
                leftPassword: "secret",
                rightPassword: nil
            )
            XCTFail("The companion import should fail")
        } catch let failure as SyncRunFailure {
            XCTAssertEqual(failure.partialResult, SyncResult(transferred: 0, deleted: 0))
        }

        let storedFiles = await destination.storedFiles
        XCTAssertEqual(storedFiles, originalFiles)
    }

    func testCancellationDuringCompanionPublicationRollsBackAndRemainsCancellation() async throws {
        let baseDate = Date(timeIntervalSince1970: 1_800_000_000)
        let primary = SyncFile(relativePath: "NEWS.CR3", size: 5, modifiedAt: baseDate)
        let sidecar = SyncFile(relativePath: "NEWS.xmp", size: 6, modifiedAt: baseDate)
        let timeline = FastStartTimeline()
        let source = FastStartSource(
            files: [primary.relativePath: primary, sidecar.relativePath: sidecar],
            timeline: timeline
        )
        let destination = PartialFailureDestination(blockedImportPath: sidecar.relativePath)
        let engine = SyncEngine(sessionFactory: { endpoint, _, _ -> any EndpointSession in
            endpoint.kind.isRemote ? source : destination
        })
        let job = partialFailureJob()
        let runTask = Task {
            try await engine.run(
                job: job,
                leftPassword: "secret",
                rightPassword: nil
            )
        }

        var publishedPrimary = false
        for _ in 0..<200 {
            if await destination.storedPaths.contains(primary.relativePath) {
                publishedPrimary = true
                break
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(publishedPrimary)
        runTask.cancel()

        do {
            _ = try await runTask.value
            XCTFail("The run should remain cancelled")
        } catch is CancellationError {
            // Expected.
        }
        let storedPaths = await destination.storedPaths
        XCTAssertEqual(storedPaths, [])
    }

    func testLaterTransferFailureReportsEarlierCompletedFiles() async throws {
        let baseDate = Date(timeIntervalSince1970: 1_800_000_000)
        let completed = SyncFile(
            relativePath: "FIRST.JPG",
            size: 5,
            modifiedAt: baseDate.addingTimeInterval(2)
        )
        let failed = SyncFile(
            relativePath: "SECOND.JPG",
            size: 6,
            modifiedAt: baseDate.addingTimeInterval(1)
        )
        let timeline = FastStartTimeline()
        let source = FastStartSource(
            files: [completed.relativePath: completed, failed.relativePath: failed],
            timeline: timeline
        )
        let destination = PartialFailureDestination(failedImportPath: failed.relativePath)
        let engine = SyncEngine(sessionFactory: { endpoint, _, _ -> any EndpointSession in
            if endpoint.kind.isRemote {
                return source
            }
            return destination
        })
        let job = partialFailureJob()

        do {
            _ = try await engine.run(job: job, leftPassword: "secret", rightPassword: nil)
            XCTFail("The second import should fail")
        } catch let failure as SyncRunFailure {
            XCTAssertEqual(failure.failureDescription, "Injected import failure for SECOND.JPG")
            XCTAssertEqual(failure.partialResult, SyncResult(transferred: 1, deleted: 0))
        }

        let storedPaths = await destination.storedPaths
        XCTAssertEqual(storedPaths, [completed.relativePath])
    }

    func testCleanupFailureCombinesTransfersAndEarlierDeletions() async throws {
        let now = Date()
        let sourceFile = SyncFile(relativePath: "NEW.JPG", size: 3, modifiedAt: now)
        let firstOldFile = SyncFile(
            relativePath: "FIRST-OLD.JPG",
            size: 1,
            modifiedAt: now.addingTimeInterval(-4 * 3_600)
        )
        let failedOldFile = SyncFile(
            relativePath: "SECOND-OLD.JPG",
            size: 2,
            modifiedAt: now.addingTimeInterval(-3 * 3_600)
        )
        let timeline = FastStartTimeline()
        let source = FastStartSource(files: [sourceFile.relativePath: sourceFile], timeline: timeline)
        let destination = PartialFailureDestination(
            files: [
                firstOldFile.relativePath: firstOldFile,
                failedOldFile.relativePath: failedOldFile,
            ],
            failedDeletePath: failedOldFile.relativePath
        )
        let engine = SyncEngine(sessionFactory: { endpoint, _, _ -> any EndpointSession in
            if endpoint.kind.isRemote {
                return source
            }
            return destination
        })
        var job = partialFailureJob()
        job.filter.recentHours = 1
        job.targetCleanup = TargetCleanup(olderThanHours: 2)

        do {
            _ = try await engine.run(job: job, leftPassword: "secret", rightPassword: nil)
            XCTFail("The second cleanup deletion should fail")
        } catch let failure as SyncRunFailure {
            XCTAssertEqual(failure.failureDescription, "Injected cleanup failure for SECOND-OLD.JPG")
            XCTAssertEqual(failure.partialResult, SyncResult(transferred: 1, deleted: 1))
        }

        let storedPaths = await destination.storedPaths
        XCTAssertEqual(storedPaths, Set([sourceFile.relativePath, failedOldFile.relativePath]))
    }

    @MainActor
    func testAppStorePersistsAndDisplaysPartialTransferFailure() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("partial-result-store-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repository = JobRepository(fileURL: root.appendingPathComponent("jobs.json"))
        let baseDate = Date(timeIntervalSince1970: 1_800_000_000)
        let completed = SyncFile(
            relativePath: "FIRST.JPG",
            size: 5,
            modifiedAt: baseDate.addingTimeInterval(2)
        )
        let failed = SyncFile(
            relativePath: "SECOND.JPG",
            size: 6,
            modifiedAt: baseDate.addingTimeInterval(1)
        )
        let timeline = FastStartTimeline()
        let source = FastStartSource(
            files: [completed.relativePath: completed, failed.relativePath: failed],
            timeline: timeline
        )
        let destination = PartialFailureDestination(failedImportPath: failed.relativePath)
        let engine = SyncEngine(sessionFactory: { endpoint, _, _ -> any EndpointSession in
            if endpoint.kind.isRemote {
                return source
            }
            return destination
        })
        let job = partialFailureJob()
        try repository.save([job])
        let notificationDelivery = PartialFailureNotificationDeliverySpy()
        let store = AppStore(
            repository: repository,
            metadataPresetRepository: MetadataPresetRepository(fileURL: root.appendingPathComponent("presets.json")),
            photographerProfileRepository: PhotographerProfileRepository(fileURL: root.appendingPathComponent("photographers.json")),
            metadataAuditRepository: MetadataAuditRepository(fileURL: root.appendingPathComponent("audit.json")),
            syncFailureRepository: SyncFailureRepository(fileURL: root.appendingPathComponent("failures.json")),
            sourceSignatureRepository: SourceSignatureRepository(fileURL: root.appendingPathComponent("signatures.json")),
            engine: engine,
            failureNotificationCoordinator: SyncFailureNotificationCoordinator(
                delivery: notificationDelivery
            )
        )

        store.runNow(job.id)
        for _ in 0..<200 where store.isJobBusy(job.id) {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertFalse(store.isJobBusy(job.id))
        XCTAssertEqual(store.transferredFileCount(for: job.id), 1)
        guard case .failed(let message, _) = store.phases[job.id] else {
            return XCTFail("Expected a failed phase")
        }
        XCTAssertTrue(message.contains("Sync stopped after 1 file transferred"))
        XCTAssertEqual(store.syncFailureHistory(for: job.id).first?.message, message)
        XCTAssertEqual(notificationDelivery.notifications, [
            SyncFailureNotification(jobID: job.id, jobName: job.name)
        ])
    }

    func testRemoteSyncPublishesOnlyAfterFullListingValidation() async throws {
        let baseDate = Date(timeIntervalSince1970: 1_800_000_000)
        let files = Dictionary(uniqueKeysWithValues: (0..<8).map { index in
            let path = "NEWS_\(index).JPG"
            return (path, SyncFile(
                relativePath: path,
                size: Int64(index + 1),
                modifiedAt: baseDate.addingTimeInterval(Double(index))
            ))
        })
        let timeline = FastStartTimeline()
        let source = FastStartSource(files: files, timeline: timeline)
        let destination = FastStartDestination(timeline: timeline)
        let signatureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fast-start-signatures-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: signatureURL)
            try? FileManager.default.removeItem(at: signatureURL.appendingPathExtension("backup"))
        }
        let engine = SyncEngine(
            sourceSignatureRepository: SourceSignatureRepository(fileURL: signatureURL),
            sessionFactory: { endpoint, _, _ in
                if endpoint.kind.isRemote { return source }
                return destination
            }
        )
        var job = SyncJob()
        job.left = Endpoint(
            kind: .ftp,
            host: "photos.example.com",
            username: "reporter",
            remotePath: "/incoming"
        )
        job.right = Endpoint(
            kind: .local,
            localPath: "/mock-downloads",
            bookmark: Data("mock".utf8)
        )
        job.direction = .leftToRight
        job.filter = FileFilter(preset: .photos)
        job.isEnabled = false

        let result = try await engine.run(job: job, leftPassword: "secret", rightPassword: nil)
        let events = await timeline.events
        let importedPaths = await destination.importedPaths
        let importCount = await destination.importCount
        let firstFullListingIndex = try XCTUnwrap(events.firstIndex(of: "source-full-list"))
        let earlyImports = events[..<firstFullListingIndex].filter { $0.hasPrefix("import:") }

        XCTAssertTrue(earlyImports.isEmpty)
        XCTAssertEqual(result.transferred, 8)
        XCTAssertEqual(importedPaths, Set(files.keys))
        XCTAssertEqual(importCount, 8)

        let secondResult = try await engine.run(job: job, leftPassword: "secret", rightPassword: nil)
        let secondImportCount = await destination.importCount
        XCTAssertEqual(secondResult.transferred, 0)
        XCTAssertEqual(secondImportCount, 8)
    }

    func testSameStemRAWFilesAcrossFormerFastStartBoundaryPublishNothing() async throws {
        let baseDate = Date(timeIntervalSince1970: 1_800_000_000)
        var files = Dictionary(uniqueKeysWithValues: (0..<4).map { index in
            let path = "NEWS_\(index).JPG"
            return (path, SyncFile(
                relativePath: path,
                size: Int64(index + 1),
                modifiedAt: baseDate.addingTimeInterval(Double(20 - index))
            ))
        })
        files["SAME.CR2"] = SyncFile(
            relativePath: "SAME.CR2",
            size: 10,
            modifiedAt: baseDate.addingTimeInterval(10)
        )
        files["SAME.NEF"] = SyncFile(
            relativePath: "SAME.NEF",
            size: 11,
            modifiedAt: baseDate.addingTimeInterval(9)
        )
        files["SAME.xmp"] = SyncFile(
            relativePath: "SAME.xmp",
            size: 12,
            modifiedAt: baseDate.addingTimeInterval(8)
        )
        let timeline = FastStartTimeline()
        let source = FastStartSource(files: files, timeline: timeline)
        let destination = FastStartDestination(timeline: timeline)
        let signatureURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fast-start-collision-signatures-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: signatureURL) }
        let engine = SyncEngine(
            sourceSignatureRepository: SourceSignatureRepository(fileURL: signatureURL),
            sessionFactory: { endpoint, _, _ -> any EndpointSession in
                if endpoint.kind.isRemote { return source }
                return destination
            }
        )
        var job = SyncJob()
        job.left = Endpoint(
            kind: .ftp,
            host: "photos.example.com",
            username: "reporter",
            remotePath: "/incoming"
        )
        job.right = Endpoint(
            kind: .local,
            localPath: "/mock-downloads",
            bookmark: Data("mock".utf8)
        )
        job.direction = .leftToRight
        job.filter = FileFilter(preset: .photos)

        do {
            _ = try await engine.run(job: job, leftPassword: "secret", rightPassword: nil)
            XCTFail("Same-stem RAW files must be rejected before publication")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("would both write SAME.xmp"))
        }
        let importCount = await destination.importCount
        XCTAssertEqual(importCount, 0)
    }

    func testCompletedDirectoryPublishesBeforeFullScanAndCountsEachFileOnce() async throws {
        let baseDate = Date(timeIntervalSince1970: 1_800_000_000)
        let first = SyncFile(relativePath: "first/NEWS.JPG", size: 5, modifiedAt: baseDate)
        let second = SyncFile(relativePath: "later/MORE.JPG", size: 6, modifiedAt: baseDate.addingTimeInterval(-1))
        let timeline = FastStartTimeline()
        let source = IncrementalSource(
            snapshots: [directorySnapshot("first", files: [first]), directorySnapshot("later", files: [second])],
            finalFiles: [first.relativePath: first, second.relativePath: second],
            timeline: timeline
        )
        let destination = ConditionalDestination(timeline: timeline)
        let engine = SyncEngine(sessionFactory: { endpoint, _, _ -> any EndpointSession in
            endpoint.kind.isRemote ? source : destination
        })

        let result = try await engine.run(
            job: partialFailureJob(),
            leftPassword: "secret",
            rightPassword: nil
        )
        let events = await timeline.events
        let fullListingIndex = try XCTUnwrap(events.firstIndex(of: "source-full-list"))
        let firstImportIndex = try XCTUnwrap(events.firstIndex(of: "conditional-import:first/NEWS.JPG"))

        XCTAssertLessThan(firstImportIndex, fullListingIndex)
        XCTAssertEqual(result.transferred, 2)
        let importCount = await destination.importCount
        let storedFiles = await destination.storedFiles
        XCTAssertEqual(importCount, 2)
        XCTAssertEqual(storedFiles, [first.relativePath: first, second.relativePath: second])
    }

    func testCompletedDirectoryRejectsSameStemRAWOwnersBeforePublication() async throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let cr2 = SyncFile(relativePath: "desk/JAD_SAME.CR2", size: 5, modifiedAt: date)
        let nef = SyncFile(relativePath: "desk/JAD_SAME.NEF", size: 6, modifiedAt: date)
        let timeline = FastStartTimeline()
        let source = IncrementalSource(
            snapshots: [directorySnapshot("desk", files: [cr2, nef])],
            finalFiles: [
                cr2.relativePath: cr2,
                nef.relativePath: nef,
            ],
            timeline: timeline
        )
        let destination = ConditionalDestination(timeline: timeline)
        let engine = SyncEngine(sessionFactory: { endpoint, _, _ -> any EndpointSession in
            endpoint.kind.isRemote ? source : destination
        })
        let photographer = PhotographerProfile(
            name: "Jane Doe",
            filenamePrefix: "JAD",
            creator: "Jane Doe",
            copyrightNotice: "Example"
        )
        let clip = MetadataScheduleClip(
            photographerID: photographer.id,
            name: "Later",
            startsAt: date.addingTimeInterval(3_600),
            endsAt: date.addingTimeInterval(7_200)
        )
        var job = partialFailureJob()
        job.metadataAutomation = MetadataAutomation(
            isEnabled: true,
            photographers: [photographer],
            clips: [clip]
        )

        do {
            _ = try await engine.run(job: job, leftPassword: "secret", rightPassword: nil)
            XCTFail("Conflicting RAW owners must be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("would both write desk/JAD_SAME.xmp"))
        }
        let importCount = await destination.importCount
        XCTAssertEqual(importCount, 0)
    }

    func testRemoteTreeWalkerRejectsCaseAndUnicodeEquivalentSiblings() async throws {
        for names in [["News", "news"], ["Café", "Cafe\u{301}"]] {
            do {
                _ = try await RemoteTreeWalker.listFiles(
                    root: "/",
                    join: { root, child in root + child },
                    listDirectory: { _ in
                        names.map {
                            RemoteDirectoryEntry(
                                name: $0,
                                isDirectory: true,
                                size: 0,
                                modifiedAt: .distantPast,
                                hasAuthoritativeTimestamp: true
                            )
                        }
                    },
                    onCompletedDirectory: { _ in }
                )
                XCTFail("Equivalent siblings must be rejected")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("cannot safely coexist"))
            }
        }
    }

    func testRemoteTreeWalkerUsesStableBreadthFirstSnapshots() async throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let tree: [String: [RemoteDirectoryEntry]] = [
            "/": [
                RemoteDirectoryEntry(name: "z", isDirectory: true, size: 0, modifiedAt: date, hasAuthoritativeTimestamp: true),
                RemoteDirectoryEntry(name: "a", isDirectory: true, size: 0, modifiedAt: date, hasAuthoritativeTimestamp: true),
            ],
            "/a": [
                RemoteDirectoryEntry(name: "first.jpg", isDirectory: false, size: 1, modifiedAt: date, hasAuthoritativeTimestamp: true),
            ],
            "/z": [
                RemoteDirectoryEntry(name: "second.jpg", isDirectory: false, size: 2, modifiedAt: date, hasAuthoritativeTimestamp: true),
            ],
        ]
        let collector = SnapshotCollector()

        let files = try await RemoteTreeWalker.listFiles(
            root: "/",
            join: { root, child in root == "/" ? root + child : root + "/" + child },
            listDirectory: { tree[$0] ?? [] },
            onCompletedDirectory: { await collector.append($0) }
        )
        let snapshots = await collector.snapshots

        XCTAssertEqual(snapshots.map(\.relativeDirectory), ["", "a", "z"])
        XCTAssertEqual(snapshots[1].validatedAncestors, ["a"])
        XCTAssertEqual(Set(files.keys), ["a/first.jpg", "z/second.jpg"])
    }

    func testDestinationFileAppearingAtConditionalCommitIsNotOverwritten() async throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let incoming = SyncFile(relativePath: "NEWS.JPG", size: 5, modifiedAt: date)
        let competing = SyncFile(relativePath: incoming.relativePath, size: 99, modifiedAt: date)
        let timeline = FastStartTimeline()
        let source = IncrementalSource(
            snapshots: [directorySnapshot("", files: [incoming])],
            finalFiles: [incoming.relativePath: incoming],
            timeline: timeline
        )
        let destination = ConditionalDestination(
            timeline: timeline,
            competingFileAtConditionalCommit: competing
        )
        let engine = SyncEngine(sessionFactory: { endpoint, _, _ -> any EndpointSession in
            endpoint.kind.isRemote ? source : destination
        })

        do {
            _ = try await engine.run(job: partialFailureJob(), leftPassword: "secret", rightPassword: nil)
            XCTFail("The conditional commit must fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("appeared before publication"))
        }
        let storedFiles = await destination.storedFiles
        XCTAssertEqual(storedFiles, [competing.relativePath: competing])
    }

    func testExistingCaseEquivalentDestinationCollisionIsNotOverwritten() async throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let incoming = SyncFile(relativePath: "NEWS.JPG", size: 5, modifiedAt: date)
        let existing = SyncFile(relativePath: "news.jpg", size: 99, modifiedAt: date)
        let timeline = FastStartTimeline()
        let source = IncrementalSource(
            snapshots: [directorySnapshot("", files: [incoming])],
            finalFiles: [incoming.relativePath: incoming],
            timeline: timeline
        )
        let destination = ConditionalDestination(
            timeline: timeline,
            initialFiles: [existing.relativePath: existing]
        )
        let engine = SyncEngine(sessionFactory: { endpoint, _, _ -> any EndpointSession in
            endpoint.kind.isRemote ? source : destination
        })

        do {
            _ = try await engine.run(job: partialFailureJob(), leftPassword: "secret", rightPassword: nil)
            XCTFail("The case-equivalent collision must fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("cannot safely coexist"))
        }
        let storedFiles = await destination.storedFiles
        XCTAssertEqual(storedFiles, [existing.relativePath: existing])
    }

    func testEarlyCompanionFailureRollsBackPrimary() async throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let primary = SyncFile(relativePath: "NEWS.CR3", size: 5, modifiedAt: date)
        let sidecar = SyncFile(relativePath: "NEWS.xmp", size: 6, modifiedAt: date)
        let timeline = FastStartTimeline()
        let source = IncrementalSource(
            snapshots: [directorySnapshot("", files: [primary, sidecar])],
            finalFiles: [primary.relativePath: primary, sidecar.relativePath: sidecar],
            timeline: timeline
        )
        let destination = ConditionalDestination(
            timeline: timeline,
            failedConditionalPath: sidecar.relativePath
        )
        let engine = SyncEngine(sessionFactory: { endpoint, _, _ -> any EndpointSession in
            endpoint.kind.isRemote ? source : destination
        })

        do {
            _ = try await engine.run(job: partialFailureJob(), leftPassword: "secret", rightPassword: nil)
            XCTFail("The companion commit must fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Injected conditional failure"))
        }
        let storedFiles = await destination.storedFiles
        XCTAssertEqual(storedFiles, [:])
    }

    func testChangedSignatureAfterEarlyPublicationReplacesFinalVersionWithoutDoubleCount() async throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let early = SyncFile(relativePath: "NEWS.JPG", size: 5, modifiedAt: date)
        let final = SyncFile(relativePath: "NEWS.JPG", size: 8, modifiedAt: date.addingTimeInterval(5))
        let timeline = FastStartTimeline()
        let source = IncrementalSource(
            snapshots: [directorySnapshot("", files: [early])],
            finalFiles: [final.relativePath: final],
            timeline: timeline
        )
        let destination = ConditionalDestination(timeline: timeline)
        let engine = SyncEngine(sessionFactory: { endpoint, _, _ -> any EndpointSession in
            endpoint.kind.isRemote ? source : destination
        })

        let result = try await engine.run(
            job: partialFailureJob(),
            leftPassword: "secret",
            rightPassword: nil
        )

        XCTAssertEqual(result.transferred, 1)
        let importCount = await destination.importCount
        let storedFiles = await destination.storedFiles
        XCTAssertEqual(importCount, 2)
        XCTAssertEqual(storedFiles, [final.relativePath: final])
    }

    func testNonAuthoritativeFTPTimestampDefersRecentFileUntilFullScan() async throws {
        let file = SyncFile(relativePath: "NEWS.JPG", size: 5, modifiedAt: Date())
        let timeline = FastStartTimeline()
        let source = IncrementalSource(
            snapshots: [directorySnapshot("", files: [file], authoritativeTimestamp: false)],
            finalFiles: [file.relativePath: file],
            timeline: timeline
        )
        let destination = ConditionalDestination(timeline: timeline)
        let engine = SyncEngine(sessionFactory: { endpoint, _, _ -> any EndpointSession in
            endpoint.kind.isRemote ? source : destination
        })
        var job = partialFailureJob()
        job.filter.recentHours = 1

        _ = try await engine.run(job: job, leftPassword: "secret", rightPassword: nil)
        let events = await timeline.events
        let fullListingIndex = try XCTUnwrap(events.firstIndex(of: "source-full-list"))
        let importIndex = try XCTUnwrap(events.firstIndex(of: "import:NEWS.JPG"))
        XCTAssertGreaterThan(importIndex, fullListingIndex)
    }

    func testFullListingFailureReportsCompletedEarlyTransfer() async throws {
        let file = SyncFile(
            relativePath: "NEWS.JPG",
            size: 5,
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let timeline = FastStartTimeline()
        let source = IncrementalSource(
            snapshots: [directorySnapshot("", files: [file])],
            finalFiles: [file.relativePath: file],
            timeline: timeline,
            failsAfterSnapshots: true
        )
        let destination = ConditionalDestination(timeline: timeline)
        let engine = SyncEngine(sessionFactory: { endpoint, _, _ -> any EndpointSession in
            endpoint.kind.isRemote ? source : destination
        })

        do {
            _ = try await engine.run(job: partialFailureJob(), leftPassword: "secret", rightPassword: nil)
            XCTFail("The full listing must fail")
        } catch let failure as SyncRunFailure {
            XCTAssertEqual(failure.partialResult.transferred, 1)
        }
        let storedFiles = await destination.storedFiles
        XCTAssertEqual(storedFiles, [file.relativePath: file])
    }

    func testCancellationAfterEarlyPublicationRemainsCancellation() async throws {
        let file = SyncFile(
            relativePath: "NEWS.JPG",
            size: 5,
            modifiedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let timeline = FastStartTimeline()
        let source = IncrementalSource(
            snapshots: [directorySnapshot("", files: [file])],
            finalFiles: [file.relativePath: file],
            timeline: timeline,
            waitsAfterSnapshots: true
        )
        let destination = ConditionalDestination(timeline: timeline)
        let engine = SyncEngine(sessionFactory: { endpoint, _, _ -> any EndpointSession in
            endpoint.kind.isRemote ? source : destination
        })
        let job = partialFailureJob()
        let task = Task {
            try await engine.run(
                job: job,
                leftPassword: "secret",
                rightPassword: nil
            )
        }

        for _ in 0..<200 {
            if await destination.importCount == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("The run must remain cancelled")
        } catch is CancellationError {
            // Expected.
        }
        let storedFiles = await destination.storedFiles
        XCTAssertEqual(storedFiles, [file.relativePath: file])
    }

    func testParsesMachineReadableListing() throws {
        let listing = """
        modify=20260821122345;size=43121;type=file; NEWS_001.JPG\r
        modify=20260821122350;size=98122;type=file; NEWS 002.CR3\r
        modify=20260821122000;type=dir; selects\r
        type=cdir; .\r
        """
        let entries = FTPEndpointSession.parseMLSD(listing)
        XCTAssertEqual(entries.map(\.name), ["NEWS_001.JPG", "NEWS 002.CR3", "selects"])
        XCTAssertEqual(entries[0].size, 43_121)
        XCTAssertTrue(entries[2].isDirectory)
    }

    func testParsesMDTMModificationDateAsUTC() throws {
        let date = try XCTUnwrap(FTPConnection.parseModificationDate("213 20260830080942.125"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))

        XCTAssertEqual(calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date),
                       DateComponents(year: 2026, month: 8, day: 30, hour: 8, minute: 9, second: 42))
    }

    func testNoDataNetworkErrorIsTreatedAsEndOfStream() {
        XCTAssertTrue(NetworkStream.isEndOfStream(.posix(.ENODATA)))
        XCTAssertFalse(NetworkStream.isEndOfStream(.posix(.ECONNRESET)))
    }

    func testNetworkStreamRejectsPortsOutsideTransportRange() {
        XCTAssertThrowsError(try NetworkStream(host: "localhost", port: -1, tls: false))
        XCTAssertThrowsError(try NetworkStream(host: "localhost", port: 0, tls: false))
        XCTAssertThrowsError(try NetworkStream(host: "localhost", port: 65_536, tls: false))
    }

    func testParsesOnlyValidExtendedPassivePorts() {
        XCTAssertEqual(FTPConnection.parseExtendedPassivePort("229 Entering Extended Passive Mode (|||6446|)"), 6_446)
        XCTAssertEqual(FTPConnection.parseExtendedPassivePort("229 Entering Extended Passive Mode (!!!2121!)"), 2_121)
        XCTAssertNil(FTPConnection.parseExtendedPassivePort("229 Entering Extended Passive Mode (|||0|)"))
        XCTAssertNil(FTPConnection.parseExtendedPassivePort("229 Entering Extended Passive Mode (|||65536|)"))
        XCTAssertNil(FTPConnection.parseExtendedPassivePort("229 Entering Extended Passive Mode (|||invalid|)"))
        XCTAssertNil(FTPConnection.parseExtendedPassivePort("229 Entering Extended Passive Mode (|||2121|trailing)"))
    }

    func testParsesOnlyValidPassivePortsAndOctets() {
        XCTAssertEqual(FTPConnection.parsePassivePort("227 Entering Passive Mode (127,0,0,1,25,46)"), 6_446)
        XCTAssertNil(FTPConnection.parsePassivePort("227 Entering Passive Mode (127,0,0,1,0,0)"))
        XCTAssertNil(FTPConnection.parsePassivePort("227 Entering Passive Mode (127,0,0,1,256,1)"))
        XCTAssertNil(FTPConnection.parsePassivePort("227 Entering Passive Mode (-1,0,0,1,25,46)"))
    }

    func testTransferSizeLimitRejectsDataBeyondAdvertisedSize() throws {
        var limit = try TransferSizeLimit(maximumBytes: 5)
        try limit.record(3)
        try limit.record(2)

        XCTAssertEqual(limit.receivedBytes, 5)
        XCTAssertThrowsError(try limit.record(1))
        XCTAssertThrowsError(try TransferSizeLimit(maximumBytes: -1))
    }

    func testRemoteFileSizeRejectsValuesAboveInt64Range() throws {
        XCTAssertEqual(
            try RemoteFileSize.checked(UInt64(Int64.max), protocolName: "SFTP", path: "valid.jpg"),
            Int64.max
        )
        XCTAssertThrowsError(
            try RemoteFileSize.checked(UInt64(Int64.max) + 1, protocolName: "SFTP", path: "invalid.jpg")
        )
    }

    func testFTPReplyRedactionRemovesCredentials() {
        XCTAssertEqual(
            FTPConnection.redactingSecrets(
                in: "530 Password hunter2 was rejected; hunter2 is invalid",
                secrets: ["hunter2", ""]
            ),
            "530 Password <redacted> was rejected; <redacted> is invalid"
        )
    }

    func testDirectoryListingAccumulatorEnforcesMaximumSize() throws {
        var accumulator = BoundedDataAccumulator(maximumBytes: 5)
        try accumulator.append(Data("123".utf8), context: "test listing")
        try accumulator.append(Data("45".utf8), context: "test listing")

        XCTAssertEqual(String(decoding: accumulator.data, as: UTF8.self), "12345")
        XCTAssertThrowsError(try accumulator.append(Data("6".utf8), context: "test listing"))
    }

    func testFTPLineBufferRejectsOverlongLineWithoutDelimiter() {
        var buffer = FTPLineBuffer()
        buffer.append(Data("123456".utf8))

        XCTAssertThrowsError(try buffer.nextLine(maximumBytes: 5))
    }

    func testFTPLineBufferRejectsOverlongCompletedLine() {
        var buffer = FTPLineBuffer()
        buffer.append(Data("123456\r\n".utf8))

        XCTAssertThrowsError(try buffer.nextLine(maximumBytes: 5))
    }

    func testFTPLineBufferPreservesFollowingReply() throws {
        var buffer = FTPLineBuffer()
        buffer.append(Data("220 hello\r\n221 bye\r\n".utf8))

        XCTAssertEqual(try buffer.nextLine(maximumBytes: 64), "220 hello")
        XCTAssertEqual(try buffer.nextLine(maximumBytes: 64), "221 bye")
        XCTAssertNil(try buffer.nextLine(maximumBytes: 64))
    }

    private func partialFailureJob() -> SyncJob {
        var job = SyncJob()
        job.left = Endpoint(
            kind: .ftp,
            host: "photos.example.com",
            username: "reporter",
            remotePath: "/incoming"
        )
        job.right = Endpoint(
            kind: .local,
            localPath: "/mock-downloads",
            bookmark: Data("mock".utf8)
        )
        job.direction = .leftToRight
        job.filter = FileFilter(preset: .photos)
        job.isEnabled = false
        job.startsOnAppLaunch = false
        return job
    }

    private func directorySnapshot(
        _ directory: String,
        files: [SyncFile],
        authoritativeTimestamp: Bool = true
    ) -> CompletedDirectoryListing {
        CompletedDirectoryListing(
            relativeDirectory: directory,
            entries: files.map {
                RemoteTreeEntry(
                    relativePath: $0.relativePath,
                    file: $0,
                    hasAuthoritativeTimestamp: authoritativeTimestamp
                )
            },
            validatedAncestors: directory.isEmpty ? [] : [directory]
        )
    }
}

@MainActor
private final class PartialFailureNotificationDeliverySpy: SyncFailureNotificationDelivering {
    private(set) var notifications: [SyncFailureNotification] = []

    func deliver(_ notification: SyncFailureNotification) {
        notifications.append(notification)
    }
}

private actor FastStartTimeline {
    private(set) var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }
}

private actor SnapshotCollector {
    private(set) var snapshots: [CompletedDirectoryListing] = []

    func append(_ snapshot: CompletedDirectoryListing) {
        snapshots.append(snapshot)
    }
}

private actor FastStartSource: EndpointSession {
    let files: [String: SyncFile]
    let timeline: FastStartTimeline

    init(files: [String: SyncFile], timeline: FastStartTimeline) {
        self.files = files
        self.timeline = timeline
    }

    func listFiles() async throws -> [String: SyncFile] {
        await timeline.append("source-full-list")
        return files
    }

    func exportFile(_ file: SyncFile, to temporaryURL: URL) async throws {
        await timeline.append("export:\(file.relativePath)")
        try Data(repeating: UInt8(file.size), count: Int(file.size)).write(to: temporaryURL)
    }

    func importFile(
        from localURL: URL,
        as file: SyncFile,
        preserveDate: Bool,
        verifySize: Bool
    ) async throws {}
}

private actor IncrementalSource: EndpointSession {
    let snapshots: [CompletedDirectoryListing]
    let finalFiles: [String: SyncFile]
    let timeline: FastStartTimeline
    let failsAfterSnapshots: Bool
    let waitsAfterSnapshots: Bool

    init(
        snapshots: [CompletedDirectoryListing],
        finalFiles: [String: SyncFile],
        timeline: FastStartTimeline,
        failsAfterSnapshots: Bool = false,
        waitsAfterSnapshots: Bool = false
    ) {
        self.snapshots = snapshots
        self.finalFiles = finalFiles
        self.timeline = timeline
        self.failsAfterSnapshots = failsAfterSnapshots
        self.waitsAfterSnapshots = waitsAfterSnapshots
    }

    nonisolated var supportsCompletedDirectoryListings: Bool { true }

    func listFiles() async throws -> [String: SyncFile] { finalFiles }

    func listFilesIncrementally(
        onCompletedDirectory: @escaping @Sendable (CompletedDirectoryListing) async throws -> Void
    ) async throws -> [String: SyncFile] {
        for snapshot in snapshots {
            await timeline.append("snapshot:\(snapshot.relativeDirectory)")
            try await onCompletedDirectory(snapshot)
        }
        if waitsAfterSnapshots {
            try await Task.sleep(for: .seconds(10))
        }
        await timeline.append("source-full-list")
        if failsAfterSnapshots {
            throw AppError.transferFailed("Injected full-list failure")
        }
        return finalFiles
    }

    func exportFile(_ file: SyncFile, to temporaryURL: URL) async throws {
        await timeline.append("export:\(file.relativePath)")
        try Data(repeating: UInt8(clamping: file.size), count: Int(file.size)).write(to: temporaryURL)
    }

    func importFile(
        from localURL: URL,
        as file: SyncFile,
        preserveDate: Bool,
        verifySize: Bool
    ) async throws {}
}

private actor ConditionalDestination: EndpointSession {
    private(set) var storedFiles: [String: SyncFile]
    private(set) var importCount = 0
    let timeline: FastStartTimeline
    let failedConditionalPath: String?
    let competingFileAtConditionalCommit: SyncFile?

    init(
        timeline: FastStartTimeline,
        initialFiles: [String: SyncFile] = [:],
        failedConditionalPath: String? = nil,
        competingFileAtConditionalCommit: SyncFile? = nil
    ) {
        self.timeline = timeline
        storedFiles = initialFiles
        self.failedConditionalPath = failedConditionalPath
        self.competingFileAtConditionalCommit = competingFileAtConditionalCommit
    }

    func listFiles() async throws -> [String: SyncFile] {
        await timeline.append("destination-full-list")
        return storedFiles
    }

    func exportFile(_ file: SyncFile, to temporaryURL: URL) async throws {
        try Data(repeating: UInt8(clamping: file.size), count: Int(file.size)).write(to: temporaryURL)
    }

    func importFile(
        from localURL: URL,
        as file: SyncFile,
        preserveDate: Bool,
        verifySize: Bool
    ) async throws {
        storedFiles[file.relativePath] = file
        importCount += 1
        await timeline.append("import:\(file.relativePath)")
    }

    func importFilesTransactionallyIfAbsent(
        _ imports: [EndpointFileImport],
        preserveDate: Bool,
        verifySize: Bool
    ) async throws {
        var published: [String] = []
        do {
            for item in imports {
                if let competingFileAtConditionalCommit,
                   competingFileAtConditionalCommit.relativePath == item.file.relativePath {
                    storedFiles[item.file.relativePath] = competingFileAtConditionalCommit
                    throw AppError.transferFailed(
                        "A file appeared before publication at \(item.file.relativePath)."
                    )
                }
                if item.file.relativePath == failedConditionalPath {
                    throw AppError.transferFailed(
                        "Injected conditional failure for \(item.file.relativePath)"
                    )
                }
                guard storedFiles[item.file.relativePath] == nil else {
                    throw AppError.transferFailed(
                        "A file appeared before publication at \(item.file.relativePath)."
                    )
                }
                storedFiles[item.file.relativePath] = item.file
                published.append(item.file.relativePath)
                importCount += 1
                await timeline.append("conditional-import:\(item.file.relativePath)")
            }
        } catch {
            for path in published.reversed() { storedFiles[path] = nil }
            throw error
        }
    }

    func removeFile(_ file: SyncFile) async throws {
        storedFiles[file.relativePath] = nil
    }
}

private actor FastStartDestination: EndpointFileLookupSession {
    private var files: [String: SyncFile] = [:]
    private(set) var importCount = 0
    let timeline: FastStartTimeline

    init(timeline: FastStartTimeline) {
        self.timeline = timeline
    }

    var importedPaths: Set<String> { Set(files.keys) }

    func fileInfo(relativePath: String) async throws -> SyncFile? {
        files[relativePath]
    }

    func listFiles() async throws -> [String: SyncFile] {
        await timeline.append("destination-full-list")
        return files
    }

    func exportFile(_ file: SyncFile, to temporaryURL: URL) async throws {
        try Data(repeating: UInt8(file.size), count: Int(file.size)).write(to: temporaryURL)
    }

    func importFile(
        from localURL: URL,
        as file: SyncFile,
        preserveDate: Bool,
        verifySize: Bool
    ) async throws {
        files[file.relativePath] = file
        importCount += 1
        await timeline.append("import:\(file.relativePath)")
    }
}

private actor PartialFailureDestination: EndpointSession {
    private var files: [String: SyncFile]
    private let failedImportPath: String?
    private let failedDeletePath: String?
    private let blockedImportPath: String?
    private let failsRollback: Bool
    private(set) var exportedBackups: [String: URL] = [:]

    init(
        files: [String: SyncFile] = [:],
        failedImportPath: String? = nil,
        failedDeletePath: String? = nil,
        blockedImportPath: String? = nil,
        failsRollback: Bool = false
    ) {
        self.failsRollback = failsRollback
        self.files = files
        self.failedImportPath = failedImportPath
        self.failedDeletePath = failedDeletePath
        self.blockedImportPath = blockedImportPath
    }

    var storedPaths: Set<String> { Set(files.keys) }
    var storedFiles: [String: SyncFile] { files }

    func listFiles() async throws -> [String: SyncFile] { files }

    func exportFile(_ file: SyncFile, to temporaryURL: URL) async throws {
        exportedBackups[file.relativePath] = temporaryURL
        try Data(repeating: UInt8(file.size), count: Int(file.size)).write(to: temporaryURL)
    }

    func importFile(
        from localURL: URL,
        as file: SyncFile,
        preserveDate: Bool,
        verifySize: Bool
    ) async throws {
        if failsRollback, localURL.pathExtension == "rollback" {
            throw AppError.transferFailed("Injected rollback failure")
        }
        if file.relativePath == failedImportPath {
            throw AppError.transferFailed("Injected import failure for \(file.relativePath)")
        }
        if file.relativePath == blockedImportPath {
            try await Task.sleep(for: .seconds(10))
        }
        files[file.relativePath] = file
    }

    func deleteFile(_ file: SyncFile, ifOlderThan cutoff: Date) async throws -> Bool {
        if file.relativePath == failedDeletePath {
            throw AppError.transferFailed("Injected cleanup failure for \(file.relativePath)")
        }
        guard let current = files[file.relativePath], current.modifiedAt < cutoff else { return false }
        files[file.relativePath] = nil
        return true
    }

    func removeFile(_ file: SyncFile) async throws {
        files[file.relativePath] = nil
    }
}
