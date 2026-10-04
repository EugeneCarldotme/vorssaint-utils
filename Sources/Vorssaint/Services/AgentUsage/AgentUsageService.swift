// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Combine
import Foundation

/// Reads Claude Code and Codex usage from their local session logs, and
/// OpenCode usage from its database, while the AI section is on, along with
/// the plan limits the Claude app saves. The files are read where they are,
/// incrementally, and nothing is copied or sent: only counters are kept, in
/// memory and in the app's private folder so the next launch reads only what
/// the agents wrote meanwhile. OpenCode's stay in memory only, and its
/// database is read again at each launch. It fetches the public price list
/// when the person keeps prices up to date, and asks the CLIProxyAPI hubs the
/// person added for the limits of the accounts they pool. Hub readings stay
/// in memory only.
///
/// Reading happens on a private queue; the main thread and that queue hand
/// work to each other asynchronously, except that a stop waits for progress
/// to be saved. The queue never waits for the main thread.
final class AgentUsageService: ObservableObject {
    static let shared = AgentUsageService()

    @Published private(set) var snapshot = AgentUsageSnapshot()
    /// When the Claude app last saved the plan's limits; nil when it never has.
    @Published private(set) var claudeAppChecked: Date?
    /// The day of the price list in use.
    @Published private(set) var pricesUpdated: Date?
    /// The CLIProxyAPI hubs the person added, in the order they added them.
    @Published private(set) var hubs: [AgentHub] = AgentHubStore.load()
    /// How each hub answered last. Nil until Vorssaint first asks it.
    @Published private(set) var hubStates: [String: AgentHubState] = [:]
    let events = PassthroughSubject<AgentUsageEvent, Never>()

    /// The history the island can show: thirteen weeks for the activity map.
    static let horizon = TimeInterval(AgentUsageSnapshot.dayCount) * 86_400
    private static let tick: TimeInterval = 30
    /// File events report a written file only once it closes, and some
    /// agents keep their log open for the whole session: logs written in the
    /// last half hour, or holding a turn, are checked this often instead.
    private static let poll: TimeInterval = 2
    private static let pollWindow: TimeInterval = 30 * 60
    /// Coalesce a live log's bursts into one history and display update.
    private static let publishDelay: TimeInterval = 1
    /// How often Vorssaint asks each hub. The island keeps the last answer
    /// in between.
    static let hubInterval: TimeInterval = 5 * 60
    /// How often progress is saved while agents write, besides on quit and
    /// pause; a launch after a crash reads again only what came after.
    private static let saveInterval: TimeInterval = 5 * 60

    private let queue = DispatchQueue(label: "com.vorssaint.agent-usage", qos: .utility, autoreleaseFrequency: .workItem)
    private let home = FileManager.default.homeDirectoryForCurrentUser

    /// Lets a stop end a first read that is still going on the queue.
    private final class Cancellation {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }

    // Main thread.
    private var running = false
    /// Reading waits while the island is away; what was read stays.
    private var paused = false
    private var session = 0
    private var cancellation = Cancellation()
    private var timer: Timer?
    /// The agents whose logs are read.
    private var providers: [AgentProvider] = []
    /// The agents whose own sign-in the page shows, by their switches.
    private var shownProviders: [AgentProvider] = []
    private var pricesInFlight = false
    private var pricesAttempted = Date.distantPast
    private var pricesFailed = false
    /// When the list on disk was downloaded; nil until the queue has looked.
    private var pricesSaved: Date?
    private var hubAsked: [String: Date] = [:]
    /// The reading in flight for each hub. Removing a hub, replacing its key
    /// or stopping cancels it, so no request goes out with an old key. The
    /// token tells a cancelled reading's late answer from a newer one.
    private var hubTasks: [String: (token: UUID, task: Task<Void, Never>)] = [:]
    /// Hubs not to ask again before a time. A wrong key waits for a new one,
    /// since every attempt counts toward the hub's ban. This outlives a
    /// stop for the same reason.
    private var hubHolds: [String: Date] = [:]

