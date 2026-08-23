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
# Run it with SHOTS=1 to regenerate the two screenshots in docs/ that need a
# cluster; everything else in there comes from a SQLite file and tests/shots.sh.
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
# Asked more than once, because a crash-looping pod is not standing still: it
# goes CrashLoopBackOff, restarts into Error, and comes back - so two snapshots
# taken a second apart can disagree about it while both are right. What is being
# checked is that the two agree about a cluster, not that they were asked at the
# same instant.
for _ in $(seq 1 6); do
	mine=$(screen "$ROOT" '{keep}' | sed -n '4,16p' | sed 's/^.*[┃│]//' | awk 'NF >= 3 {print $1, $2, $3}' | sort)
	theirs=$(kubectl -n payments get pods --no-headers | awk '{print $1, $2, $3}' | sort)
	[ "$mine" = "$theirs" ] && break
	sleep 3
done
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

# A shell in a container: the WebSocket, the channel framing and the terminal
# handover, checked by asking the container who it is and believing its answer.
kubectl -n payments run shellme --image=busybox:1.36 --command -- \
	sh -c 'while true; do sleep 30; done' >/dev/null
until [ "$(kubectl -n payments get pod shellme -o jsonpath='{.status.phase}' 2>/dev/null)" = "Running" ]; do
	sleep 2
done
# The shell stays open, which is the whole of it: a command runs where the last
# one left it. `cd` and then `pwd` is the smallest thing that proves it.
inside=$(python3 tests/screen.py "$ROOT" 's' 'EXEC shellme' '{ctrl-s}' '{sleep}' \
	'cd /etc' '{ctrl-s}' '{sleep}' 'pwd' '{ctrl-s}' '{sleep}' '{keep}' 2>&1)
printf '%s' "$inside" | grep -q "/etc" ||
	fail "the shell did not keep where the last command left it"
echo "ok: one shell, and a command runs where the last one left it"

# What it says comes back as rows, and what it exited with is said too.
failed=$(python3 tests/screen.py "$ROOT" 's' 'EXEC shellme' '{ctrl-s}' '{sleep}' \
	'ls /nope' '{ctrl-s}' '{sleep}' '{keep}' 2>&1)
printf '%s' "$failed" | grep -q "No such file" || fail "the shell's output did not come back"
printf '%s' "$failed" | grep -q "exit 1" || fail "a command that failed did not say so"
echo "ok: output comes back as rows, and a non-zero exit is said"

# Enter on a pod opens a screen about that pod, with what can be done to it along
# the bottom - which is the thing somebody at a terminal reaches for first.
opened=$(python3 tests/screen.py "$ROOT" '{tab}' '{enter}' '{sleep}' '{keep}' 2>&1)
printf '%s' "$opened" | grep -q "container" || fail "enter on a pod should open a screen about it"
printf '%s' "$opened" | grep -q "l logs" || fail "the object screen should offer logs"
printf '%s' "$opened" | grep -q "s shell" || fail "the object screen should offer a shell"
echo "ok: enter opens a screen about the pod, with logs and a shell on it"

# And the actions on it are the engine's own console lines.
#
# What the pod actually wrote, not the name of the column it arrives in: a
# listing that came back empty still draws the header, so grepping for that
# passes whether or not there was a log. Asked more than once because the log is
# a round trip to the cluster, and half a second is not a promise.
for _ in $(seq 1 6); do
	logged=$(python3 tests/screen.py "$ROOT" '{tab}' '{enter}' '{sleep}' 'l' '{sleep}' '{sleep}' '{keep}' 2>&1)
	printf '%s' "$logged" | grep -q "listening on" && break
done
printf '%s' "$logged" | grep -q "listening on" || {
	printf '%s\n' "$logged" >&2
	fail "l on the object screen should show the log"
}
echo "ok: l on it shows that pod's log"

# And the terminal is still there for something full screen.
terminal=$(python3 tests/screen.py "$ROOT" 's' 'EXEC -t shellme' '{ctrl-s}' '{sleep}' \
	'echo I-AM-$(hostname)' '{enter}' '{sleep}' '{keep}' 2>&1)
printf '%s' "$terminal" | grep -q "I-AM-shellme" ||
	fail "EXEC -t did not hand the terminal to a shell in the container"
