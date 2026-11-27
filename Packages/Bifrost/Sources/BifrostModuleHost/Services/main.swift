import BifrostModuleHostCore
import BifrostModuleHostSandbox
import Foundation

// The module host runs one add-on module's JavaScript and talks JSON lines with its parent on
// stdin and stdout. The order below is the point of the file: the JIT and WebAssembly go off
// before anything starts JavaScriptCore, the sandbox goes on before any input is read, and the
// self-test proves the sandbox works before the hello goes out.

// Nothing may come before these two. JavaScriptCore reads its options when its first context
// starts, and a clean fallback when the hardened runtime refuses the JIT isn't documented.
setenv("JSC_useJIT", "0", 1)
setenv("JSC_useWasm", "0", 1)

guard bifrost_enter_sandbox(SandboxProfile.text) == 0 else { HostExit.sandboxFailed.end() }

// The hello carries the real outcomes even when the self-test fails, so the parent can say which
// probe got through.
let selfTest = SelfTestProbe.run()
HostOutput.send(.hello(selfTest))
guard selfTest.passed else { HostExit.selfTestFailed.end() }

let engine = ModuleEngine()
Thread { [engine] in LineReader.run(handingTo: engine) }.start()
dispatchMain()