    // Confined to `queue`.
    private var readerSession = -1
    private var readerCancellation: Cancellation?
    private var enabled: Set<AgentProvider> = []
    /// The agents whose own plan and limits count, a subset of `enabled`.
    private var shown: Set<AgentProvider> = []
    private var store = AgentUsageStore()
    private var cursors: [String: AgentLogCursor] = [:]
    private var watcher: AgentLogWatcher?
    private var watchedRoots: [AgentLogRoot] = []
    private var poller: DispatchSourceTimer?
    private var publishScheduled = false
    /// The last snapshot handed over, to tell when time alone changes it.
    private var published = AgentUsageSnapshot()
    private var claudePlan: AgentPlan?
    /// The organization Claude Code signs in to, when its profile says.
    private var claudeOrganization: String?
    private var claudeProfileModified: Date?
    private var claudeAppModified: Date?
    private var claudeAppSamples: [AgentClaudeAppUsage.Sample] = []
    private var shippedPrices: AgentPriceList?
    /// Each account's last limits, and the warned windows waiting to renew.
    private var alerts = AgentLimitAlerts()
    /// The email Claude Code signs in with, to spot the same account in a hub.
    private var claudeEmail: String?
    /// Every hub's accounts as last read, in the order of `hubOrder`.
    private var hubAccounts: [String: [AgentHubAccount]] = [:]
    private var hubOrder: [String] = []
    /// The Codex model providers that point at a hub, from Codex's config,
    /// each with the hub it reaches.
    private var hubRoutes: [String: String] = [:]
    private var budgetDay: Date?
    private var lastRootCheck = Date.distantPast
    /// Tells whether reading moved on since progress was last saved.
    /// Nil until this reading saved or resumed progress: the first save
    /// always replaces what is on disk, which may hold agents now off.
    private var savedMark: Int?
    private var lastSave = Date.distantPast

    private init() {}

    func syncWithPreferences() {
        guard NotchAgentSupport.isEnabled() else { stop(); return }
        let switched = NotchAgentSupport.providers()
        let wanted = NotchAgentSupport.readProviders(switched: switched, hasHubs: !hubs.isEmpty)
        // The service drops an agent it no longer reads and reads a new one
        // from its start, so either change takes a fresh reading. That would
        // not resume progress saved for the old set, so the saved file goes
        // at once.
        if running, wanted != providers { stop(keepingProgress: false) }
        if !running {
            running = true
            session += 1
            cancellation = Cancellation()
            providers = wanted
            shownProviders = switched
            start(session: session, providers: Set(wanted), shown: Set(switched), cancellation: cancellation)
        } else {
            if switched != shownProviders {
                // With a hub added, a switch only shows or hides the agent's
                // own sign-in. The logs stay read.
                shownProviders = switched
                let session = self.session
                queue.async { [self] in
                    guard readerSession == session else { return }
                    shown = Set(switched)
                    readClaudePlan()
                    readClaudeApp(now: Date())
                    checkLimits()
                    publish()
                }
            }
            if paused { resume() }
        }
        syncPrices()
        askHubs()
    }

    /// Stops reading while the island is away, as with the display asleep or
    /// the Mac locked, and keeps what was read: reading every log again on the
    /// way back costs far more than the pause saves.
    func pause() {
        guard running, !paused else { return }
        paused = true
        timer?.invalidate()
        timer = nil
        queue.async { [self] in
            poller?.cancel()
            poller = nil
            watcher?.stop()
            saveProgress()
        }
    }

    /// Reads what the agents wrote meanwhile, from where each log stopped.
    private func resume() {
        paused = false
        startTimer()
        queue.async { [self] in
            guard readerSession >= 0 else { return }
            watch(AgentLogRoot.all(home: home).filter { enabled.contains($0.provider) })
            filesChanged([], rescan: true)
            startPolling()
            // Time went by meanwhile: a window or the day may have moved on.
            schedulePublish()
        }
        askHubs()
    }

    func stop(keepingProgress keeps: Bool = true) {
        // A first read still going stops at its next chunk, so the wait
        // below is short.
        if running { cancellation.cancel() }
        settleArchive(keeping: keeps && NotchAgentSupport.isEnabled())
        guard running else { return }
        running = false
        paused = false
        session += 1
        timer?.invalidate()
        timer = nil
        providers = []
        shownProviders = []
        pricesInFlight = false
        pricesSaved = nil
        snapshot = AgentUsageSnapshot()
        claudeAppChecked = nil
        // A held hub keeps showing why, so the person fixes the key before Vorssaint tries it again.
        let now = Date()
        hubStates = hubStates.filter { (hubHolds[$0.key] ?? .distantPast) > now }
        hubAsked = [:]
        hubTasks.values.forEach { $0.task.cancel() }
        hubTasks = [:]
        queue.async { [self] in
            readerSession = -1
            readerCancellation = nil
            poller?.cancel()
            poller = nil
            watcher?.stop()
            watcher = nil
            watchedRoots = []
            store = AgentUsageStore()
            cursors.removeAll()
            published = AgentUsageSnapshot()
            alerts = AgentLimitAlerts()
            budgetDay = nil
            claudePlan = nil
            claudeOrganization = nil
            claudeEmail = nil
            hubAccounts = [:]
            hubRoutes = [:]
            claudeProfileModified = nil
            claudeAppModified = nil
            claudeAppSamples = []
            savedMark = nil
            lastSave = .distantPast
        }
    }

