// IntentTests.swift: fast paths and lenient decoding of model JSON.

import Foundation

func runIntentTests() {
    // Fast paths.
    let save = IntentParser.fastPath("save rule: no site visits after 5 PM")
    check(save?.kind == .saveRule && save?.title == "No site visits after 5 PM" && save?.body == "no site visits after 5 PM", "save rule fast path derives title")
    let skill = IntentParser.fastPath("Save skill Concrete mix: 1 cement, 2 sand, 3 gravel")
    check(skill?.kind == .saveRule && skill?.ruleKind == .skill && skill?.title == "Concrete mix" && skill?.body == "1 cement, 2 sand, 3 gravel", "skill with title")
    check(IntentParser.fastPath("update rule No site visits after 5 PM: after 6 PM")?.kind == .editRule, "edit rule fast path")
    check(IntentParser.fastPath("What did I miss?")?.kind == .summarize, "what did I miss")
    check(IntentParser.fastPath("my tasks")?.kind == .listMyTasks, "my tasks")
    check(IntentParser.fastPath("Team tasks")?.kind == .listTeamTasks, "team tasks")
    check(IntentParser.fastPath("more")?.kind == .more, "more")
    let lock = IntentParser.fastPath("lock rule No site visits after 5 PM")
    check(lock?.kind == .lockRule && lock?.title == "No site visits after 5 PM", "lock rule")
    check(IntentParser.fastPath("unlock rule Hard hats")?.kind == .unlockRule, "unlock rule")
    check(IntentParser.fastPath(String(repeating: "Ana said we pour concrete Monday. ", count: 25))?.kind == .takeNotes, "long text means notes")
    check(IntentParser.fastPath("notes: Ben will fix the generator by Tuesday and we agreed to start at 7.")?.kind == .takeNotes, "notes prefix")
    check(IntentParser.fastPath("remind Ana to order cement Friday") == nil, "natural task goes to the model")
    check(IntentParser.fastPath("save rule") == nil, "empty rule is not a fast path")

    // Lenient model decoding.
    let fenced = "Sure!\n```json\n{\"intent\": \"add_task\", \"task_title\": \"order cement\", \"assignee\": \"Ana\", \"due\": \"Friday\", \"title\": null}\n```"
    let plan = IntentParser.decodePlan(from: fenced, original: "remind Ana to order cement Friday")
    check(plan.kind == .addTask && plan.taskTitle == "order cement" && plan.assignee == "Ana" && plan.due == "Friday" && plan.title == nil, "code fence and nulls")
    let alias = IntentParser.decodePlan(from: #"{"intent":"Remind","task":"buy nails","due":5}"#, original: "x")
    check(alias.kind == .addTask && alias.taskTitle == "buy nails" && alias.due == "5", "aliases and numbers")
    check(IntentParser.decodePlan(from: "no json here", original: "hello?").kind == .answer, "garbage falls back to answer")
    check(IntentParser.decodePlan(from: #"{"intent":"dance"}"#, original: "q").kind == .answer, "unknown intent falls back to answer")
    let rule = IntentParser.decodePlan(from: #"{"intent":"save rule","body":"Wear boots on site"}"#, original: "x")
    check(rule.kind == .saveRule && rule.title == "Wear boots on site", "rule title derived when missing")
    let ask = IntentParser.decodePlan(from: #"{"intent":"answer","question":""}"#, original: "Can we pour at night?")
    check(ask.question == "Can we pour at night?", "empty question uses original")

    let notesJSON = #"{"title":"Monday huddle","summary":"Pour moved.","decisions":["Pour on Tuesday"],"action_items":[{"title":"order cement","assignee":"Ana","due":"Friday"},"call supplier",{"title":""}]}"#
    let notes = IntentParser.decodeNotes(from: notesJSON)
    check(notes?.title == "Monday huddle" && notes?.decisions == ["Pour on Tuesday"], "notes decode")
    check(notes?.actionItems.count == 2 && notes?.actionItems.first?.assignee == "Ana", "action items decode, blanks dropped")
    check(IntentParser.decodeNotes(from: "{}") == nil, "empty notes rejected")

    // Ollama request shaping.
    check(OllamaClient.usesThinking("qwen3:8b") && !OllamaClient.usesThinking("llama3.2:3b"), "thinking models detected")
    check(!OllamaClient.usesThinking("qwen3:4b-instruct"), "instruct variant gets no think flag")
    let prepared = OllamaClient.prepare([.system("s"), .user("hi")], model: "qwen3:4b")
    check(prepared[1].content.hasPrefix("/no_think\n") && prepared[0].content == "s", "/no_think added to user turns only")
    check(OllamaClient.prepare([.user("hi")], model: "llama3.2")[0].content == "hi", "non-qwen untouched")
    check(OllamaClient.stripThinking("<think>\nhmm\n</think>\n\nAnswer") == "Answer", "think block stripped")
    let request = OllamaClient.ChatRequest(model: "qwen3:8b", messages: [.user("hi")], stream: false, think: false, format: nil,
                                           options: .init(temperature: 0.2, num_ctx: 8192), keep_alive: "30m")
    let json = String(data: (try? JSONEncoder().encode(request)) ?? Data(), encoding: .utf8) ?? ""
    check(json.contains("\"think\":false") && json.contains("\"stream\":false") && !json.contains("format"), "request has think false, no format when not JSON")
    let response = #"{"model":"qwen3:8b","message":{"role":"assistant","content":"ok"},"done":true,"total_duration":2000000000,"eval_count":40,"eval_duration":2000000000}"#
    let decoded = try? JSONDecoder().decode(OllamaClient.ChatResponse.self, from: Data(response.utf8))
    check(decoded?.eval_count == 40 && decoded?.message?.content == "ok", "response decodes")
    let result = LLMResult(text: "ok", model: "qwen3:8b", evalCount: 40, evalDurationNs: 2_000_000_000)
    check(result.tokensPerSecond == 20, "tokens per second = eval_count / eval_duration")
    check(LLMError.notRunning.errorDescription?.hasPrefix("Start Ollama on the Mac") == true, "clear not-running message")
}
