import HaloFoundation
import MatrixRustSDK
import Synchronization

/// Process-wide SDK initialisation (SDK_INTEGRATION §2). Safe to call more than once.
public enum MatrixBootstrap {
    private static let done = Mutex(false)

    static func tracingConfiguration() -> TracingConfiguration {
        TracingConfiguration(
            logLevel: .warn, traceLogPacks: [], extraTargets: [],
            writeToStdoutOrSystem: false, writeToFiles: nil, sentryConfig: nil
        )
    }

    /// Initialises the SDK's tracing and runtime once per process. Nothing is written to stdout:
    /// SDK logs can contain identifiers (SECURITY §6); a privacy-reviewed sink arrives with HaloPlatform.
    /// - Parameter lightweightRuntime: a single-threaded Tokio runtime, for the notification extension's memory budget
    ///   (V-NSE-3). Only the first call in a process decides.
    public static func initialise(lightweightRuntime: Bool = false) throws(HaloError) {
        let result: Result<Void, HaloError> = done.withLock { isDone in
            guard !isDone else { return .success(()) }
            do { try initPlatform(config: tracingConfiguration(), useLightweightTokioRuntime: lightweightRuntime) } catch {
                return .failure(ErrorMapper.map(error))
            }
            isDone = true
            return .success(())
        }
        try result.get()
    }
}