    /// Limits an agent read from the account on request, newer than its
    /// logs until it writes again: after a banked reset, right away.
    func noteLimits(_ reading: AgentLimits) {
        guard running else { return }
        queue.async { [self] in
            guard readerSession >= 0, enabled.contains(reading.provider) else { return }
            store.updateLimits(reading)
            checkLimits()
            schedulePublish()
        }
    }

    /// Opening the page shows the latest limits the Claude app saved.
    func pageDidAppear() {
        guard running else { return }
        queue.async { [self] in
            guard readerSession >= 0 else { return }
            readClaudeApp(now: Date())
            checkLimits()
            publish()
        }
    }

    // MARK: Reading

    private func startTimer() {
        let timer = Timer(timeInterval: Self.tick, repeats: true) { [weak self] _ in self?.tickTimer() }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func start(session: Int, providers: Set<AgentProvider>, shown: Set<AgentProvider>, cancellation: Cancellation) {
        startTimer()
        let hubIDs = hubs.map(\.id)
        queue.async { [self] in
            readerSession = session
            readerCancellation = cancellation
            enabled = providers
            self.shown = shown
            hubOrder = hubIDs
            store = AgentUsageStore()
            cursors.removeAll()
            // Prices first, so the first read is already priced.
            loadPrices()
            let horizon = Date().addingTimeInterval(-Self.horizon)
            let roots = AgentLogRoot.all(home: home).filter { providers.contains($0.provider) }
            let files = AgentLogReader.discover(roots, since: horizon)
            // Resumes where the last launch stopped, among the logs there now.
            if let saved = AgentUsageArchive.load(), saved.providers == providers {
                let resumed = AgentUsageArchive.resume(saved, logs: Set(files.map(\.path)), since: horizon)
                (store, cursors) = (resumed.store, resumed.cursors)
                // What the resume took back leaves the disk at the next save.
                if resumed.unchanged { savedMark = progressMark }
            }
            for file in files {
                // A stop while reading leaves the rest for the next start.
                guard !cancellation.isCancelled else { return }
                read(file.path, provider: file.provider)
            }
            guard !cancellation.isCancelled else { return }
            let now = Date()
            // A turn left open by a crash would otherwise stay working.
            store.closeIdleTurns(now: now, after: NotchAgentSupport.idleTurn)
            closeEndedTurns(roots, atLaunch: true)
            // The account Claude Code uses picks the Claude app's readings.
            readClaudePlan()
            readClaudeApp(now: now)
            store.reportsTransitions = true
            alerts.baseline(currentLimits())
            // A budget already passed before launch is history, not news.
            let today = Calendar.autoupdatingCurrent.startOfDay(for: now)
            if let budget = NotchAgentSupport.dailyBudget(),
               store.records.lazy.filter({ $0.date >= today }).reduce(0.0, { $0 + ($1.cost ?? 0) }) >= budget {
                budgetDay = today
            }
            readRoutes()
            watch(roots)
            startPolling()
            publish()
            saveProgress()
        }
    }

    /// Saves progress, or removes it once the section is off, even what an
    /// earlier launch saved. Quitting stops the service too and ends the
    /// process right after, so this returns only once the file is settled.
    /// Main thread.
    private func settleArchive(keeping keeps: Bool) {
        queue.sync {
            if keeps { saveProgress() } else { AgentUsageArchive.remove() }
        }
    }

    /// Saves what was read, when reading moved on since the last save. Runs
    /// on `queue`.
    private func saveProgress() {
        guard readerSession >= 0 else { return }
        let mark = progressMark
        lastSave = Date()
        guard mark != savedMark else { return }
        // A log that started over while running still counts what its old
        // contents gave. Left out, the next launch reads it as rewritten.
        // Nothing from OpenCode's database is saved. Its open replies and
        // sessions live only in memory, so each launch reads it again.
        let kept = cursors.values.filter { !$0.restarted && $0.provider != .opencode }
        let contents = AgentUsageArchive.Contents(providers: enabled, store: store.saved, cursors: kept.map(\.saved))
        if AgentUsageArchive.save(contents) { savedMark = mark }
    }

    /// Changes whenever a log is read further, replaced or let go. OpenCode,
    /// which is never saved, leaves it alone.
    private var progressMark: Int {
        let records = store.records.reduce(0) { $1.provider == .opencode ? $0 : $0 + 1 }
        return cursors.values.reduce(records) { mark, cursor in
            guard cursor.provider != .opencode else { return mark }
            var hasher = Hasher()
            hasher.combine(cursor.path)
            hasher.combine(cursor.offset)
            hasher.combine(cursor.identity)
            return mark &+ hasher.finalize()
        }
    }

    /// Runs on `queue`.
    private func startPolling() {
        poller?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.poll, repeating: Self.poll, leeway: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let read = self.pollOpenLogs(within: Self.pollWindow)
            let stopped = self.store.closeSettledTurns(now: Date())
            // After the logs, so a turn its last lines ended ends as usual.
            guard self.closeEndedTurns(self.watchedRoots) || read || stopped else { return }
            self.checkLimits()
            self.schedulePublish()
        }
        timer.resume()
        poller = timer
    }

