kubectl -n openbao exec openbao-0 -- sh -c \
  'BAO_ADDR=http://127.0.0.1:8200 bao operator init -key-shares=5 -key-threshold=3 -format=json' \
  > init-keys.json   # already git-ignored (init-keys.json*)


# Unseal now, interactively (needs 3 of the 5 keys) — the watcher below only
# handles *future* seals, it doesn't do this first one for you.
kubectl -n openbao exec openbao-0 -- sh -c \
  "BAO_ADDR=http://127.0.0.1:8200 bao operator unseal $(jq -r '.unseal_keys_b64[0]' init-keys.json)"
kubectl -n openbao exec openbao-0 -- sh -c \
  "BAO_ADDR=http://127.0.0.1:8200 bao operator unseal $(jq -r '.unseal_keys_b64[1]' init-keys.json)"
kubectl -n openbao exec openbao-0 -- sh -c \
  "BAO_ADDR=http://127.0.0.1:8200 bao operator unseal $(jq -r '.unseal_keys_b64[2]' init-keys.json)"

# Create the unseal-keys Secret the watcher consumes (threshold = 3 keys).
# --ignore-not-found so a fresh cluster (Secret not yet created) doesn't error;
# the delete only matters on a re-run where an old Secret must be replaced.
kubectl delete secret openbao-unseal-keys -n openbao --ignore-not-found
kubectl -n openbao create secret generic openbao-unseal-keys \
  --from-literal=UNSEAL_KEY_1="$(jq -r '.unseal_keys_b64[0]' init-keys.json)" \
  --from-literal=UNSEAL_KEY_2="$(jq -r '.unseal_keys_b64[1]' init-keys.json)" \
  --from-literal=UNSEAL_KEY_3="$(jq -r '.unseal_keys_b64[2]' init-keys.json)"
