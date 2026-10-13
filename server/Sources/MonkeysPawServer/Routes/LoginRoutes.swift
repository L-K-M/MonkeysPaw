import Hummingbird
import HTTPTypes
import MonkeysPawCore

struct LoginRoutes {
    let login: LoginService
    let trustedProxies: TrustedProxies

    func add(to router: Router<ServerRequestContext>) {
        let forwardedFor = HTTPField.Name("X-Forwarded-For")!
        router.post("/api/v1/auth/login") { request, context in
            let body = try await context.requestDecoder.decode(SyncAPI.LoginRequest.self, from: request, context: context)
            let ip = try trustedProxies.clientIP(peer: context.remoteAddress, forwardedFor: request.headers[values: forwardedFor])
            let response = try await login.login(body, ip: ip)
            return try context.responseEncoder.encode(response, from: request, context: context)
        }
    }
}
