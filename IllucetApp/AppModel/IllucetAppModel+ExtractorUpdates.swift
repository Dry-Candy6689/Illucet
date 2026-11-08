import Foundation

@MainActor
extension IllucetAppModel {
    var extractorUpdateBusy: Bool {
        [.checking, .installing, .testing].contains(updateStatus.state)
    }

    func refreshExtractorStatus() async {
        guard !extractorUpdateBusy else { return }
        let previous = updateStatus
        do {
            let refreshed: UpdateStatus
            if try await runtime.hasInstalledPackages() {
                refreshed = try await updateService.refreshed(previous, runtime: runtime)
            } else {
                var bundled = previous.reconciledWithBundledRuntime
                bundled.activeCertifiVersion = DependencyVersions.certifi
                bundled.previousYTDLPVersion = try? await updateService.previousVersion()
                refreshed = bundled
            }
            guard updateStatus == previous else { return }
            updateStatus = refreshed
            snapshot.updateStatus = refreshed
        } catch {
            guard updateStatus == previous else { return }
            updateStatus.state = .failed
            updateStatus.message = "The extractor couldn’t start. Close and reopen Illucet to try again."
        }
    }

    func selectExtractorUpdateChannel(_ channel: UpdateChannel) {
        guard !extractorUpdateBusy, updateStatus.state != .staged, channel != settings.updateChannel else { return }
        settings.updateChannel = channel
        updateStatus.invalidateCheck()
        scheduleSave()
    }

    func checkForUpdates(automatically: Bool = false) {
        guard !extractorUpdateBusy, updateStatus.state != .staged else { return }
        extractorUpdateCheckIsAutomatic = automatically
        let channel = settings.updateChannel
        let currentStatus = updateStatus
        let checkID = UUID()
        extractorUpdateCheckTask?.cancel()
        extractorUpdateCheckID = checkID
        updateStatus.state = .checking
        updateStatus.message = nil
        updateStatus.availableRelease = nil
        extractorUpdateCheckTask = Task { [weak self, updateService] in
            let result = await updateService.check(current: currentStatus, channel: channel)
            guard let self, extractorUpdateCheckID == checkID else { return }
            extractorUpdateCheckTask = nil
            extractorUpdateCheckID = nil
            extractorUpdateCheckIsAutomatic = false
            guard updateStatus.state == .checking else { return }
            if settings.updateChannel == channel {
                updateStatus = result
                if settings.notifyUpdates, result.state == .updateAvailable,
                   let version = result.availableRelease?.version {
                    await notifications.notifyUpdate(version: version)
                }
            } else {
                updateStatus.invalidateCheck()
            }
            scheduleSave()
        }
    }

    func checkForUpdatesIfDue(now: Date = .now) {
        // Tests exercise the policy with injected dates and HTTP fixtures. Never
        // turn app-host launch into an incidental live integration test.
        let testHost = ProcessInfo.processInfo.environment.keys.contains { $0.hasPrefix("XCTest") }
            || Bundle.allBundles.contains { $0.bundlePath.hasSuffix(".xctest") }
        guard !fixtureMode, !testHost, !startupState.blocksInteraction,
              !extractorUpdateBusy,
              AutomaticExtractorUpdatePolicy.isDue(enabled: settings.automaticUpdateChecks,
                status: updateStatus, channel: settings.updateChannel, now: now) else { return }
        checkForUpdates(automatically: true)
    }

    func automaticUpdatePreferenceChanged() {
        if !settings.automaticUpdateChecks && extractorUpdateCheckIsAutomatic {
            extractorUpdateCheckTask?.cancel()
            extractorUpdateCheckTask = nil
            extractorUpdateCheckID = nil
            extractorUpdateCheckIsAutomatic = false
            if updateStatus.state == .checking { updateStatus.invalidateCheck() }
        }
        checkForUpdatesIfDue()
    }

    func restorePreviousExtractor() {
        guard !extractorUpdateBusy, updateStatus.state != .staged,
              updateStatus.previousYTDLPVersion != nil else { return }
        let current = updateStatus
        updateStatus.state = .installing
        updateStatus.message = "Preparing the previous version…"
        Task {
            do { updateStatus = try await updateService.restorePrevious(current, runtime: runtime) }
            catch {
                updateStatus = current
                updateStatus.availableRelease = nil
                updateStatus.state = .failed
                updateStatus.message = "Couldn’t restore the previous version. Try again."
            }
            scheduleSave()
        }
    }

    func installUpdate(_ offer: ExtractorRelease, confirmedOlderVersion: Bool = false) {
        guard !extractorUpdateBusy, updateStatus.state == .updateAvailable,
              updateStatus.availableRelease == offer, offer.channel == settings.updateChannel,
              !offer.isOlder(than: updateStatus) || confirmedOlderVersion else { return }
        let current = updateStatus
        let channel = settings.updateChannel
        updateStatus.state = .installing
        updateStatus.message = "Downloading and verifying extractor packages…"
        Task {
            do {
                updateStatus = try await updateService.install(current: current, channel: channel,
                    confirmedOlderVersion: confirmedOlderVersion, runtime: runtime)
            } catch {
                updateStatus = current
                updateStatus.availableRelease = nil
                updateStatus.state = .failed
                updateStatus.message = (error as? UpdateError)?.errorDescription
                    ?? "Couldn’t install this release. Check for updates and try again."
            }
            scheduleSave()
        }
    }

    func resetExtractor() {
        guard !extractorUpdateBusy else { return }
        let current = updateStatus
        updateStatus.state = .installing
        updateStatus.message = "Preparing the bundled version…"
        Task {
            do {
                updateStatus = try await updateService.resetToBundled(current, runtime: runtime)
            } catch {
                updateStatus = current
                updateStatus.message = "Couldn’t restore the bundled version. Try again."
                if current.state != .staged {
                    updateStatus.availableRelease = nil
                    updateStatus.state = .failed
                }
            }
            scheduleSave()
        }
    }

}
