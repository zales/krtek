#!/bin/sh
# Bring up a Kubernetes and check the driver against it:
#
#     zig build && ./tests/k8s.sh
#
# k3s in a container, because it is a whole cluster in one image and it hands out
# a kubeconfig with a certificate authority of its own and a client certificate -
# which is exactly the pair a driver has to get right and the pair no unit test
# can prove. A namespace with something worth looking at in it, and then the three
# ways in: the admin's client certificate, a service account's bearer token, and
# an exec credential plugin, since that last one is how nearly every cloud cluster
# authenticates and the one most likely to be broken by a change here.
#
# What is compared is this program against kubectl, column for column, because
# kubectl is the yardstick everybody already has in their head: a pod that says
# Running here and CrashLoopBackOff there is a driver that reads the phase and
# calls a broken pod healthy.
set -e
cd "$(dirname "$0")/.."

NAME=${NAME:-krtek-k3s-test}
IMAGE=${IMAGE:-rancher/k3s:v1.31.5-k3s1}
WORK=$(mktemp -d)
trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT

BIN=zig-out/bin/krtek
test -x "$BIN" || { echo "$BIN is not there - zig build first" >&2; exit 1; }
command -v kubectl >/dev/null || { echo "kubectl is the yardstick here and is not installed" >&2; exit 1; }

echo "starting $IMAGE"
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" --privileged -p 6443:6443 "$IMAGE" \
	server --disable=traefik --disable=servicelb --disable=metrics-server --tls-san=127.0.0.1 >/dev/null

export KUBECONFIG="$WORK/kubeconfig"
printf 'waiting for the cluster'
for _ in $(seq 1 90); do
	docker exec "$NAME" cat /etc/rancher/k3s/k3s.yaml > "$KUBECONFIG" 2>/dev/null || true
	if [ -s "$KUBECONFIG" ] && kubectl get nodes >/dev/null 2>&1; then break; fi
	printf .
	sleep 2
done
kubectl get nodes >/dev/null 2>&1 || { echo " the cluster never came up" >&2; exit 1; }
echo " up"

kubectl create namespace payments >/dev/null
kubectl apply -f - >/dev/null <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata: {name: api, namespace: payments}
spec:
  replicas: 3
  selector: {matchLabels: {app: api}}
  template:
    metadata: {labels: {app: api}}
    spec:
      containers:
      - name: api
        image: busybox:1.36
        command: ["sh","-c","echo listening on :8080; while true; do sleep 30; done"]
---
# One that never starts, because a pod list whose broken pod says Running is the
# mistake this whole check exists for.
apiVersion: apps/v1
kind: Deployment
metadata: {name: broken, namespace: payments}
spec:
  replicas: 1
  selector: {matchLabels: {app: broken}}
  template:
    metadata: {labels: {app: broken}}
    spec:
      containers:
      - name: broken
        image: busybox:1.36
        command: ["sh","-c","exit 1"]
---
apiVersion: v1
kind: Service
metadata: {name: api, namespace: payments}
spec:
  selector: {app: api}
  ports: [{port: 80, targetPort: 8080}]
---
apiVersion: v1
kind: ConfigMap
metadata: {name: api-settings, namespace: payments}
data: {LOG_LEVEL: debug}
---
# A job that finishes, which kubectl calls Completed and the phase calls Succeeded.
apiVersion: batch/v1
kind: Job
metadata: {name: migrate, namespace: payments}
spec:
  template:
    spec:
      restartPolicy: Never
      containers: [{name: migrate, image: "busybox:1.36", command: ["sh","-c","echo done"]}]
YAML

printf 'waiting for the workloads'
for _ in $(seq 1 60); do
	crashing=$(kubectl -n payments get pods --no-headers 2>/dev/null | grep -c CrashLoopBackOff || true)
	done_pod=$(kubectl -n payments get pods --no-headers 2>/dev/null | grep -c Completed || true)
	[ "$crashing" -ge 1 ] && [ "$done_pod" -ge 1 ] && break
	printf .
	sleep 2
done
echo " ready"

# The other two ways in, built from the cluster's own certificate authority.
CA=$(grep certificate-authority-data "$KUBECONFIG" | awk '{print $2}')
kubectl -n payments create serviceaccount viewer >/dev/null
kubectl create rolebinding viewer-can-view --clusterrole=view \
	--serviceaccount=payments:viewer -n payments >/dev/null
TOKEN=$(kubectl -n payments create token viewer --duration=2h)

# Deliberately written in flow style: it is legal YAML, kubectl reads it, and
# people write kubeconfigs like this by hand.
cat > "$WORK/by-token" <<YAML
apiVersion: v1
kind: Config
current-context: by-token
clusters:
- cluster: {certificate-authority-data: $CA, server: "https://127.0.0.1:6443"}
  name: k3s