    /// Reads the logs that grew, were replaced or disappeared since the last
    /// look, among those an agent may still be writing. True when that
    /// changed what is stored.
    private func pollOpenLogs(within window: TimeInterval) -> Bool {
        guard readerSession >= 0 else { return false }
        let now = Date()
        // A turn gone quiet, as while it waits for an approval, is noticed
        // as soon as its work resumes.
        var working = Set(store.turns.keys).union(store.waiting.keys)
        // An OpenCode turn is kept by database and session.
        for key in working {
            if let mark = key.firstIndex(of: "#") { working.insert(String(key[..<mark])) }
        }
        var changed = false
        for (path, cursor) in cursors
        where working.contains(path) || now.timeIntervalSince(cursor.modified) < window {
            if cursor.provider == .opencode {
                // A database changes in place: its write-ahead log grows instead.
                if let modified = AgentOpenCodeReader.modified(path), modified <= cursor.modified { continue }
                if read(path, provider: cursor.provider) { changed = true }
                continue
            }
            var info = stat()
            let exists = stat(path, &info) == 0
            guard !exists || UInt64(max(0, info.st_size)) != cursor.offset
                    || UInt64(info.st_ino) != cursor.identity else { continue }
            if read(path, provider: cursor.provider) { changed = true }
        }
        return changed
    }

    /// Ends the Claude turns whose process is gone. True when one was showing.
    @discardableResult
    private func closeEndedTurns(_ roots: [AgentLogRoot], atLaunch: Bool = false) -> Bool {
        guard store.showsClaudeTurn else { return false }
        let folders = roots.filter { $0.provider == .claude }
            .map { $0.url.deletingLastPathComponent().appending(path: "sessions", directoryHint: .isDirectory) }
        return store.closeEndedTurns(AgentSessionRegistry.read(folders), atLaunch: atLaunch)
    }

    /// True when the log had entries to apply, or was gone and took a
    /// working turn with it.
    @discardableResult
    private func read(_ path: String, provider: AgentProvider) -> Bool {
        guard let cancellation = readerCancellation, !cancellation.isCancelled else { return false }
        guard FileManager.default.fileExists(atPath: path) else {
            cursors[path] = nil
            return store.forget(file: path)
        }
        let cursor = cursors[path] ?? AgentLogCursor(path: path, provider: provider)
        cursors[path] = cursor
        var changed = false
        let now = Date()
        AgentLogReader.readAppended(cursor, since: now.addingTimeInterval(-Self.horizon),
                                    shouldContinue: { !cancellation.isCancelled }) { line in
            // Apply in log order while the chunk is alive instead of retaining
            // every parsed entry until a potentially multi-gigabyte file ends.
            let entries: [AgentLogEntry]
            switch provider {
            case .claude: entries = AgentLogParser.parseClaude(line, state: &cursor.state, now: now)
            case .codex: entries = AgentLogParser.parseCodex(line, state: &cursor.state, now: now)
            case .opencode: entries = AgentLogParser.parseOpenCode(line, state: &cursor.state, now: now)
            }
            guard !entries.isEmpty else { return }
            changed = true
            let isSubagent = provider == .opencode && !cursor.state.parentSession.isEmpty
            let turnFile = provider == .opencode && !cursor.state.session.isEmpty ? "\(path)#\(cursor.state.session)" : path
            let tracksTurns = isSubagent ? false : cursor.tracksTurns
            let parent = isSubagent ? "\(path)#\(cursor.state.parentSession)" : cursor.parent
            let finished = store.apply(entries, file: turnFile, provider: provider, tracksTurns: tracksTurns,
                                       parent: parent, modified: cursor.modified, now: now)
            finished.forEach(report)
        }
        return changed
    }

    private func watch(_ roots: [AgentLogRoot]) {
        let existing = roots.filter(\.exists)
        watchedRoots = existing
        lastRootCheck = Date()
        if watcher == nil {
            watcher = AgentLogWatcher(queue: queue) { [weak self] paths, rescan in
                self?.filesChanged(paths, rescan: rescan)
            }
        }
        if existing.isEmpty { watcher?.stop() } else { watcher?.start(existing.map(\.url.path)) }
    }

