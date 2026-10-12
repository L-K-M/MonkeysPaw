/// Serial, nonblocking work away from the platform's UI thread (§4.2).
///
/// Drivers run each submitted closure exactly once, in submission order. A
/// serial dispatch queue is suitable on either desktop; Linux never hops to
/// the dispatch main queue. Services deliver results through MainThread.
/// Tests may execute inline or hold work until explicitly released.
public protocol BackgroundWork {
    func run(_ work: @escaping () -> Void)
}
