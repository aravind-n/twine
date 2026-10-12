import XCTest

extension TwineUITests {
    @MainActor
    func testTerminalRunsLibraryInjectionAndDebugger() throws {
        let folder = try makeTestFolder(prefix: "TwineRuntime")
        try writeRuntimeFixtures(in: folder)
        try runtimeScript().write(to: folder.appending(path: "runtime.sh"), atomically: true, encoding: .utf8)
        let app = try makeApp(lastOpenFolder: folder)
        app.launchEnvironment["SHELL"] = "/bin/sh"
        app.launch()
        XCTAssertTrue(app.buttons["workflowTab-1"].waitForExistence(timeout: 10), app.debugDescription)
        app.typeText("/bin/sh runtime.sh > runtime.log 2>&1\r")
        let completed = expectation(
            for: NSPredicate { _, _ in
                FileManager.default.fileExists(atPath: folder.appending(path: "runtime.complete").path)
            }, evaluatedWith: nil)
        wait(for: [completed], timeout: 60)
        let output = try String(contentsOf: folder.appending(path: "runtime.log"), encoding: .utf8)
        for marker in [
            "CHILD_INJECTION_OK", "CHILD_LIBRARY_OK", "stop reason = breakpoint", "DEBUGGER_OK", "TERMINAL_RUNTIME_OK",
        ] {
            XCTAssertTrue(output.contains(marker), output)
        }
        if ProcessInfo.processInfo.environment["TWINE_TEST_NODE"] != nil {
            XCTAssertTrue(output.contains("CHILD_JIT_OK"), output)
        }
        let attachment = XCTAttachment(string: output)
        attachment.name = "Terminal runtime probes"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
    }

    private func writeRuntimeFixtures(in folder: URL) throws {
        try """
        int twine_runtime_answer(void) { return 42; }
        """.write(to: folder.appending(path: "library.c"), atomically: true, encoding: .utf8)
        try """
        #include <dlfcn.h>
        #include <stdio.h>
        #include <stdlib.h>
        int main(void) {
            if (getenv("TWINE_REQUIRE_INJECTION")) {
                if (!dlsym(RTLD_DEFAULT, "twine_runtime_answer")) return 3;
                puts("CHILD_INJECTION_OK");
            }
            void *library = dlopen("./library.dylib", RTLD_NOW);
            if (!library) { puts(dlerror()); return 1; }
            int (*answer)(void) = dlsym(library, "twine_runtime_answer");
            if (!answer || answer() != 42) return 2;
            puts("CHILD_LIBRARY_OK");
            return 0;
        }
        """.write(to: folder.appending(path: "program.c"), atomically: true, encoding: .utf8)
        try """
        let sum = 0;
        for (let i = 0; i < 1000000; i++) sum += i;
        if (sum !== 499999500000) process.exit(1);
        console.log("CHILD_JIT_OK");
        """.write(to: folder.appending(path: "jit.js"), atomically: true, encoding: .utf8)
    }

    private func runtimeScript() -> String {
        var script = """
            set -eu
            trap 'touch runtime.complete' EXIT
            xcrun clang -dynamiclib library.c -o library.dylib
            xcrun clang -g -O0 program.c -o program
            set +e
            TWINE_REQUIRE_INJECTION=1 ./program
            rejected=$?
            set -e
            [ "$rejected" -eq 3 ]
            TWINE_REQUIRE_INJECTION=1 DYLD_INSERT_LIBRARIES="$PWD/library.dylib" ./program
            xcrun lldb --batch -o 'breakpoint set --name main' -o run -o continue ./program
            echo DEBUGGER_OK
            """
        if let node = ProcessInfo.processInfo.environment["TWINE_TEST_NODE"] {
            let quotedNode = "'" + node.replacingOccurrences(of: "'", with: "'\\''") + "'"
            script += "\n\(quotedNode) jit.js"
        }
        return script + "\necho TERMINAL_RUNTIME_OK\n"
    }
}