    private func filesChanged(_ paths: [String], rescan: Bool) {
        guard readerSession >= 0, !watchedRoots.isEmpty else { return }
        var changed = false
        if rescan {
            for file in AgentLogReader.discover(watchedRoots, since: Date().addingTimeInterval(-Self.horizon)) {
                if read(file.path, provider: file.provider) { changed = true }
            }
        } else {
            for path in Set(paths) where AgentLogReader.isLog(path) {
                let actualPath = path.hasSuffix("-wal") ? String(path.dropLast(4)) : path
                guard let root = watchedRoots.first(where: { actualPath.hasPrefix($0.url.path + "/") }),
                      root.provider != .opencode
                        || actualPath == root.url.appending(path: AgentOpenCodeReader.database).path else { continue }
                if read(actualPath, provider: root.provider) { changed = true }
            }
        }
        // Saved tool output and lines with nothing to keep do not change the
        // summary or require a display update.
        guard changed else { return }
        checkLimits()
        schedulePublish()
    }

    /// Bursts of writes publish once.
    private func schedulePublish() {
        guard !publishScheduled else { return }
        publishScheduled = true
        queue.asyncAfter(deadline: .now() + Self.publishDelay) { [self] in
            publishScheduled = false
            publish()
        }
    }

    private func tickTimer() {
        guard running else { return }
        syncPrices()
        askHubs()
        queue.async { [self] in
            guard readerSession >= 0 else { return }
            let now = Date()
            let before = inputs
            store.closeIdleTurns(now: now, after: NotchAgentSupport.idleTurn)
            store.dropRecords(before: now.addingTimeInterval(-Self.horizon))
            // A log kept open through a long pause reports nothing when work
            // resumes; the day's logs are looked at less often than recent ones.
            var changed = pollOpenLogs(within: 86_400)
            // A folder that appears later, like a first Codex session, is
            // picked up without a restart.
            if now.timeIntervalSince(lastRootCheck) > 300 {
                let roots = AgentLogRoot.all(home: home).filter { enabled.contains($0.provider) }
                if roots.filter(\.exists) != watchedRoots {
                    for file in AgentLogReader.discover(roots, since: now.addingTimeInterval(-Self.horizon)) {
                        if read(file.path, provider: file.provider) { changed = true }
                    }
                    watch(roots)
                }
                lastRootCheck = now
                readClaudePlan()
                // Codex's config may have gained or lost a hub provider.
                if readRoutes() { changed = true }
            }
            readClaudeApp(now: now)
            checkLimits()
            reportRenewals(now: now)
            if now.timeIntervalSince(lastSave) >= Self.saveInterval { saveProgress() }
            // Publish only when stored values or sliding time windows change.
            if changed || inputs != before || AgentUsageSummary.movesWithClock(published, now: now) {
                schedulePublish()
            }
        }
    }

    /// The stored state a snapshot is made from, compared across a tick.
    private struct Inputs: Equatable {
        let records: Int
        let turns: [String: AgentLiveSession]
        let limits: [AgentProvider: AgentLimits]
        let codexPlan: String?
        let claudePlan: AgentPlan?
        let claudeOrganization: String?
        let claudeApp: [AgentClaudeAppUsage.Sample]
    }

    /// Runs on `queue`.
    private var inputs: Inputs {
        Inputs(records: store.records.count, turns: store.turns, limits: store.limits, codexPlan: store.codexPlan,
               claudePlan: claudePlan, claudeOrganization: claudeOrganization, claudeApp: claudeAppSamples)
    }

    /// Runs on `queue` and hands the finished snapshot to the main thread.
    private func publish() {
        let session = readerSession
        guard session >= 0 else { return }
        var plans: [AgentProvider: AgentPlan] = [:]
        if let claudePlan { plans[.claude] = claudePlan }
        if let codex = AgentPlans.codex(planType: store.codexPlan) { plans[.codex] = codex }
        let hubs = hubContext
        var next = store.snapshot(plans: plans.filter { shown.contains($0.key) }, providers: enabled,
                                  limitProviders: shown, hubs: hubs, now: Date())
        let merged = mergedAccounts
        let claudeTile = shown.contains(.claude) && next.seen.contains(.claude)
        if claudeTile, let reading = claudeReading() { next.limits[.claude] = reading }
        next.accounts = orderedAccounts.filter { !merged.contains($0.id) || !claudeTile }
        next.pool = orderedAccounts
        next.hubs = hubs
        published = next
        checkBudget(next)
        let checked = shown.contains(.claude) ? claudeAppSamples.last(where: {
            claudeOrganization == nil || $0.organization == nil || $0.organization == claudeOrganization
        })?.date : nil
        let listed = AgentPricing.list.updated
        let prices = listed == AgentPriceList.empty.updated ? nil : listed
        DispatchQueue.main.async { [weak self] in
            guard let self, self.running, self.session == session else { return }
            if self.claudeAppChecked != checked { self.claudeAppChecked = checked }
            if self.pricesUpdated != prices { self.pricesUpdated = prices }
            if self.snapshot != next { self.snapshot = next }
        }
    }

