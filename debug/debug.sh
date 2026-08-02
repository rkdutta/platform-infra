kubectl -n engineering-platform exec -it deployments/teams-operator -c teams-operator -- cat /operator-shared/spiffe-jwt | jwt decode -
export VAULT_ADDR="https://openbao.127.0.0.1.sslip.io:8443/"
vault login --method=oidc -tls-skip-verify
vault auth list -tls-skip-verify
vault list -tls-skip-verify auth/jwt/role
vault read -tls-skip-verify auth/jwt/role/teams-operator-admin
vault policy list -tls-skip-verify
vault policy read -tls-skip-verify teams-operator-admin-policy