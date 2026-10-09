// AssistantPrompts.swift
// Libre: prompts for the local model. Short on purpose: small models follow short prompts better,
// and replies must fit small mesh packets.

import Foundation

enum AssistantPrompts {
    static func classify(rules: [RuleEntry], people: [String], openTasks: [TaskItem]) -> String {
        let ruleTitles = rules.prefix(30).map { $0.title }.joined(separator: "; ")
        let taskTitles = openTasks.prefix(20).map { $0.title }.joined(separator: "; ")
        return """
        You route messages for Libre, the offline executive assistant of a work team.
        Pick exactly one intent and extract fields. Reply with one JSON object only, no prose:
        {"intent": "...", "title": "", "body": "", "kind": "rule", "task_title": "", "assignee": "", "due": "", "task_ref": "", "question": ""}
        Intents:
        - save_rule: the user shares a rule, policy, procedure or skill for the team to remember. title = short name, body = the rule, kind = rule or skill.
        - edit_rule: the user changes an existing rule. title = the existing rule's title, body = new text.
        - lock_rule / unlock_rule: title = rule title.
        - add_task: a to-do, reminder or assignment. task_title = the action in a few words, assignee = person or device (empty if none, "me" if the sender), due = when, as said.
        - list_my_tasks: the sender asks for their own tasks.
        - list_team_tasks: asks for everyone's tasks or the team to-do list.
        - mark_done: a task is finished. task_ref = words that identify the task.
        - summarize: what did I miss, catch me up, recap the chat.
        - take_notes: a transcript or meeting notes to turn into decisions and action items.
        - answer: any other question or request. question = the question.
        Known rules: \(ruleTitles.isEmpty ? "none" : ruleTitles)
        Known people and devices: \(people.isEmpty ? "none" : people.joined(separator: "; "))
        Open tasks: \(taskTitles.isEmpty ? "none" : taskTitles)
        Example: "remind Ana to order cement on Friday" -> {"intent":"add_task","task_title":"Order cement","assignee":"Ana","due":"Friday"}
        Example: "cement order is done" -> {"intent":"mark_done","task_ref":"cement order"}
        Example: "can we visit the site at 6 PM?" -> {"intent":"answer","question":"can we visit the site at 6 PM?"}
        """
    }

    static func classifyUser(text: String, asker: String) -> String {
        "Sender: \(asker)\nMessage: \(text)"
    }

    static let answerSystem = """
    You are Libre, the concise offline executive assistant of a work team.
    Use the team knowledge when it is relevant and cite every item you rely on exactly as written in square brackets, for example [Rule: No site visits after 5 PM v2] or [Note: Monday huddle].
    Rules marked locked are binding. If the knowledge does not cover the question, say so in a few words, then give your best short general answer.
    Plain text, no markdown, at most 3 short sentences.
    """

    static func answerUser(question: String, asker: String, rules: [RuleEntry], notes: [Note], openTasks: [TaskItem]) -> String {
        var lines: [String] = ["Team knowledge:"]
        if rules.isEmpty && notes.isEmpty { lines.append("(none saved yet)") }
        for rule in rules.prefix(40) {
            lines.append("\(rule.citation)\(rule.locked ? " (locked)" : "") \(rule.body.prefix(400))")
        }
        for note in notes.suffix(8) {
            let decisions = note.decisions.isEmpty ? "" : " Decisions: " + note.decisions.joined(separator: "; ")
            lines.append("\(note.citation) \(note.summary.prefix(300))\(decisions.prefix(300))")
        }
        if !openTasks.isEmpty {
            lines.append("")
            lines.append("Open tasks:")
            for task in openTasks.prefix(15) { lines.append("- \(task.shortLine)") }
        }
        lines.append("")
        lines.append("Question from \(asker): \(question)")
        return lines.joined(separator: "\n")
    }

    static let summarizeSystem = """
    You catch up a teammate who missed the team chat.
    Write at most 3 short lines, each starting with "- ". Say who said what, and include decisions, requests and times. No preamble, no markdown headings.
    """

    static func summarizeUser(lines: [ChatLogLine], asker: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let body = lines.map { "[\(formatter.string(from: $0.at))] \($0.from): \($0.text.prefix(300))" }.joined(separator: "\n")
        return "Catch up \(asker). Team chat, oldest first:\n\(body)"
    }

    static func notesSystem(people: [String]) -> String {
        """
        Turn a meeting transcript or long message into team notes. Reply with one JSON object only:
        {"title": "short title", "summary": "one sentence", "decisions": ["..."], "action_items": [{"title": "action in a few words", "assignee": "person or empty", "due": "when or empty"}]}
        Only include decisions and action items that are actually in the text. Known people and devices: \(people.isEmpty ? "none" : people.joined(separator: "; "))
        """
    }
}