    // MARK: Alerts

    /// Filters by the person's choices on the main thread, where they live.
    private func report(_ event: AgentUsageEvent) {
        let session = readerSession
        DispatchQueue.main.async { [weak self] in
            guard let self, self.running, self.session == session else { return }
            switch event {
            case .finished(let provider, let duration, _, _, _):
                guard self.providers.contains(provider), let minimum = NotchAgentSupport.finishMinimum(),
                      duration >= minimum else { return }
            case .limitWarning(let provider, _, let account), .limitReset(let provider, _, let account):
                // Hub accounts follow the hubs, not the switches for this Mac's agents.
                guard account != nil || self.shownProviders.contains(provider),
                      NotchAgentSupport.limitThreshold() != nil else { return }
            case .budgetReached:
                guard NotchAgentSupport.dailyBudget() != nil else { return }
            }
            self.events.send(event)
        }
    }

    /// Runs on `queue` whenever limits may have changed.
    private func checkLimits() {
        guard store.reportsTransitions else { return }
        let threshold = NotchAgentSupport.limitThreshold() ?? NotchAgentSupport.defaultLimitThreshold
        for warning in alerts.check(currentLimits(), threshold: threshold) {
            report(.limitWarning(provider: warning.provider, window: warning.window, account: warning.account))
        }
        // A banked reset renews a warned window before its time, which is
        // news now rather than at the renewal it replaced.
        for renewed in alerts.renewedEarly(currentLimits(), threshold: threshold) {
            report(.limitReset(provider: renewed.provider, window: renewed.window, account: renewed.account))
        }
    }

    /// Runs on `queue`.
    private func currentLimits() -> [String: AgentTrackedLimits] {
        AgentLimitAlerts.current(local: store.limits, shown: shown, claude: claudeReading(),
                                 accounts: orderedAccounts, merged: mergedAccounts)
    }

    /// The Claude sign-in on this Mac, as the newer of the reading the Claude
    /// app saved and one a hub took of the same account. Runs on `queue`.
    private func claudeReading() -> AgentLimits? {
        let merged = mergedAccounts
        let hub = orderedAccounts.filter { merged.contains($0.id) }.compactMap(\.limits)
        return ([store.limits[.claude]].compactMap { $0 } + hub).max { $0.observedAt < $1.observedAt }
    }

    /// What ties turns to hubs and accounts. Nil until the person adds a hub.
    /// Runs on `queue`.
    private var hubContext: AgentHubContext? {
        hubOrder.isEmpty ? nil
            : AgentHubContext(hubs: hubOrder, codexRoutes: hubRoutes, accounts: orderedAccounts)
    }

    /// Reads which Codex providers reach a hub. True when that changed.
    /// Runs on `queue`.
    @discardableResult
    private func readRoutes() -> Bool {
        let routes = AgentHubRoutes.codex(home: home, hubs: hubOrder)
        guard routes != hubRoutes else { return false }
        hubRoutes = routes
        return true
    }

    /// A warned window that renews brings its agent back: worth a word.
    private func reportRenewals(now: Date) {
        for entry in alerts.renewals(now: now) {
            report(.limitReset(provider: entry.provider, window: entry.window, account: entry.account))
        }
    }

    private func checkBudget(_ snapshot: AgentUsageSnapshot) {
        guard store.reportsTransitions, let budget = NotchAgentSupport.dailyBudget() else { return }
        let today = Calendar.autoupdatingCurrent.startOfDay(for: snapshot.now)
        let spent = snapshot.usage(.today).total.cost
        guard spent >= budget, budgetDay != today else { return }
        budgetDay = today
        report(.budgetReached(spent: spent, budget: budget))
    }

    // MARK: Plans and limits