echo "ok: EXEC -t hands the terminal over for something full screen"

# And what it says when the pod is not there, rather than a hung terminal.
#
# `m` because that is where a failed statement puts what went wrong: the line
# along the bottom says how many failed and offers the details, and the details
# are where the name is. This check used to read the bottom line and had not
# been run since it stopped being there.
missing=$(python3 tests/screen.py "$ROOT" 's' 'EXEC nosuchpod' '{ctrl-s}' '{sleep}' 'm' '{sleep}' '{keep}' 2>&1)
printf '%s' "$missing" | grep -qi "nosuchpod" || {
	printf '%s\n' "$missing" >&2
	fail "EXEC on a missing pod should name it"
}
echo "ok: EXEC on a pod that is not there says so"

# A manifest applied from the editor. Typed rather than pasted, so the newlines
# are the carriage returns a terminal really sends.
made=$(python3 tests/screen.py "$ROOT" 's' \
	'APPLY' '{enter}' \
	'apiVersion: v1' '{enter}' \
	'kind: ConfigMap' '{enter}' \
	'metadata:' '{enter}' \
	'  name: made-by-krtek' '{enter}' \
	'data:' '{enter}' \
	'  greeting: hello' '{enter}' \
	'{ctrl-s}' '{sleep}' 'y' '{enter}' '{sleep}' '{keep}' 2>&1)
printf '%s' "$made" | grep -q "created" || fail "APPLY did not create the object"
kubectl -n payments get configmap made-by-krtek >/dev/null 2>&1 ||
	fail "APPLY said it created it and the cluster disagrees"
echo "ok: APPLY makes what the manifest says, and asks first"

# The same one again is a change, not a second one - which is what server-side
# apply is for, and the field manager says who owns it.
again=$(python3 tests/screen.py "$ROOT" 's' \
	'APPLY' '{enter}' \
	'apiVersion: v1' '{enter}' \
	'kind: ConfigMap' '{enter}' \
	'metadata:' '{enter}' \
	'  name: made-by-krtek' '{enter}' \
	'data:' '{enter}' \
	'  greeting: changed' '{enter}' \
	'{ctrl-s}' '{sleep}' 'y' '{enter}' '{sleep}' '{keep}' 2>&1)
printf '%s' "$again" | grep -q "configured" || fail "applying it again should configure, not create"
[ "$(kubectl -n payments get configmap made-by-krtek -o jsonpath='{.data.greeting}')" = "changed" ] ||
	fail "the change did not reach the cluster"
[ "$(kubectl -n payments get configmap made-by-krtek -o jsonpath='{.metadata.managedFields[0].manager}')" = "krtek" ] ||
	fail "the apply was not a server-side apply"
echo "ok: applying it again changes it, and the cluster knows who owns the field"

# And a manifest that is not one says which line it gave up on.
bad=$(python3 tests/screen.py "$ROOT" 's' 'APPLY' '{enter}' 'kind: ConfigMap' '{enter}' \
	'{ctrl-s}' '{sleep}' 'y' '{enter}' '{sleep}' '{keep}' 2>&1)
printf '%s' "$bad" | grep -q "apiVersion" || fail "a document with no apiVersion should say so"
echo "ok: a document that is not a manifest is named rather than sent"

# The screenshots on the website and in the README, which need a cluster with
# something interesting in it - so they are regenerated here rather than in
# tests/shots.sh, where everything else comes from a SQLite file.
if [ -n "${SHOTS:-}" ]; then
	kubectl -n payments create deployment billing --image=busybox:1.36 -- \
		sh -c 'echo starting; echo cannot reach the ledger; exit 1' >/dev/null 2>&1 || true
	printf 'waiting for something to be wrong with'
	until kubectl -n payments get pods --no-headers 2>/dev/null | grep -q CrashLoopBackOff; do
		printf .
		sleep 3
	done
	echo " it"
	SHOT_COLS=104 SHOT_ROWS=14 python3 tests/shot.py docs/kubernetes.svg "$ROOT" '{tab}'
	SHOT_COLS=104 SHOT_ROWS=26 python3 tests/shot.py docs/pod.svg "$ROOT" \
		'{tab}' '{down}{down}{down}' '{enter}' '{wait}'
	echo "ok: docs/kubernetes.svg and docs/pod.svg regenerated"
fi

echo "all good"
