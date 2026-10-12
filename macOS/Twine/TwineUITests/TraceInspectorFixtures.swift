import XCTest

extension TwineUITests {
    func writeInspectorNativeHistory(in folder: URL) throws {
        let project = folder.appending(path: "native/projects/fixture")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let records: [[String: Any]] = [
            [
                "type": "assistant", "uuid": "block-a", "sessionId": "inspector-fixture", "promptId": "inspect",
                "requestId": "native-response", "timestamp": "2026-10-08T10:00:00.000Z",
                "message": [
                    "id": "message", "model": "fixture-model",
                    "content": [
                        [
                            "type": "text",
                            "text": "Public summary\n" + String(repeating: "☃ Full recorded response\n", count: 300),
                        ]
                    ], "usage": ["input_tokens": 120, "output_tokens": 30],
                ],
            ],
            [
                "type": "assistant", "uuid": "block-b", "sessionId": "inspector-fixture", "promptId": "inspect",
                "requestId": "native-response", "timestamp": "2026-10-08T10:00:01.000Z",
                "message": [
                    "id": "message", "model": "fixture-model",
                    "content": [["type": "text", "text": "END-OF-FULL-RESPONSE"]], "usage": ["output_tokens": 32],
                ],
            ],
            [
                "type": "system", "uuid": "compact", "sessionId": "inspector-fixture", "promptId": "inspect",
                "subtype": "compact_boundary", "timestamp": "2026-10-08T10:00:02.000Z",
                "compactMetadata": ["trigger": "auto"],
            ],
        ]
        let lines =
            try records.map { record in
                try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: record), encoding: .utf8))
            }.joined(separator: "\n") + "\n"
        try lines.write(to: project.appending(path: "inspector-fixture.jsonl"), atomically: true, encoding: .utf8)
    }

    func inspectorFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(
            path: "TwineInspectorUITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func inspectorEvents() -> [[String: Any]] {
        var events: [[String: Any]] = [
            ["hook_event_name": "UserPromptSubmit", "prompt": "Inspect parallel coding work"],
            ["hook_event_name": "SubagentStart", "agent_id": "review", "agent_type": "Reviewer"],
            ["hook_event_name": "SubagentStart", "agent_id": "tests", "agent_type": "Test runner"],
            [
                "hook_event_name": "PreToolUse", "agent_id": "review", "tool_use_id": "read", "tool_name": "Read",
                "tool_input": ["file_path": "src/main.rs"],
            ],
            [
                "hook_event_name": "PreToolUse", "agent_id": "tests", "tool_use_id": "test", "tool_name": "Bash",
                "tool_input": ["command": "cargo test"],
            ],
            [
                "hook_event_name": "PostToolUse", "agent_id": "review", "tool_use_id": "read", "tool_name": "Read",
                "tool_input": ["file_path": "src/main.rs"], "tool_response": "fn main() {}",
            ],
            [
                "hook_event_name": "PostToolUseFailure", "agent_id": "tests", "tool_use_id": "test",
                "tool_name": "Bash", "tool_input": ["command": "cargo test"], "error": "fixture test failure",
            ],
            [
                "hook_event_name": "SubagentStop", "agent_id": "review", "agent_type": "Reviewer",
                "last_assistant_message": "Review complete",
            ],
            [
                "hook_event_name": "SubagentStop", "agent_id": "tests", "agent_type": "Test runner",
                "last_assistant_message": "Failure reported",
            ],
        ]
        for index in 0..<24 {
            let command = index == 23 ? "printf final-tool" : "printf tool-\(index)"
            for event in ["PreToolUse", "PostToolUse"] {
                events.append([
                    "hook_event_name": event, "tool_use_id": "tool-\(index)", "tool_name": "Bash",
                    "tool_input": ["command": command], "tool_response": "recorded output \(index)",
                ])
            }
        }
        events.append(["hook_event_name": "Stop", "last_assistant_message": "Inspection complete"])
        return events
    }

    func writeInspectorAgent(in folder: URL) throws {
        let lines =
            try inspectorEvents().map { event in
                var event = event
                event["session_id"] = "inspector-fixture"
                event["prompt_id"] = "inspect"
                return try XCTUnwrap(
                    String(
                        data: JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]), encoding: .utf8))
            }.joined(separator: "\n") + "\n"
        try lines.write(to: folder.appending(path: "inspector-events.jsonl"), atomically: true, encoding: .utf8)
        try #"""
        case "$1" in --help) exit 0 ;; esac
        if [ -f inspector-ready ]; then while :; do sleep 1; done; fi
        while [ "$#" -gt 0 ]; do
            if [ "$1" = --settings ]; then settings="$2"; break; fi
            shift
        done
        hook=$(/usr/bin/plutil -extract hooks.UserPromptSubmit.0.hooks.0.command raw -o - "$settings")
        stty -echo
        printf '❯ Inspect parallel coding work\n'
        while IFS= read -r event; do
            printf '%s' "$event" | /bin/sh -c "$hook"
            printf 'recorded native hook\n'
        done < inspector-events.jsonl
        printf 'ready\n' > inspector-ready
        while :; do sleep 1; done
        """#.write(to: folder.appending(path: "inspector-stub.txt"), atomically: true, encoding: .utf8)
    }
}