    /// The plan comes from the account profile Claude Code caches; nothing
    /// else in that file is kept.
    private func readClaudePlan() {
        guard shown.contains(.claude) else { return }
        let url = home.appending(path: ".claude.json")
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard modified != claudeProfileModified else { return }
        claudeProfileModified = modified
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let account = json["oauthAccount"] as? [String: Any] else {
            claudePlan = nil
            claudeOrganization = nil
            claudeEmail = nil
            return
        }
        claudeOrganization = account["organizationUuid"] as? String
        claudeEmail = (account["emailAddress"] as? String)?.lowercased()
        claudePlan = AgentPlans.claude(organizationType: account["organizationType"] as? String,
                                       rateLimitTier: account["organizationRateLimitTier"] as? String
                                        ?? account["userRateLimitTier"] as? String)
    }

    /// Reads the limits the Claude app saved when the file changes, and
    /// places them at `now` on every call, since a session ages out between
    /// saves. Runs on `queue`.
    private func readClaudeApp(now: Date) {
        guard shown.contains(.claude) else {
            if store.limits[.claude]?.source == .claudeApp { store.clearLimits(.claude) }
            claudeAppModified = nil
            claudeAppSamples = []
            return
        }
        let url = AgentClaudeAppUsage.historyURL(home: home)
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if modified != claudeAppModified {
            claudeAppModified = modified
            claudeAppSamples = modified == nil ? []
                : (try? Data(contentsOf: url)).flatMap(AgentClaudeAppUsage.samples) ?? []
        }
        // Claude Code's own first request can place the session's start.
        let start = AgentClaudeAppUsage.sessionStart(store.records, samples: claudeAppSamples,
                                                     organization: claudeOrganization)
        if let limits = AgentClaudeAppUsage.limits(from: claudeAppSamples, now: now, sessionStart: start,
                                                   organization: claudeOrganization) {
            store.setLimits(limits)
        } else if store.limits[.claude]?.source == .claudeApp {
            store.clearLimits(.claude)
        }
    }

    // MARK: Hubs

    /// Adds a hub, or replaces the one at the same address. False when the
    /// address is not a web address or the file cannot be written.
    @discardableResult
    func addHub(url: String, key: String, label: String) -> Bool {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let address = AgentHub.normalizedURL(url), !key.isEmpty else { return false }
        // Adding the same address again keeps the names given to its accounts.
        let hub = AgentHub(url: address, label: label.trimmingCharacters(in: .whitespacesAndNewlines), key: key,
                           names: hubs.first { $0.id == address }?.names ?? [:])
        var next = hubs.filter { $0.id != hub.id }
        next.append(hub)
        guard AgentHubStore.save(next) else { return false }
        forgetHub(hub.id)
        hubs = next
        hubsChanged(dropping: hub.id)
        return true
    }

    func removeHub(_ id: String) {
        let next = hubs.filter { $0.id != id }
        guard next != hubs, AgentHubStore.save(next) else { return }
        forgetHub(id)
        hubs = next
        hubsChanged(dropping: id)
    }

    /// Gives a hub account a name of its own. An empty name brings back the
    /// one the hub reports.
    func renameAccount(hub id: String, index: String, to name: String) {
        guard let position = hubs.firstIndex(where: { $0.id == id }) else { return }
        var next = hubs
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        next[position].names[index] = trimmed.isEmpty ? nil : trimmed
        guard next != hubs, AgentHubStore.save(next) else { return }
        hubs = next
    }

    /// What the island calls an account. That is the name the person gave
    /// it, else the hub's name unless names are hidden, else the agent's name.
    func accountLabel(_ account: AgentHubAccount) -> String {
        if let given = hubs.first(where: { $0.id == account.hub })?.names[account.index] { return given }
        return NotchAgentSupport.hidesAccountNames() ? account.provider.displayName : account.name
    }

    /// The same for an alert, which carries only the account's id.
    func accountLabel(id: String, provider: AgentProvider) -> String {
        snapshot.accounts.first { $0.id == id }.map(accountLabel) ?? provider.displayName
    }

    private func forgetHub(_ id: String) {
        hubStates[id] = nil
        hubAsked[id] = nil
        hubHolds[id] = nil
        hubTasks.removeValue(forKey: id)?.task.cancel()
    }

    /// `dropping` names a hub removed or reached with another key. Its
    /// accounts, readings and pending renewals go, since they belonged to
    /// the old connection.
    private func hubsChanged(dropping dropped: String) {
        guard running else { return }
        let ids = hubs.map(\.id)
        let session = self.session
        queue.async { [self] in
            guard readerSession == session else { return }
            hubOrder = ids
            hubAccounts[dropped] = nil
            hubAccounts = hubAccounts.filter { ids.contains($0.key) }
            alerts.discard(hub: dropped)
            readRoutes()
            checkLimits()
            publish()
        }
        askHubs()
        // The first hub added, or the last removed, changes which logs are read.
        syncWithPreferences()
    }

