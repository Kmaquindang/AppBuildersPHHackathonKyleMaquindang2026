// MacSetupService.swift
// Mac only: the "Set up AI" button. Reads the hardware, finds Ollama, plans models for this Mac,
// and only after an explicit tap downloads what is missing:
//   1. Ollama for macOS from ollama.com (https, redirects limited to ollama.com and GitHub releases)
//      into ~/Downloads, then opens it so macOS shows its normal Gatekeeper and "Move to Applications"
//      prompts. Nothing is bypassed and nothing is installed silently.
//   2. Models through the local Ollama server (/api/pull on 127.0.0.1, streaming progress).
//   3. Warm up and a one-question self-test.
// Sandbox: the app stays sandboxed. It only needs the Downloads folder entitlement for step 1
// (com.apple.security.files.downloads.read-write); /Applications is never written by Pasa.

#if os(macOS)
import AppKit
import Foundation

@MainActor
final class MacSetupService: NSObject, ObservableObject {
    enum Phase: Equatable {
        case idle
        case downloadingOllama(done: Int64, total: Int64)
        case openingOllama(String)
        case waitingForServer(Int)
        case pulling(model: String, status: String, fraction: Double?)
        case warming(String)
        case selfTest
        case finished(String)
        case failed(String)
        case cancelled

        var busy: Bool {
            switch self {
            case .idle, .finished, .failed, .cancelled: return false
            default: return true
            }
        }
    }

    @Published private(set) var hardware: HardwareProfile
    @Published private(set) var presence = OllamaPresence(appInstalled: false, cliPath: nil, serverUp: false)
    @Published private(set) var installed: [String] = []
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var selfTest: BenchmarkResult?
    @Published var wantVision: Bool?
    @Published var chatOverride = ""
    @Published var visionOverride = ""

    private var job: Task<Void, Never>?
    private var download: URLSessionDownloadTask?
    private var downloadContinuation: CheckedContinuation<URL, Error>?
    private var downloadDestination: URL?
    private let base = OllamaClient.defaultBaseURL

    override init() {
        hardware = MacSetupService.readHardware()
        super.init()
    }

    var plan: ModelPlan {
        ModelPlanner.plan(hardware: hardware, wantVision: wantVision, chatOverride: chatOverride, visionOverride: visionOverride,
                          installed: installed, ollamaInstalled: presence.installed)
    }

    // MARK: Read-only detection

