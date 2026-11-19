import HaloFoundation
import MatrixRustSDK
import Synchronization

/// Process-wide SDK initialisation (SDK_INTEGRATION §2). Safe to call more than once.
public enum MatrixBootstrap {
    private static let done = Mutex(false)

    /// Initialises the SDK's tracing and runtime once per process. Nothing is written to stdout:
    /// SDK logs can contain identifiers (SECURITY §6); a privacy-reviewed sink arrives with HaloPlatform.
    public static func initialise() throws(HaloError) {
        let result: Result<Void, HaloError> = done.withLock { isDone in
            guard !isDone else { return .success(()) }
            let config = TracingConfiguration(
                logLevel: .warn, traceLogPacks: [], extraTargets: [],
                writeToStdoutOrSystem: false, writeToFiles: nil, sentryConfig: nil
            )
            do { try initPlatform(config: config, useLightweightTokioRuntime: false) } catch {
                return .failure(ErrorMapper.map(error))
            }
            isDone = true
            return .success(())
        }
        try result.get()
    }
}