    /// Asks every hub that is due, one request at a time per hub.
    private func askHubs() {
        guard running, !paused else { return }
        let now = Date()
        for hub in hubs where hubTasks[hub.id] == nil {
            if let hold = hubHolds[hub.id], hold > now { continue }
            if let asked = hubAsked[hub.id], now.timeIntervalSince(asked) < Self.hubInterval { continue }
            hubAsked[hub.id] = now
            if hubStates[hub.id] == nil { hubStates[hub.id] = .checking }
            let session = self.session
            let token = UUID()
            let task = Task.detached(priority: .utility) {
                let reading = await AgentHubClient.read(hub)
                guard !Task.isCancelled else { return }
                DispatchQueue.main.async {
                    AgentUsageService.shared.hubAnswered(hub, reading, session: session, token: token)
                }
            }
            hubTasks[hub.id] = (token, task)
        }
    }

    private func hubAnswered(_ hub: AgentHub, _ reading: AgentHubClient.Reading, session: Int, token: UUID) {
        // Only the reading still in flight counts. A cancelled one's late
        // answer would otherwise clear the newer reading's place.
        guard hubTasks[hub.id]?.token == token else { return }
        hubTasks[hub.id] = nil
        // A hub removed or given a new key meanwhile keeps nothing from before.
        guard running, self.session == session, hubs.contains(where: { $0.sameConnection(as: hub) }) else { return }
        hubStates[hub.id] = reading.state
        switch reading.state {
        case .wrongKey: hubHolds[hub.id] = .distantFuture
        case .blocked: hubHolds[hub.id] = Date().addingTimeInterval(AgentHubParser.banLength)
        default: hubHolds[hub.id] = nil
        }
        guard let accounts = reading.accounts else { return }
        queue.async { [self] in
            guard readerSession == session else { return }
            let previous = Dictionary(hubAccounts[hub.id, default: []].map { ($0.id, $0) }) { first, _ in first }
            hubAccounts[hub.id] = accounts.map { account in
                // A failed read keeps the last good one, shown as older.
                guard let before = previous[account.id] else { return account }
                var kept = account
                // A listing that failed keeps the models listed before.
                if kept.models.isEmpty { kept.models = before.models }
                guard account.failed else { return kept }
                kept.limits = before.limits
                kept.plan = account.plan ?? before.plan
                return kept
            }
            checkLimits()
            publish()
        }
    }

    /// Runs on `queue`.
    private var orderedAccounts: [AgentHubAccount] {
        hubOrder.flatMap { hubAccounts[$0] ?? [] }
    }

    /// Hub accounts that are the Claude account signed in on this Mac.
    /// Runs on `queue`.
    private var mergedAccounts: Set<String> {
        guard shown.contains(.claude), let claudeEmail else { return [] }
        return Set(orderedAccounts.filter { $0.provider == .claude && $0.email?.lowercased() == claudeEmail }.map(\.id))
    }

    // MARK: Prices

    /// The newer of the list inside the app and the last one downloaded.
    /// Runs on `queue`.
    private func loadPrices() {
        if shippedPrices == nil { shippedPrices = AgentPriceSource.bundled() }
        let cached = AgentPriceSource.cached()
        AgentPricing.install(AgentPriceList.newer(shippedPrices, cached?.list) ?? .empty)
        let saved = cached?.saved ?? .distantPast
        let session = readerSession
        DispatchQueue.main.async { [weak self] in
            guard let self, self.running, self.session == session else { return }
            self.pricesSaved = saved
            self.syncPrices()
        }
    }

    /// Looks for a newer price list at most once a day, and again a few hours
    /// after a failure. The last good list stays in use meanwhile.
    private func syncPrices() {
        guard running, NotchAgentSupport.updatesPrices(), !pricesInFlight, let saved = pricesSaved else { return }
        let now = Date()
        let wait = pricesFailed ? AgentPriceSource.retryInterval : AgentPriceSource.refreshInterval
        guard now.timeIntervalSince(saved) >= AgentPriceSource.refreshInterval,
              now.timeIntervalSince(pricesAttempted) >= wait else { return }
        pricesInFlight = true
        pricesAttempted = now
        let session = self.session
        AgentPriceSource.download { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.session == session else { return }
                self.pricesInFlight = false
                guard let result else {
                    self.pricesFailed = true
                    return
                }
                let (data, list) = result
                self.pricesFailed = false
                self.pricesSaved = Date()
                self.queue.async {
                    AgentPriceSource.save(data)
                    guard self.readerSession == session,
                          AgentPricing.install(AgentPriceList.newer(self.shippedPrices, list) ?? list) else { return }
                    self.store.reprice()
                    self.publish()
                }
            }
        }
    }
}