contexts:
- context: {cluster: k3s, namespace: payments, user: viewer}
  name: by-token
users:
- name: viewer
  user: {token: $TOKEN}
YAML

cat > "$WORK/plugin.sh" <<'PLUGIN'
#!/bin/sh
printf '{"kind":"ExecCredential","apiVersion":"client.authentication.k8s.io/v1beta1","status":{"token":"%s"}}\n' "$KRTEK_TEST_TOKEN"
PLUGIN
chmod +x "$WORK/plugin.sh"
cat > "$WORK/by-plugin" <<YAML
apiVersion: v1
kind: Config
current-context: by-plugin
clusters:
- cluster:
    certificate-authority-data: $CA
    server: https://127.0.0.1:6443
  name: k3s
contexts:
- context:
    cluster: k3s
    namespace: payments
    user: plugin
  name: by-plugin
users:
- name: plugin
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1beta1
      command: $WORK/plugin.sh
      env:
      - name: KRTEK_TEST_TOKEN
        value: $TOKEN
YAML

# --- and now the driver ---

fail() { echo "FAIL: $1" >&2; exit 1; }

check() {
	what=$1
	target=$2
	wanted=$3
	table=$4
	out=$(zig build dbcheck -- "$target" $table 2>&1 || true)
	printf '%s' "$out" | grep -q "$wanted" || {
		echo "--- what came back:" >&2
		printf '%s\n' "$out" >&2
		fail "$what"
	}
	echo "ok: $what"
}

# The screen, for the things that are about what a person sees.
screen() {
	python3 tests/screen.py "$1" "$2" "$3" "$4" "$5" '{sleep}' '{keep}' 2>&1
}

ROOT=k8s://default/payments

check "the admin's client certificate gets in" "$ROOT" "Kubernetes v1.31"
check "a resource kind is a table" "$ROOT" "table .pods" pods
check "a pod is addressed by its name" "$ROOT" "row key: name (usable=true)" pods
check "a namespace is a schema, and the context's comes first" "$ROOT" "^schema payments"
check "a bearer token gets in" "k8s://?kubeconfig=$WORK/by-token" "Kubernetes v1.31"
check "a kubeconfig written in flow style is read" "k8s://?kubeconfig=$WORK/by-token" "Kubernetes v1.31"
check "an exec credential plugin gets in" "k8s://?kubeconfig=$WORK/by-plugin" "Kubernetes v1.31"
check "a context that is not there says which ones are" "k8s://staging" "there is no context called staging"

# kubectl is the yardstick: the same pods, the same states, from both.
# The sidebar and the rule that divides it off come first on every line; the grid
# is whatever follows the rule.
mine=$(screen "$ROOT" '{keep}' | sed -n '4,16p' | sed 's/^.*[┃│]//' | awk 'NF >= 3 {print $1, $2, $3}' | sort)
theirs=$(kubectl -n payments get pods --no-headers | awk '{print $1, $2, $3}' | sort)
[ -n "$theirs" ] || fail "kubectl listed no pods, so there is nothing to compare against"
if [ "$mine" != "$theirs" ]; then
	echo "--- krtek:"   >&2; printf '%s\n' "$mine"   >&2
	echo "--- kubectl:" >&2; printf '%s\n' "$theirs" >&2
	fail "the pod list does not match kubectl"
fi
echo "ok: the pod list matches kubectl, name for name and state for state"

# The two states that are not the phase, which is the whole point of the column.
printf '%s' "$mine" | grep -q CrashLoopBackOff || fail "a crash-looping pod should not read as Running"
printf '%s' "$mine" | grep -q Completed || fail "a finished pod should not read as Succeeded"
echo "ok: a broken pod says CrashLoopBackOff and a finished one says Completed"

# Writing: the two things this driver does, checked against the cluster itself.
screen "$ROOT" 's' 'SCALE deployments api 5' '{ctrl-s}' >/dev/null
sleep 2
[ "$(kubectl -n payments get deploy api -o jsonpath='{.spec.replicas}')" = "5" ] ||
	fail "SCALE did not reach the cluster"
echo "ok: SCALE moves a deployment's replicas"

screen "$ROOT" 's' 'RESTART deployments api' '{ctrl-s}' >/dev/null
sleep 2
kubectl -n payments get deploy api -o jsonpath='{.spec.template.metadata.annotations}' |
	grep -q krtek.restartedAt || fail "RESTART did not annotate the template"
echo "ok: RESTART rolls a deployment the way kubectl does"

asked=$(python3 tests/screen.py "$ROOT" '{tab}' 'x' '{sleep}' '{keep}' 2>&1)
printf '%s' "$asked" | grep -q "type y to delete" || fail "x should ask before deleting an object"
echo "ok: x asks before deleting, because nothing takes that back"

echo "all good"