    static func readHardware() -> HardwareProfile {
        func sysctlString(_ name: String) -> String? {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var buf = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
            return String(cString: buf)
        }
        func sysctlInt(_ name: String) -> Int? {
            var value: Int32 = 0
            var size = MemoryLayout<Int32>.size
            guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
            return Int(value)
        }
        let arm = sysctlInt("hw.optional.arm64") == 1
        let chip = sysctlString("machdep.cpu.brand_string") ?? (arm ? "Apple silicon" : "Intel")
        let home = FileManager.default.homeDirectoryForCurrentUser
        let free = (try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
        return HardwareProfile(memoryBytes: ProcessInfo.processInfo.physicalMemory, appleSilicon: arm, chip: chip,
                               cores: ProcessInfo.processInfo.activeProcessorCount, freeDiskBytes: free)
    }

    /// Looks for the app, the command line tool and the server. Reads only.
    func detect() async {
        hardware = MacSetupService.readHardware()
        let fm = FileManager.default
        let app = OllamaPresence.appPaths.contains { fm.fileExists(atPath: $0) }
        let cli = OllamaPresence.cliPaths.first { fm.isExecutableFile(atPath: $0) }
        let client = OllamaClient(baseURL: base, model: OllamaClient.defaultModel, fallbackModel: nil, timeout: 3)
        let version = try? await client.serverVersion()
        installed = (try? await client.installedModels()) ?? []
        presence = OllamaPresence(appInstalled: app, cliPath: cli, serverUp: version != nil, version: version)
    }

    // MARK: Explicit setup

    /// Runs only from the "Set up AI" button after the user has seen what downloads.
    func start(internet: InternetState, apply: @escaping (String, String?) -> Void) {
        guard !phase.busy else { return }
        selfTest = nil
        let plan = self.plan
        if let blocked = plan.blocked { phase = .failed(blocked); return }
        if plan.totalBytes > 0 && internet == .offline {
            phase = .failed("Connect to internet once for setup, then Libre runs offline.")
            return
        }
        job = Task { [weak self] in
            guard let self else { return }
            do {
                if plan.needsOllama { try await self.installOllama() }
                try await self.waitForServer(seconds: 180)
                for item in plan.downloads where !item.installed {
                    try await self.pull(item.model)
                }
                await self.detect()
                apply(plan.chat, plan.vision)
                try await self.warmAndTest(plan.chat)
            } catch is CancellationError {
                self.phase = .cancelled
            } catch {
                if Task.isCancelled { self.phase = .cancelled } else { self.phase = .failed(error.localizedDescription) }
            }
        }
    }

    func cancel() {
        job?.cancel()
        download?.cancel()
        download = nil
        phase = .cancelled
    }

    // MARK: Steps

    private struct SetupError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func installOllama() async throws {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let zip = downloads.appendingPathComponent(OllamaDownload.fileName)
        phase = .downloadingOllama(done: 0, total: ModelCatalog.ollamaAppBytes)
        let file = try await downloadZip(to: zip)
        let head = (try? FileHandle(forReadingFrom: file))?.readData(ofLength: 4) ?? Data()
        guard OllamaDownload.looksLikeZip(head) else {
            try? FileManager.default.removeItem(at: file)
            throw SetupError(message: "The download was not the Ollama app (not a zip). Nothing was opened.")
        }
        // Archive Utility unzips next to the zip; macOS checks the app's signature when it opens.
        phase = .openingOllama("Unzipping Ollama in Downloads...")
        NSWorkspace.shared.open(file)
        let candidates = [URL(fileURLWithPath: "/Applications/Ollama.app"), downloads.appendingPathComponent("Ollama.app")]
        var appURL: URL?
        for _ in 0..<120 {
            try Task.checkCancellation()
            if let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) { appURL = found; break }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        guard let appURL else { throw SetupError(message: "Ollama.app did not appear in Downloads. Open \(OllamaDownload.fileName) in Finder, then press Set up AI again.") }
        phase = .openingOllama("Opening Ollama. Answer the macOS prompts (Open, Move to Applications).")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        _ = try? await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
    }

    private func downloadZip(to destination: URL) async throws -> URL {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)   // callbacks on main: MainActor.assumeIsolated below is valid
        defer { session.finishTasksAndInvalidate() }
        downloadDestination = destination
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
                downloadContinuation = cont
                let task = session.downloadTask(with: OllamaDownload.url)
                download = task
                task.resume()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.download?.cancel() }
        }
    }

    private func waitForServer(seconds: Int) async throws {
        let client = OllamaClient(baseURL: base, model: OllamaClient.defaultModel, fallbackModel: nil, timeout: 3)
        for left in stride(from: seconds, to: 0, by: -2) {
            try Task.checkCancellation()
            if (try? await client.serverVersion()) != nil { await detect(); return }
            phase = .waitingForServer(left)
            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
        throw SetupError(message: "Ollama did not start on 127.0.0.1:11434. Open the Ollama app, then press Set up AI again.")
    }

    /// Streams /api/pull from the local server. A retry resumes: Ollama keeps finished layers.
    private func pull(_ model: String) async throws {
        guard OllamaClient.isLoopback(base) else { throw SetupError(message: "Refusing to pull from a non-local Ollama.") }
        phase = .pulling(model: model, status: "starting", fraction: nil)
        var request = URLRequest(url: base.appendingPathComponent("api/pull"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = PullProgress.requestBody(model: model)
        request.timeoutInterval = 3600
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw SetupError(message: "Ollama refused to pull \(model) (HTTP \(http.statusCode)).")
        }
        var sawSuccess = false
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let p = PullProgress.parse(line) else { continue }
            if let error = p.error { throw SetupError(message: "Pull \(model) failed: \(error)") }
            if p.isSuccess { sawSuccess = true }
            phase = .pulling(model: model, status: p.status, fraction: p.fraction)
        }
        if !sawSuccess { throw SetupError(message: "Pull \(model) stopped early. Press Retry to resume.") }
    }

    private func warmAndTest(_ model: String) async throws {
        phase = .warming(model)
        let client = OllamaClient(baseURL: base, model: model, fallbackModel: nil, timeout: 300)
        _ = try await client.chat([ChatTurn(role: "user", content: "Reply with OK.")], json: false)
        try Task.checkCancellation()
        phase = .selfTest
        let result = await BenchmarkSuite.runOne(BenchmarkSuite.questions[0], llm: client, model: model)
        selfTest = result
        phase = result.correct
            ? .finished("Ready. Self-test passed in \(result.latencyMs) ms (\(result.reason)).")
            : .failed("Self-test answered but did not pass: \(result.reason). The model works; check the AI settings.")
    }
}

extension MacSetupService: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                                newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Only https hops through ollama.com and GitHub releases.
        completionHandler(OllamaDownload.isAllowed(request.url) ? request : nil)
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : ModelCatalog.ollamaAppBytes
        Task { @MainActor [weak self] in self?.phase = .downloadingOllama(done: totalBytesWritten, total: total) }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file disappears after this call returns: move it now.
        let finalURL = downloadTask.response?.url
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        let moved: Result<URL, Error>
        do {
            guard status == 200, OllamaDownload.isAllowed(finalURL) else {
                throw NSError(domain: "Libre", code: status, userInfo: [NSLocalizedDescriptionKey: "Download refused (HTTP \(status) from \(finalURL?.host ?? "unknown host"))."])
            }
            let dest = MainActor.assumeIsolated { downloadDestination } ?? location
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
            moved = .success(dest)
        } catch {
            moved = .failure(error)
        }
        MainActor.assumeIsolated {
            downloadContinuation?.resume(with: moved)
            downloadContinuation = nil
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        Task { @MainActor [weak self] in
            self?.downloadContinuation?.resume(throwing: (error as? URLError)?.code == .cancelled ? CancellationError() : error)
            self?.downloadContinuation = nil
        }
    }
}
#endif
