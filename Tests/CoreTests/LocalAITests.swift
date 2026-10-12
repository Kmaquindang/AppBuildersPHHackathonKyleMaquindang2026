// LocalAITests.swift: local proof badge, daily digest (fake model, fixed clock), vision request
// shape (fake HTTP), photo and summary intents, benchmark scoring and reports.

import Foundation

final class FakePoster: HTTPPoster, @unchecked Sendable {
    private let lock = NSLock()
    private var _bodies: [Data] = []
    private var _urls: [URL] = []
    let reply: Data
    let status: Int
    init(reply: String, status: Int = 200) { self.reply = Data(reply.utf8); self.status = status }
    var bodies: [Data] { lock.lock(); defer { lock.unlock() }; return _bodies }
    var urls: [URL] { lock.lock(); defer { lock.unlock() }; return _urls }
    private func record(_ url: URL, _ body: Data) { lock.lock(); _bodies.append(body); _urls.append(url); lock.unlock() }
    func post(_ url: URL, body: Data, timeout: TimeInterval) async throws -> (Data, Int) {
        record(url, body)
        return (reply, status)
    }
}

func manilaCalendar() -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "Asia/Manila")!
    return c
}

func manila(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0) -> Date {
    manilaCalendar().date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

func runLocalProofTests() {
    let p = AIProof(mac: "Site Office", model: "qwen3:8b", internet: .offline, tokensPerSecond: 16.63, latencyMs: 6470)
    check(p.badge == "On-device: Site Office · qwen3:8b · offline · 16.6 tok/s · 6470 ms", "proof badge format")
    let fast = AIProof(mac: "Site Office", model: nil, internet: .connected, tokensPerSecond: nil, latencyMs: 9)
    check(fast.badge == "On-device: Site Office · no model call · internet available, not used · 9 ms", "fast path badge says no model call and internet not used")
    check(InternetState.from(satisfied: true, realInterfaces: 0) == .offline, "satisfied path with only peer-to-peer interfaces is not internet")
    check(InternetState.from(satisfied: true, realInterfaces: 1) == .connected && InternetState.from(satisfied: false, realInterfaces: 2) == .offline, "internet state from path")
    check(InternetState.offline.label == "Internet: none" && InternetState.connected.label == "Internet: available, not used" && InternetState.connected.detailsLabel == "Internet available, not used" && InternetState.offline.detailsLabel == "No internet", "dashboard labels")

    // Proof rides on answers and survives sealing round trip (JSON).
    var m = MeshMessage(origin: "Mac", kind: .answer, body: "hi")
    m.proof = p
    m.card = "summary"
    m.personal = ["DEVICE_A": "Your open tasks (1): 1) Order cement"]
    m.suggestions = ["Fix damaged wall at Block 3"]
    let back = try? MeshCodec.decode(MeshCodec.encode(m))
    check(back?.proof == p && back?.card == "summary" && back?.personal?["DEVICE_A"] != nil && back?.suggestions?.count == 1, "proof, card, personal, suggestions encode")
    // An older packet without the fields still decodes.
    let old = #"{"id":"\#(UUID().uuidString)","origin":"x","kind":"answer","body":"b","ttl":7,"hops":["x"],"createdAt":0}"#
    check((try? MeshCodec.decode(Data(old.utf8)))?.proof == nil, "packet without proof decodes")

    var log = ProofLog()
    for i in 0..<25 { log.add(.init(at: Date(), room: "r", kind: "answer", proof: AIProof(mac: "M", model: i % 5 == 0 ? nil : "qwen3:8b", internet: .offline, tokensPerSecond: 10, latencyMs: 1000))) }
    check(log.items.count == 20 && log.averageLatencyMs == 1000 && log.averageTokensPerSecond == 10 && log.allOffline, "proof log keeps 20, averages model answers")

    let ps = #"{"models":[{"name":"qwen3:8b","model":"qwen3:8b","size":6654289920,"digest":"500a1f06","size_vram":6654289920,"expires_at":"2026-10-09T20:00:00+08:00"}]}"#
    let list = RunningModel.decodeList(Data(ps.utf8))
    check(list?.first?.name == "qwen3:8b" && list?.first?.sizeVRAM == 6654289920 && RunningModel.gigabytes(list?.first?.size) == "6.7 GB", "api/ps decode")
    check(OllamaClient.isLoopback(URL(string: "http://127.0.0.1:11434")!) && !OllamaClient.isLoopback(URL(string: "http://example.com")!), "loopback check")

    // AI status carries the internet flag and older status still decodes.
    let st = AIStatus(device: "Mac", state: .awake, model: "qwen3:8b", queue: 0, rooms: [], at: Date(), internet: .offline)
    let enc = try? PasaJSON.encoder.encode(st)
    let dec = enc.flatMap { try? PasaJSON.decoder.decode(AIStatus.self, from: $0) }
    check(dec?.internet.map { $0 == InternetState.offline } == true, "AI status internet round trip")
}

@MainActor
func runDigestTests() async {
    let cal = manilaCalendar()
    // Schedule: first check records only; today due after 5 PM; idempotent; slept-through runs late.
    var book = DigestBook()
    check(DigestClock.due(now: manila(2026, 10, 9, 17, 30), schedule: .standard, book: book, calendar: cal).isEmpty, "first check ever makes nothing")
    book.lastCheckedAt = manila(2026, 10, 9, 16, 59)
    var due = DigestClock.due(now: manila(2026, 10, 9, 17, 0), schedule: .standard, book: book, calendar: cal)
    check(due.count == 1 && due[0].day == "2026-10-09" && !due[0].late, "5:00 PM Manila is due on time")
    book.lastCheckedAt = manila(2026, 10, 9, 16, 0)
    due = DigestClock.due(now: manila(2026, 10, 9, 19, 30), schedule: .standard, book: book, calendar: cal)
    check(due.count == 1 && due[0].late, "Mac asleep at 5 PM: runs on wake, marked late")
    book.lastCheckedAt = manila(2026, 10, 9, 17, 1)
    check(DigestClock.due(now: manila(2026, 10, 9, 18, 0), schedule: .standard, book: book, calendar: cal).isEmpty, "already past the time when last checked: nothing new")
    book.lastCheckedAt = manila(2026, 10, 9, 15, 0)
    due = DigestClock.due(now: manila(2026, 10, 10, 8, 0), schedule: .standard, book: book, calendar: cal)
    check(due.map(\.day) == ["2026-10-09"] && due[0].late, "slept overnight through 5 PM: yesterday's digest on wake")
    check(DigestClock.due(now: manila(2026, 10, 9, 18), schedule: DigestSchedule(enabled: false), book: book, calendar: cal).isEmpty, "disabled schedule")
    check(DigestSchedule(hour: 17).clockLabel == "5:00 PM" && DigestSchedule(hour: 9, minute: 5).clockLabel == "9:05 AM", "clock label")

    // Day log and digest with a fake model.
    var snap = OrgSnapshot()
    let day = DigestClock.dayInterval(of: manila(2026, 10, 9, 12), calendar: cal)
    let rule = RuleEntry(title: "No site visits after 5 PM", body: "Visits end at 5 PM.", addedBy: "Mac", createdAt: manila(2026, 10, 9, 9))
    var old = RuleEntry(title: "Old rule", body: "x", addedBy: "Mac", createdAt: manila(2026, 10, 1, 9))
    old.retired = true; old.retiredAt = manila(2026, 10, 9, 10); old.version = 2
    snap.rules = [rule, old]
    var done = TaskItem(title: "Call supplier", assignee: "Ana", assigneeDevice: "DEV_ANA", createdBy: "Mac", createdAt: manila(2026, 10, 8, 9))
    done.status = .done; done.updatedAt = manila(2026, 10, 9, 11)
    snap.tasks = [done,
                  TaskItem(title: "Order cement", assignee: "Ana", assigneeDevice: "DEV_ANA", due: "Friday", createdBy: "Mac", createdAt: manila(2026, 10, 9, 10)),
                  TaskItem(title: "Sweep", createdBy: "Mac", createdAt: manila(2026, 10, 9, 10))]
    snap.chatLog = [ChatLogLine(from: "Kyle", text: "We move the pour to Tuesday", at: manila(2026, 10, 9, 9), device: "DEV_KYLE"),
                    ChatLogLine(from: "Ana", text: "(voice note) cement truck is late", at: manila(2026, 10, 9, 13), device: "DEV_ANA"),
                    ChatLogLine(from: "Ana", text: "(photo) Cracked wall near Block 3", at: manila(2026, 10, 9, 14), device: "DEV_ANA"),
                    ChatLogLine(from: "Kyle", text: "yesterday line", at: manila(2026, 10, 8, 14), device: "DEV_KYLE")]
    let log = DayLog.build(snap, interval: day)
    check(log.chat.count == 3 && log.media.count == 2 && log.done.count == 1 && log.created.count == 2 && log.rules.count == 2 && !log.isEmpty, "day log picks that day only")

    let fake = FakeLLM([.success(#"{"decisions":["Pour moved to Tuesday [Rule: No site visits after 5 PM v1]","Buy a new crane for the team picnic"]}"#)])
    let d = await DigestWriter.make(room: "r1", label: "BOHOL-7", snapshot: snap, day: "2026-10-09", interval: day, scheduled: true, late: false,
                                    llm: fake, now: manila(2026, 10, 9, 17), calendar: cal, directory: [:])
    check(d.decisions.count == 1 && d.decisions[0].contains("Tuesday") && d.droppedDecisions == 1, "decision not in chat is dropped")
    check(d.done == ["Call supplier (Ana)"] && d.open.first?.person == "Ana" && d.open.last?.person == "Unassigned", "done today and open tasks per person")
    check(d.rules.contains("New: [Rule: No site visits after 5 PM v1]") && d.rules.contains("Rule deleted: Old rule"), "rule changes listed")
    check(d.media.count == 2 && d.media[0].contains("voice note") && d.media[1].contains("photo"), "voice notes and photo checks listed")
    check(d.personal["DEV_ANA"]?.hasPrefix("Your open tasks (1): 1) Order cement (due Friday)") == true && d.personal["DEV_KYLE"] == "You have no open tasks.", "personal lines")
    check(d.text.contains("**Daily summary: BOHOL-7, Fri Oct 9**") && d.text.contains("Pour moved") && !d.text.contains("crane"), "digest text grounded")
    check(fake.received.first?.last?.content.contains("We move the pour") == true && fake.received.first?.last?.content.contains("yesterday line") == false
          && fake.received.first?.last?.content.contains("Cracked wall") == false, "model sees only that day's talk")
    let fake2 = FakeLLM([.success(#"{"decisions":["Pour on Tuesday per [Rule: Pour policy v3]"]}"#)])
    let d2 = await DigestWriter.make(room: "r1", label: "BOHOL-7", snapshot: snap, day: "2026-10-09", interval: day, scheduled: false, late: true,
                                     llm: fake2, now: manila(2026, 10, 9, 19), calendar: cal)
    check(d2.unverified.count == 1 && d2.decisions.first?.contains("(unverified)") == true && d2.text.contains("made late"), "invented rule tag marked unverified; late note")
    let failing = FakeLLM([.failure(.notRunning)])
    let d3 = await DigestWriter.make(room: "r1", label: "R", snapshot: snap, day: "2026-10-09", interval: day, scheduled: true, late: false,
                                     llm: failing, now: Date(), calendar: cal)
    check(!d3.skipped && d3.text.contains("Decisions not read") && d3.done.count == 1, "model down: deterministic parts still sent")
    let quiet = DigestClock.dayInterval(of: manila(2026, 10, 12, 12), calendar: cal)
    let d4 = await DigestWriter.make(room: "r1", label: "R", snapshot: snap, day: "2026-10-12", interval: quiet, scheduled: true, late: false,
                                     llm: FakeLLM([]), now: Date(), calendar: cal)
    check(d4.skipped, "quiet day is skipped")

    // Book is idempotent and persists.
    var b = DigestBook()
    b.record(d); b.record(d2)
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("pasa-digest-\(UUID().uuidString).json")
    check(b.save(url), "digest book saves")
    var loaded = DigestBook.load(url)
    loaded.lastCheckedAt = manila(2026, 10, 9, 16)
    check(loaded.days["2026-10-09"] != nil && loaded.onDemand.count == 1, "digest book reloads")
    check(DigestClock.due(now: manila(2026, 10, 9, 19), schedule: .standard, book: loaded, calendar: cal).isEmpty, "restart after the digest: no duplicate")
    try? FileManager.default.removeItem(at: url)

    // "@pasa summary" through the assistant.
    let mem = OrgMemory(admins: ["Mac"])
    mem.replace(with: snap)
    let a = ExecutiveAssistant(memory: mem, llm: FakeLLM([.success(#"{"decisions":["Pour moved to Tuesday"]}"#)]), selfName: "Mac")
    a.calendar = cal
    a.now = { manila(2026, 10, 9, 15) }
    a.roomLabel = "BOHOL-7"
    let out = await a.handle("summary", from: "DEV_KYLE")
    check(out.intent == .dailySummary && out.digest?.scheduled == false && out.reply.contains("Summary so far: BOHOL-7") && !out.compact, "@libre summary makes an on-demand digest card")
    check(IntentParser.fastPath("recap")?.kind == .summarize && IntentParser.fastPath("buod")?.kind == .dailySummary, "recap stays catch-up, buod is the digest")
}

func runVisionTests() async {
    check(VisionModels.pick(installed: ["qwen3:8b", "qwen2.5-coder:7b"]) == nil, "no vision model installed")
    check(VisionModels.pick(installed: ["qwen3:8b", "qwen3-vl:2b-instruct"]) == VisionModels.fallback, "falls back to the small vision model")
    check(VisionModels.pick(installed: ["qwen3-vl:2b-instruct", "qwen3-vl:4b-instruct"]) == VisionModels.primary, "prefers the default vision model")
    check(VisionModels.pick(installed: ["gemma3:latest"]) == nil && VisionModels.pick(installed: ["gemma3:4b"]) == "gemma3:4b", "accepts an installed alternative")
    check(VisionModels.notInstalledMessage == "Vision model not installed: run ollama pull qwen3-vl:4b-instruct", "not installed message")
    check(VisionPolicy.keepAlive(physicalMemory: 16 << 30) == "30s" && VisionPolicy.keepAlive(physicalMemory: 32 << 30) == "10m", "keep_alive policy by memory")
    check(VisionPolicy.rewarmTextModel(physicalMemory: 16 << 30) && !VisionPolicy.rewarmTextModel(physicalMemory: 64 << 30), "rewarm text model on tight memory")

    let reply = #"{"model":"qwen3-vl:4b-instruct","message":{"role":"assistant","content":"{\"description\":\"A cracked wall near a doorway.\",\"text\":[\"BLOCK 3\"],\"numbers\":[\"3\"],\"tasks\":[\"fix damaged wall at Block 3\"]}"},"done":true,"eval_count":40,"eval_duration":2000000000,"prompt_eval_count":700}"#
    let poster = FakePoster(reply: reply)
    let client = VisionClient(model: VisionModels.primary, keepAlive: "30s", poster: poster)
    let jpeg = Data([0xFF, 0xD8, 0xFF, 0x01, 0x02])
    do {
        let result = try await client.analyze(jpeg: jpeg, caption: "@libre what is this")
        check(poster.urls.first?.absoluteString == "http://127.0.0.1:11434/api/chat", "vision posts to local /api/chat")
        let json = poster.bodies.first.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let messages = json?["messages"] as? [[String: Any]]
        check(json?["model"] as? String == "qwen3-vl:4b-instruct" && json?["stream"] as? Bool == false && json?["format"] as? String == "json"
              && json?["keep_alive"] as? String == "30s", "vision request model, stream, format, keep_alive")
        check((json?["options"] as? [String: Any])?["num_ctx"] as? Int == 4096, "vision num_ctx")
        check(messages?.count == 2 && messages?[0]["role"] as? String == "system" && messages?[0]["images"] == nil, "system turn has no image")
        check((messages?[1]["images"] as? [String]) == [jpeg.base64EncodedString()] && (messages?[1]["content"] as? String)?.contains("Caption from the sender") == true, "image sent as base64 on the user turn")
        check(json?["think"] == nil, "no think flag for instruct vision model")
        let f = VisionPrompt.parse(result.text)
        check(f?.description == "A cracked wall near a doorway." && f?.text == ["BLOCK 3"] && f?.tasks == ["Fix damaged wall at Block 3"], "vision reply parsed")
        check(result.tokensPerSecond == 20 && result.promptEvalCount == 700, "vision timings")
        let rules = [RuleEntry(title: "Report damaged walls", body: "Report any cracked or damaged wall to the foreman.", addedBy: "Mac"),
                     RuleEntry(title: "Lunch", body: "Lunch at noon.", addedBy: "Mac", locked: true)]
        let related = VisionCard.relatedRules(f!, rules: rules)
        check(related.map(\.title) == ["Report damaged walls"], "related rule found by keyword search, locked unrelated rule not forced in")
        let text = VisionCard.text(f!, sender: "Ana", related: related)
        check(text.contains("Possible tasks") && text.contains("1) Fix damaged wall at Block 3") && text.contains("[Rule: Report damaged walls v1]")
              && !text.contains("**") && !text.contains("local model") && !text.contains("Photo from"), "photo answer reads like a normal reply: \(text)")
        check(VisionCard.caution.contains("local model"), "photo caution kept for Details")
        let shown = AnswerStyle.display(body: text, rulesUsed: nil, unverified: nil)
        check(shown.rulesUsed == ["[Rule: Report damaged walls v1]"] && !shown.text.contains("[Rule:"), "photo answer rule tag becomes a chip")
        check(VisionCard.logLine(f!).hasPrefix("(photo) A cracked wall"), "photo log line for digests")
    } catch {
        check(false, "vision analyze threw \(error)")
    }
    do {
        _ = try await VisionClient(poster: FakePoster(reply: #"{"error":"model \"qwen3-vl:4b-instruct\" not found, try pulling it first"}"#, status: 404)).analyze(jpeg: jpeg)
        check(false, "missing model should throw")
    } catch LLMError.modelMissing(let m) {
        check(m == VisionModels.primary, "missing vision model reported")
    } catch { check(false, "wrong error \(error)") }
    do {
        _ = try await VisionClient(baseURL: URL(string: "http://example.com:11434")!, poster: FakePoster(reply: "{}")).analyze(jpeg: jpeg)
        check(false, "remote server should be refused")
    } catch { check(true, "remote vision server refused") }
    check(VisionPrompt.parse("not json at all")?.description == "not json at all" && VisionPrompt.parse("") == nil, "lenient vision parse")
    check(IntentParser.fastPath("what is this")?.kind == .describePhoto && IntentParser.fastPath("ano ito")?.kind == .describePhoto
          && IntentParser.fastPath("unsa ni")?.kind == .describePhoto, "photo questions in English, Tagalog, Cebuano")
    check(IntentParser.fastPath("accept task: Fix damaged wall at Block 3")?.taskTitle == "Fix damaged wall at Block 3", "accept task fast path")
}

@MainActor
func runAcceptTaskTests() async {
    let mem = OrgMemory(admins: ["Mac", "ADMIN_PHONE"])
    let a = ExecutiveAssistant(memory: mem, llm: FakeLLM([]), selfName: "Mac")
    let denied = await a.handle("accept task: Fix wall", from: "OTHER_PHONE")
    check(denied.taskUpdates.isEmpty && denied.reply.contains("Only an admin"), "non-admin cannot accept a suggestion")
    let ok = await a.handle("accept task: Fix damaged wall at Block 3", from: "ADMIN_PHONE")
    check(ok.taskUpdates.first?.title == "Fix damaged wall at Block 3" && ok.taskUpdates.first?.source == "photo", "admin accepts a suggestion")
    let photo = await a.handle("what is this", from: "OTHER_PHONE")
    check(photo.intent == .describePhoto && photo.modelCalls == 0, "photo ask without a photo needs no model call")
}

@MainActor
func runBenchmarkTests() async {
    check(BenchmarkSuite.questions.count == 20, "20 benchmark questions")
    check(BenchmarkSuite.questions.filter { $0.language == "tl" }.count == 6 && BenchmarkSuite.questions.filter { $0.language == "ceb" }.count == 3
          && BenchmarkSuite.questions.filter { $0.expect == .noRule }.count == 4, "language and no-rule mix")
    let rules = BenchmarkSuite.memory().activeRules
    check(rules.count == 10, "10 synthetic rules")
    for q in BenchmarkSuite.questions { if case .cites(let t) = q.expect { check(rules.contains { $0.title == t }, "expected rule exists: \(t)") } }
    let visit = "[Rule: No site visits after 5 PM v1]"
    func sc(_ used: [String], _ unv: [String], _ noRule: Bool?, _ reply: String, _ e: BenchmarkExpectation, intent: String = "answer") -> Bool {
        BenchmarkSuite.score(rulesUsed: used, unverified: unv, noRule: noRule, reply: reply, intent: intent, expect: e, rules: rules).0
    }
    check(sc([visit], [], false, "No, visits end at 5 PM.", .cites("No site visits after 5 PM")), "score: cited via rulesUsed")
    check(!sc([], ["[Rule: Night visits]"], true, "No.", .cites("No site visits after 5 PM")), "score: invented citation fails")
    check(!sc([], [], true, "No visits after 5.", .cites("No site visits after 5 PM")), "score: no citation fails")
    check(!sc(["[Rule: Visitor sign-in v1]"], [], false, "Sign in.", .cites("No site visits after 5 PM")), "score: wrong rule fails")
    check(sc([], [], true, "I don't have the Wi-Fi password saved.", .noRule), "score: no rule, admits it")
    check(sc([], [], true, "Wala akong impormasyon tungkol diyan.", .noRule), "score: no rule, Tagalog admission")
    check(!sc([], [], true, "The password is pasa1234.", .noRule), "score: no rule but invented answer fails")
    check(!sc(["[Rule: Visitor sign-in v1]"], [], false, "I don't know.", .noRule), "score: citing on a no-rule question fails")
    check(!sc([], [], nil, "I don't know.", .noRule), "score: missing noRule flag fails")
    check(!sc([], [], true, "I don't know.", .noRule, intent: "add_task"), "score: routed elsewhere fails")

    // Full run with a fake model. First the run glosses each rule once (RuleGlosser, issue #8),
    // as the AI Mac does when a rule is saved; the smoking rule gets an English wording. Every
    // benchmark question is a plain question, so the intent call is skipped and each question
    // makes exactly one model call.
    var script: [Result<String, LLMError>] = rules.map { r in
        r.title.hasPrefix("Bawal manigarilyo")
            ? .success(#"{"en": "No smoking in or near the cement and paint storage", "tl": "Bawal manigarilyo malapit sa bodega"}"#)
            : .success(#"{"en": "\#(r.title)", "tl": "\#(r.title)"}"#)
    }
    for q in BenchmarkSuite.questions {
        check(QuestionRouter.isPlainQuestion(q.text), "benchmark question skips the intent call: \(q.text)")
        switch q.expect {
        case .cites(let t): script.append(.success("Here is the answer. [Rule: \(t) v1]"))
        case .noRule: script.append(.success("I don't have that info."))
        }
    }
    let fake = FakeLLM(script)
    let results = await BenchmarkSuite.run(llm: fake, model: "fake:1b")
    // #8 (English question, Tagalog-titled rule) used to miss: keyword retrieval never showed the rule to
    // the model. With the rule's gloss it is shown, so its citation is real and becomes a chip.
    check(results.count == 20 && results.allSatisfy(\.correct) && fake.remaining == 0,
          "benchmark run with fake model scores 20/20 (#8 reaches the Tagalog rule through its gloss)")
    check(results.allSatisfy { $0.modelCalls == 1 && $0.tokensPerSecond == 50 }, "benchmark records calls (one per plain question) and speed")
    check(results.filter { if case .cites = $0.question.expect { return true }; return false }.allSatisfy { !$0.reply.contains("[Rule") && $0.rulesUsed.count == 1 }, "benchmark replies carry no tags; rules travel in rulesUsed")
    let csv = BenchmarkReport.csv(results)
    check(csv.split(separator: "\n").count == 21 && csv.hasPrefix("id,language,model,expect,correct"), "benchmark CSV")
    let md = BenchmarkReport.markdown(header: .init(date: "2026-10-09", machine: "test", ollamaVersion: "0", digests: ["fake:1b": "abc"]), runs: [("fake:1b", results)])
    check(md.contains("| fake:1b | 20/20 | 11/11 | 6/6 | 3/3 |"), "benchmark markdown summary row")
    let s = BenchmarkSummary(model: "fake", results: results)
    check(s.correct == 20 && s.byLanguage.count == 3, "benchmark summary")
}

/// Chat-style answers: citation tags become chips, preambles go, plain questions skip the intent call.
@MainActor
func runAnswerStyleTests() async {
    let mem = OrgMemory(admins: ["Mac"])
    _ = mem.upsertRule(title: "No site visits after 5 PM", body: "Site visits end at 5 PM.", by: "Mac")
    _ = mem.upsertRule(title: "Hard hats inside the fence", body: "Wear a hard hat.", by: "Mac")
    let rules = mem.rules
    func st(_ s: String) -> StyledAnswer { AnswerStyle.style(s, rules: rules, notes: []) }

    let end = st("No, visits end at 5 PM. [Rule: No site visits after 5 PM v1]")
    check(end.text == "No, visits end at 5 PM." && end.rulesUsed == ["[Rule: No site visits after 5 PM v1]"] && !end.noRule, "style: trailing tag becomes a chip")
    let inline = st("No, you cannot visit at 6 PM. [Rule: No site visits after 5 PM v1] says site visits end at 5 PM.")
    check(inline.text == "No, you cannot visit at 6 PM. \u{201C}No site visits after 5 PM\u{201D} says site visits end at 5 PM.", "style: tag used as a subject keeps its title: \(inline.text)")
    let mid = st("You cannot visit after 5 PM [Rule: No site visits after 5 PM], and wear a hard hat [Rule: Hard hats inside the fence v1].")
    check(mid.text == "You cannot visit after 5 PM, and wear a hard hat." && mid.rulesUsed.count == 2, "style: inline tags removed cleanly: \(mid.text)")
    let per = st("Per [Rule: No site visits after 5 PM v1], no.")
    check(per.text == "Per \u{201C}No site visits after 5 PM\u{201D}, no.", "style: tag after 'per' keeps its title: \(per.text)")
    let paren = st("No visits after 5 PM ([Rule: No site visits after 5 PM v1]).")
    check(paren.text == "No visits after 5 PM.", "style: parenthesized tag removed: \(paren.text)")
    let dup = st("No. [Rule: No site visits after 5 PM v1] [Rule: No site visits after 5 PM v1]")
    check(dup.rulesUsed.count == 1 && dup.text == "No.", "style: duplicate citations fold into one chip")
    let fake = st("Yes, until 7 PM. [Rule: Night visits allowed v1]")
    check(fake.text == "Yes, until 7 PM." && fake.rulesUsed.isEmpty && fake.unverifiedRules == ["[Rule: Night visits allowed v1]"] && fake.noRule, "style: invented rule goes to unverifiedRules, never rulesUsed")
    let math = st("No saved team rule covers this. General advice, not a team rule: 10+69 equals 79.")
    check(math.text == "10+69 equals 79." && math.noRule, "style: Kyle's 8:33 PM bubble loses both preambles: \(math.text)")
    check(AnswerStyle.title(in: "[Rule: No site visits after 5 PM v2]") == "No site visits after 5 PM" && AnswerStyle.kind(in: "[Note: Monday huddle]") == "Note", "style: chip title and kind")

    // Router
    for q in ["10+69", "12 x 7 = ?", "What is the capital of Japan?", "Can I visit the site at 6 PM?", "It is raining. Can we keep pouring concrete",
              "Pwede ba akong pumunta sa site?", "Unsa orasa ang tanghalian?"] {
        check(QuestionRouter.isPlainQuestion(q), "router: plain question \(q)")
    }
    for q in ["remind Ana to order cement Friday", "save rule: no smoking", "cement order is done", "Can you add a task for Ana?",
              "is the cement task done?", "delete rule night shift", "ipaalala kay Ana ang semento", "Ana will order cement", ""] {
        check(!QuestionRouter.isPlainQuestion(q), "router: goes to the intent call \(q)")
    }
    check(!QuestionRouter.needsTasks("10+69", taskTitles: ["Order cement"]) && QuestionRouter.needsTasks("who is ordering cement?", taskTitles: ["Order cement"]),
          "router: task list only for task questions")

    // End to end: "10+69" is one model call with a lean prompt and a clean reply.
    _ = mem.addTask(title: "Order cement", assignee: "Ana", assigneeDevice: "PHONE_A", due: nil, by: "Mac", source: "ask")
    let llm = FakeLLM([.success("10 + 69 = 79.")])
    let a = ExecutiveAssistant(memory: mem, llm: llm, selfName: "Mac")
    let out = await a.handle("10+69", from: "PHONE_A")
    check(out.modelCalls == 1 && out.skippedClassify && out.reply == "10 + 69 = 79." && out.noRule == true && out.rulesUsed.isEmpty, "e2e: 10+69 one call, clean reply")
    let prompt = llm.received.first?.last?.content ?? ""
    check(!prompt.contains("Open tasks") && !prompt.contains("No saved team rule"), "e2e: lean prompt, no task list, no old marker")
    check(!AssistantPrompts.answerSystem.contains("No saved team rule covers this") && AssistantPrompts.answerSystem.contains("very end"), "prompt: no text markers, citations at the end")

    // Commands still classify first, and rule replies carry a chip instead of a tag.
    let llm2 = FakeLLM([.success(#"{"intent":"save_rule","title":"Gloves for rebar","body":"Wear gloves when handling rebar."}"#)])
    let b = ExecutiveAssistant(memory: mem, llm: llm2, selfName: "Mac")
    let saved = await b.handle("everyone must wear gloves for rebar, remember that", from: "Mac")
    check(saved.intent == .saveRule && saved.modelCalls == 1 && !saved.skippedClassify, "command goes through the intent call")
    check(saved.reply.hasPrefix("Saved.") && saved.rulesUsed == ["[Rule: Gloves for rebar v1]"] && saved.noRule == nil, "save rule reply: chip, no tag: \(saved.reply)")
}

func runChatLayoutTests() {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Asia/Manila")!
    let t0 = Date(timeIntervalSince1970: 1_791_549_180)   // Oct 9 2026, 8:33 PM Manila
    func e(_ origin: String, _ kind: MessageKind, _ at: Date, mine: Bool, sentTo: [String] = ["MAC"], replyTo: UUID? = nil) -> ChatEntry {
        var m = MeshMessage(origin: origin, kind: kind, body: "x", createdAt: at)
        m.replyTo = replyTo
        return ChatEntry(id: m.id, message: m, direction: mine ? .sent : .received, receivedAt: at, sentTo: mine ? sentTo : [])
    }
    let a1 = e("PHONE_A", .chat, t0, mine: false)
    let a2 = e("PHONE_A", .chat, t0 + 30, mine: false)
    let me1 = e("KYLE", .ask, t0 + 60, mine: true)
    let ai = e("MAC", .answer, t0 + 65, mine: false, replyTo: me1.id)
    let me2 = e("KYLE", .chat, t0 + 2000, mine: true, sentTo: [])
    let entries = [a1, a2, me1, ai, me2]
    let answered = AskCoalescer.answered(entries)
    var statuses: [UUID: BubbleStatus] = [:]
    for x in entries { statuses[x.id] = BubbleStatus.of(x, answered: answered, waiting: false) }
    let l = ChatLayout.layout(entries, statuses: statuses, now: t0 + 2100, calendar: cal)
    check(l[a1.id]?.timestamp == "Today 8:33 PM" && l[a1.id]?.showName == true, "layout: first row gets a timestamp and the sender name")
    check(l[a2.id]?.timestamp == nil && l[a2.id]?.showName == false && l[a1.id]?.lastInGroup == false && l[a2.id]?.lastInGroup == true, "layout: same sender groups, name once")
    check(l[me1.id]?.showName == false && l[me1.id]?.statusWord == nil, "layout: never a name for self; status only on the last own message")
    check(l[ai.id]?.showName == true && l[ai.id]?.firstInGroup == true && l[ai.id]?.lastInGroup == true, "layout: Libre AI is its own sender")
    check(l[me2.id]?.timestamp != nil && l[me2.id]?.statusWord == "Queued", "layout: gap over 15 min shows a timestamp; last own message says Queued")
    check(ChatLayout.statusWord(.answered) == "Answered" && ChatLayout.statusWord(.sent) == "Delivered" && ChatLayout.statusWord(.received) == nil, "layout: status words")
    let yesterday = ChatLayout.timestampText(t0 - 86_400, now: t0, calendar: cal)
    let older = ChatLayout.timestampText(t0 - 3 * 86_400, now: t0, calendar: cal)
    check(yesterday == "Yesterday 8:33 PM" && older == "Tue, Oct 6 8:33 PM", "layout: yesterday and older stamps (\(yesterday), \(older))")
    let midnight = e("PHONE_A", .chat, Date(timeIntervalSince1970: 1_791_561_660), mine: false)   // Oct 10 12:01 AM
    let late = e("PHONE_A", .chat, Date(timeIntervalSince1970: 1_791_561_000), mine: false)       // Oct 9 11:50 PM
    let l2 = ChatLayout.layout([late, midnight], statuses: [:], now: t0 + 90_000, calendar: cal)
    check(l2[midnight.id]?.timestamp != nil && l2[midnight.id]?.showName == true, "layout: a new day shows a stamp even within 15 min")

    // Typing
    let pending = ChatLayout.pendingAsks([me1], device: "KYLE", now: t0 + 70)
    check(pending.count == 1 && ChatLayout.pendingAsks(entries, device: "KYLE", now: t0 + 70).isEmpty, "typing: pending until answered")
    check(ChatLayout.pendingAsks([e("KYLE", .ask, t0, mine: true, sentTo: [])], device: "KYLE", now: t0 + 5).isEmpty, "typing: a queued ask shows no dots")
    check(ChatLayout.pendingAsks([me1], device: "KYLE", now: t0 + 3600).isEmpty, "typing: stops after 10 minutes")
    check(TypingState.of(pending: 1, isAIPeer: false, ai: .awake) == .typing && TypingState.of(pending: 0, isAIPeer: false, ai: .awake) == .none, "typing: dots when the Mac is awake")
    check(TypingState.of(pending: 1, isAIPeer: false, ai: .asleep) == .note(TypingState.asleepLine) && TypingState.of(pending: 1, isAIPeer: true, ai: .unknown) == .typing, "typing: asleep line; the Mac itself types")

    // Header
    check(StatusWords.subtitle(linked: 1, nearby: 1, isAIPeer: false, ai: .awake, aiMac: "Kyle's Mac", firstPeer: "Kyle's Mac") == "Kyle's Mac nearby", "header: Mac nearby")
    check(StatusWords.subtitle(linked: 3, nearby: 3, isAIPeer: false, ai: .awake, aiMac: "Kyle's Mac", firstPeer: "Ana") == "Kyle's Mac and 2 more nearby", "header: Mac and more")
    check(StatusWords.subtitle(linked: 0, nearby: 0, isAIPeer: false, ai: .unknown, aiMac: nil, firstPeer: nil) == "No one nearby", "header: no one nearby")
    check(StatusWords.subtitle(linked: 0, nearby: 0, isAIPeer: false, ai: .asleep, aiMac: "Kyle's Mac", firstPeer: nil) == "Kyle's Mac is asleep", "header: Mac asleep")
    check(StatusWords.subtitle(linked: 2, nearby: 2, isAIPeer: true, ai: .unknown, aiMac: nil, firstPeer: "Ana") == "Ana and 1 more nearby", "header: on the Mac")
    check(StatusWords.aiReady(isAIPeer: false, ai: .awake) && !StatusWords.aiReady(isAIPeer: false, ai: .asleep), "header: AI dot")

    // Legacy answers in history display clean.
    let legacy = AnswerStyle.display(body: "No saved team rule covers this. General advice, not a team rule: 10+69 equals 79.", rulesUsed: nil, unverified: nil)
    check(legacy.text == "10+69 equals 79." && legacy.rulesUsed.isEmpty, "display: Kyle's old bubble shows clean")
    let legacy2 = AnswerStyle.display(body: "No. [Rule: No site visits after 5 PM v1] Also [Rule: Night v1] (unverified).", rulesUsed: nil, unverified: nil)
    check(legacy2.rulesUsed == ["[Rule: No site visits after 5 PM v1]"] && legacy2.unverifiedRules == ["[Rule: Night v1]"] && !legacy2.text.contains("["), "display: old tags become chips: \(legacy2.text)")
    let modern = AnswerStyle.display(body: "No, visits end at 5 PM.", rulesUsed: ["[Rule: No site visits after 5 PM v1]"], unverified: nil)
    check(modern.text == "No, visits end at 5 PM." && modern.rulesUsed.count == 1, "display: new answers pass through")
}
