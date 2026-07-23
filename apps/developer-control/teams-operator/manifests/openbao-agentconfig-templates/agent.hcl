# OpenBao Agent config for namespace {{ NAMESPACE }} - the sidecar that logs
# into OpenBao using the JWT-SVID spiffe-helper writes to /shared/spiffe-jwt,
# then proxies API calls on 127.0.0.1:8207 with the resulting token attached
# automatically (api_proxy.use_auto_auth_token). The app container just
# calls that local address - no token handling in app code. Syntax verified
# against `bao agent` (OpenBao 2.5.5) directly before committing this -
# OpenBao is Vault-Agent-config-compatible, confirmed rather than assumed.
pid_file = "/shared/openbao-agent.pid"

vault {
  address = "http://openbao.openbao.svc.cluster.local:8200"
}

auto_auth {
  method "jwt" {
    mount_path = "auth/jwt"
    config = {
      role = "team-{{ NAMESPACE }}"
      path = "/shared/spiffe-jwt"
      remove_jwt_after_reading = false
    }
  }

  sink "file" {
    config = {
      path = "/shared/bao-token"
    }
  }
}

api_proxy {
  use_auto_auth_token = true
}

listener "tcp" {
  address     = "127.0.0.1:8207"
  tls_disable = true
}
