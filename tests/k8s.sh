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
# With its metrics-server, which the other two add-ons are not needed for: what
# a pod is using is a column, and it is measured by nothing else.
docker run -d --name "$NAME" --privileged -p 6443:6443 "$IMAGE" \
	server --disable=traefik --disable=servicelb --tls-san=127.0.0.1 >/dev/null

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
# A pod made by hand is refused until the namespace has its service account,
# which arrives a moment after the namespace does. A deployment's pods are made
# by a controller that tries again; the one bare pod below is not.
until kubectl -n payments get serviceaccount default >/dev/null 2>&1; do sleep 1; done
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
# One that holds on to thirty megabytes, among pods that hold on to none. What a
# pod is using is read from another place than the pod and matched to it by name,
# and a list where every pod uses the same would look right with them shuffled.
apiVersion: v1
kind: Pod
metadata: {name: hungry, namespace: payments}
spec:
  containers:
  - name: hungry
    image: busybox:1.36
    command: ["sh","-c","x=$(head -c 30000000 /dev/zero | tr '\\0' a); while true; do sleep 30; done"]
    resources:
      requests: {cpu: 50m, memory: 48Mi}
      limits: {memory: 256Mi}
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

# And the grid alone: the sidebar and the rule that divides it off come first on
# every line. The rule is spelled as the two it can be and not as a set of them,
# because a sed that reads bytes reads such a set as a set of bytes - and the
# first byte of a rule is the first byte of the squares a pod's containers are
# drawn as, so everything up to the last square on the line went with it.
grid() {
	sed -E 's/^.*(┃|│)//'
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
# The broken pod has to have settled into CrashLoopBackOff as well, and not
# merely into whatever both happen to see: it goes Error between restarts, and
# two views agreeing on Error is agreement about a state the checks below are
# not about.
# The status is the seventh thing on a row here and the third on kubectl's: what
# a pod is using, how often it has restarted and how old it is come before it. A
# cell with nothing in it still says NULL, so the count holds.
#
# And what kubectl writes as 1/2 is drawn here as a square a container, filled
# for one that is ready and hollow for one that is not - so counting the two
# kinds gives kubectl's two numbers back, which is what is compared.
for _ in $(seq 1 10); do
	mine=$(screen "$ROOT" '{keep}' | sed -n '4,16p' | grid |
		awk 'NF >= 7 {
			drawn = $2
			up = gsub(/▪/, "", drawn)
			down = gsub(/▫/, "", drawn)
			# Anything left over is not a square, and is shown as it came so
			# that the comparison fails on it rather than counting past it.
			print $1, (drawn == "" ? up "/" (up + down) : $2), $7
		}' | sort)
	theirs=$(kubectl -n payments get pods --no-headers | awk '{print $1, $2, $3}' | sort)
	if [ "$mine" = "$theirs" ] && printf '%s' "$theirs" | grep -q CrashLoopBackOff; then
		break
	fi
	sleep 3
done
[ -n "$theirs" ] || fail "kubectl listed no pods, so there is nothing to compare against"
if [ "$mine" != "$theirs" ]; then
	echo "--- krtek:"   >&2; printf '%s\n' "$mine"   >&2
	echo "--- kubectl:" >&2; printf '%s\n' "$theirs" >&2
	fail "the pod list does not match kubectl"
fi
echo "ok: the pod list matches kubectl, name for name and state for state"

# The squares themselves, and not only their count: every pod of the deployment
# that works is one filled square, and the one that keeps dying is a hollow one.
# Asked more than once, for the pod of the three that is last to be ready.
for _ in $(seq 1 6); do
	squares=$(screen "$ROOT" '{keep}' | grid |
		awk '$1 ~ /^(api|broken)-/ {print substr($1, 1, 3), $2}' | sort -u)
	[ "$squares" = "$(printf 'api ▪\nbro ▫')" ] && break
	sleep 3
done
[ "$squares" = "$(printf 'api ▪\nbro ▫')" ] || {
	printf '%s\n' "$squares" >&2
	fail "a ready container should be a filled square and one that is not a hollow one"
}
echo "ok: a container is a square, filled where it is ready and hollow where it is not"

# The two states that are not the phase, which is the whole point of the column.
printf '%s' "$mine" | grep -q CrashLoopBackOff || fail "a crash-looping pod should not read as Running"
printf '%s' "$mine" | grep -q Completed || fail "a finished pod should not read as Succeeded"
echo "ok: a broken pod says CrashLoopBackOff and a finished one says Completed"

# The whole value of a cell is that cell's. `gv` asks the engine again for the
# one column the cursor is on and shows the first cell of what comes back - and
# what came back had every column in it, so the box said `status` along the top
# and the pod's name inside. The status of the first pod, then, against what
# kubectl says of that pod; asked more than once for the reason the list above
# is.
#
# The column is found by its name and not by counting to it. It was the third,
# and two presses of right were how to get there, until what a pod is using was
# put in front of it: the box then said `cpu`, this looked for one that said
# `status`, and found nothing. And nothing is not allowed to be the answer on
# both sides - a pod kubectl says nothing about and a box that is not there
# were equal, and that was a pass: which is what this was on a Mac, where the
# sidebar was taken off the line by the sed `grid` is there to replace, and the
# name of the pod came out as two bytes of a square.
first=$(screen "$ROOT" '{keep}')
pod=$(printf '%s\n' "$first" | sed -n '4p' | grid | awk '{print $1}')
[ -n "$pod" ] || fail "there is no first pod to ask the whole value of"
steps=$(printf '%s\n' "$first" | sed -n '3p' | grid |
	awk '{for (i = 1; i <= NF; i++) if ($i == "status") print i - 1}')
[ -n "$steps" ] || fail "the pod list has no column called status to ask the whole value of"
right=''
for _ in $(seq 1 "$steps"); do
	right="$right{right}"
done
for _ in $(seq 1 6); do
	whole=$(python3 tests/screen.py "$ROOT" '{tab}' "$right" 'g' 'v' '{sleep}' '{keep}' 2>&1 |
		grep -A1 'status ─ enter/esc closes' | tail -1 | sed 's/ *│ *$//; s/^.*│ //')
	theirs=$(kubectl -n payments get pod "$pod" --no-headers | awk '{print $3}')
	[ -n "$theirs" ] && [ "$whole" = "$theirs" ] && break
	sleep 3
done
[ -n "$theirs" ] || fail "kubectl says nothing about $pod, so there is nothing to compare its status with"
[ "$whole" = "$theirs" ] || fail "gv on the status of $pod should show $theirs, and shows '$whole'"
echo "ok: gv shows the value under the cursor, and not the name of its row"

# A namespace is picked from a list: `#`, a few letters of its name, and enter.
# It was a form with one field in it, turned with the arrows a namespace at a
# time - which on a cluster with thirty of them is the long way to the one whose
# name was known all along.
listed=$(screen "$ROOT" '#')
printf '%s' "$listed" | grep -q "─ namespace ─" || { printf '%s\n' "$listed" >&2; fail "# should open the list of namespaces"; }
printf '%s' "$listed" | grep -q "payments .* now" || { printf '%s\n' "$listed" >&2; fail "the namespace in force should say so in the list"; }
moved=$(screen "$ROOT" '#' 'kube-sy' '{enter}')
printf '%s' "$moved" | grep -q "NAMESPACE kube-system" || { printf '%s\n' "$moved" >&2; fail "enter in the list should move to the namespace that was typed"; }
printf '%s' "$moved" | grep -q "coredns" || { printf '%s\n' "$moved" >&2; fail "the pods listed are not the ones of the namespace that was picked"; }
echo "ok: # lists the namespaces, and enter moves to the one that was typed"

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
#
# Asked more than once: the container's own state arrives after the pod's, so a
# pod opened the moment it exists has a screen with everything but that on it.
for _ in $(seq 1 6); do
	opened=$(python3 tests/screen.py "$ROOT" '{tab}' '{enter}' '{sleep}' '{keep}' 2>&1)
	printf '%s' "$opened" | grep -q "container" && break
	sleep 2
done
printf '%s' "$opened" | grep -q "container" || {
	printf '%s\n' "$opened" >&2
	fail "enter on a pod should open a screen about it"
}
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

# S shows one object of the kind whole, under a line that says what it is one of.
# The line is written before the object, so the way this breaks is the object
# landing on top of it.
structure=$(python3 tests/screen.py "$ROOT" 'S' '{sleep}' '{keep}' 2>&1)
printf '%s' "$structure" | grep -q "# one pod, as the cluster holds it" || {
	printf '%s\n' "$structure" >&2
	fail "the structure view should say what its object is one of"
}
printf '%s' "$structure" | grep -q '"metadata"' || {
	printf '%s\n' "$structure" >&2
	fail "the structure view should show the object itself"
}
echo "ok: S shows one pod whole, under the line that says it is one"

# The kinds a cluster has that Kubernetes does not. k3s ships four definitions of
# its own, which is what makes this checkable without installing anything: their
# columns come out of the definition, the way kubectl gets them.
# In kube-system, which is where k3s keeps them - `$ROOT` is the payments
# namespace and a kind is listed in the namespace being looked at.
crd=$(python3 tests/screen.py "k8s://default/kube-system" 's' 'GET addons' '{ctrl-s}' '{sleep}' '{keep}' 2>&1)
printf '%s' "$crd" | grep -q "coredns" || {
	printf '%s\n' "$crd" >&2
	fail "a custom resource should list like any other kind"
}
# `source` is a column the definition asks for, not one this program knows about.
printf '%s' "$crd" | grep -q "source" || {
	printf '%s\n' "$crd" >&2
	fail "a custom resource should take its columns from its own definition"
}
echo "ok: a custom kind lists, with the columns its definition asks for"

# Helm keeps a release as a secret of its own type, so this reads without
# unzipping anything. Installed here where there is a helm to install it with -
# the check is the same either way: the kind answers rather than erroring.
if command -v helm >/dev/null 2>&1; then
	work=$(mktemp -d)
	mkdir -p "$work/templates"
	printf 'apiVersion: v2\nname: pokus\nversion: 0.1.0\n' > "$work/Chart.yaml"
	printf 'apiVersion: v1\nkind: ConfigMap\nmetadata: {name: pokus-config}\ndata: {a: b}\n' > "$work/templates/cm.yaml"
	helm install pokus "$work" -n payments >/dev/null 2>&1
	helm upgrade pokus "$work" -n payments >/dev/null 2>&1
	rm -rf "$work"
	out=$(python3 tests/screen.py "$ROOT" 's' 'GET releases' '{ctrl-s}' '{sleep}' '{keep}' 2>&1)
	# Two revisions, and only the second is the one installed.
	printf '%s' "$out" | grep -q "superseded" && printf '%s' "$out" | grep -q "deployed" || {
		printf '%s\n' "$out" >&2
		fail "a helm release should show its revisions and which one is installed"
	}
	echo "ok: helm releases are read out of the secrets helm keeps them in"
else
	# A statement that failed leaves the editor open over what the engine said,
	# so the editor still being there is what a failure looks like.
	out=$(python3 tests/screen.py "$ROOT" 's' 'GET releases' '{ctrl-s}' '{sleep}' '{keep}' 2>&1)
	printf '%s' "$out" | grep -q "\[INSERT\]\|failed" && fail "GET releases should answer even where there is nothing to list"
	echo "ok: helm releases answer on a cluster with none (no helm to install one)"
fi

# Eighteen kinds is more than a list, so the list down the side is divided the
# way a cluster is: workloads, then network, then config, then storage, access
# and the cluster's own. Heading lines take room, so what is really being
# checked is that moving over them still lands where the cursor says it does.
# A window tall enough for the whole list: there are more kinds than a default
# terminal has rows, and a heading below the edge is not a heading that is
# missing.
side=$(SCREEN_ROWS=48 python3 tests/screen.py "$ROOT" '{sleep}' '{keep}' 2>&1)
for heading in workloads network config storage access helm cluster custom; do
	printf '%s' "$side" | grep -qE "^ $heading *\|" || printf '%s' "$side" | grep -q " $heading " || {
		printf '%s\n' "$side" >&2
		fail "the list should be divided, and should have a $heading heading"
	}
done
echo "ok: the kinds are divided the way a cluster is"

# Moving down lands on the kind the cursor is on, whatever headings were drawn
# between. How far down `namespaces` is comes from the list itself rather than
# from a number written here: a count in a test is a count that goes stale the
# next time a kind is added, which is what happened the first time.
at=$(printf '%s' "$side" | grep -nE '^ (▪|~) ' | grep -n 'namespaces' | cut -d: -f1)
test -n "$at" || fail "namespaces should be somewhere in the list"
down=""
i=1
while [ $i -lt "$at" ]; do down="$down{down}"; i=$((i + 1)); done

# On a window too short to hold the list, so it has scrolled as well.
out=$(SCREEN_ROWS=14 python3 tests/screen.py "$ROOT" "{sleep}$down{enter}{sleep}{keep}" 2>&1)
printf '%s' "$out" | grep -q "namespaces  1-" || {
	printf '%s\n' "$out" >&2
	fail "moving down past the headings should land on the kind the cursor is on"
}
echo "ok: the cursor counts kinds, not the lines drawn between them"

# A cluster that is far away. The handshake is several round trips and the socket
# has a short receive timeout on it, so OpenSSL says "want read" while the first
# flight is still in the air - which is not a failure and used to be read as one.
# Asked once, a cluster a third of a second away could not be reached at all.
#
# The delay goes on the k3s container's own interface, from a sidecar that shares
# its network. Skipped where that will not run rather than failed: this is about
# krtek, and a machine that cannot shape traffic has nothing to say about it.
if docker run --rm --net=container:"$NAME" --cap-add=NET_ADMIN alpine:3.22 \
	sh -c 'apk add -q iproute2 && tc qdisc add dev eth0 root netem delay 300ms' >/dev/null 2>&1
then
	out=$(python3 tests/screen.py "$ROOT" '{sleep}' '{sleep}' '{sleep}' '{sleep}' '{keep}' 2>&1 || true)
	docker run --rm --net=container:"$NAME" --cap-add=NET_ADMIN alpine:3.22 \
		sh -c 'apk add -q iproute2 && tc qdisc del dev eth0 root' >/dev/null 2>&1
	printf '%s' "$out" | grep -q "handshake failed" && {
		printf '%s\n' "$out" >&2
		fail "a cluster 300ms away should still connect"
	}
	printf '%s' "$out" | grep -q "Kubernetes v1" || {
		printf '%s\n' "$out" >&2
		fail "a cluster 300ms away should still answer"
	}
	echo "ok: a cluster far enough away to outlast the read timeout still connects"
else
	echo "ok: (no way to add latency here, so nothing to say about a far cluster)"
fi

# What the cluster is made of. Every number here comes out of the API for
# nothing extra - what a node has left to place pods in, and what the pods on it
# asked for - so it works on a cluster with no add-ons at all.
summary=$(python3 tests/screen.py "$ROOT" 's' 'CLUSTER' '{ctrl-s}' '{sleep}' '{keep}' 2>&1)
for expected in "version" "nodes" "cpu" "memory" "pods" "cpu requested"; do
	printf '%s' "$summary" | grep -q "$expected" || {
		printf '%s\n' "$summary" >&2
		fail "CLUSTER should say $expected"
	}
done
# Against kubectl, which is the yardstick everywhere else in this file.
nodes=$(kubectl get nodes --no-headers | wc -l | tr -d ' ')
printf '%s' "$summary" | grep -q "ready of $nodes" || {
	printf '%s\n' "$summary" >&2
	fail "CLUSTER should count the nodes kubectl counts"
}
echo "ok: CLUSTER says what the cluster is and what is spoken for"

# What the pods are using, which is what their cpu and memory columns say. It is
# metrics-server that knows, and it takes a minute after a cluster comes up to
# have measured anything - so this waits for kubectl to be told first.
printf 'waiting for the pods to be measured'
for _ in $(seq 1 90); do
	kubectl -n payments top pod hungry --no-headers >/dev/null 2>&1 &&
		kubectl -n payments top pod shellme --no-headers >/dev/null 2>&1 && break
	printf .
	sleep 2
done
echo " measured"
kubectl -n payments top pod hungry --no-headers >/dev/null 2>&1 ||
	fail "metrics-server never measured the pods, so there is nothing to compare against"

# One row of the pod list, by the pod's name, without the sidebar in front of it.
row_of() {
	printf '%s\n' "$1" | grid | awk -v pod="$2" '$1 ~ "^" pod {print; exit}'
}

# Against kubectl, to the megabyte. Asked more than once: the two are read a
# moment apart, and a measurement taken in between is a different measurement.
for _ in $(seq 1 6); do
	listed=$(screen "$ROOT" '{keep}')
	mine=$(row_of "$listed" hungry | awk '{print $4}')
	theirs=$(kubectl -n payments top pod hungry --no-headers | awk '{print $3}')
	near=$(awk -v a="${mine%Mi}" -v b="${theirs%Mi}" 'BEGIN {d = a - b; print (d > -2 && d < 2) ? "yes" : "no"}')
	case "$mine" in *Mi) [ "$near" = "yes" ] && break ;; esac
	sleep 3
done
case "$mine" in *Mi) ;; *) printf '%s\n' "$listed" >&2; fail "a pod's memory should be what it is using, in units somebody reads" ;; esac
[ "$near" = "yes" ] || fail "hungry is using $theirs by kubectl and $mine here"
echo "ok: a pod's memory is what kubectl top says it is using ($mine)"

# And it is that pod's, not a neighbour's: the one holding thirty megabytes says
# more than twenty, and one that only sleeps says less than ten. What hungry
# asked for is 48Mi, which is what this column used to say.
[ "$(awk -v a="${mine%Mi}" 'BEGIN {print (a > 20 && a != 48) ? "yes" : "no"}')" = "yes" ] ||
	fail "hungry should say what it is using ($mine), which is more than 20Mi and is not its request"
other=$(row_of "$listed" shellme | awk '{print $4}')
case "$other" in
	*Ki|[0-9].[0-9]Mi) ;;
	*) printf '%s\n' "$listed" >&2; fail "a pod that only sleeps should not be using $other" ;;
esac
row_of "$listed" hungry | awk '{print $3}' | grep -qE '^[0-9]+m?$' || {
	printf '%s\n' "$listed" >&2
	fail "a pod's cpu should be what it is using, in cores or thousandths of one"
}
echo "ok: and it is that pod's own, not its neighbour's"

# A pod that has finished is not measured, and says nothing rather than zero.
row_of "$listed" migrate | awk '{print $3, $4}' | grep -q '^NULL NULL$' || {
	printf '%s\n' "$listed" >&2
	fail "a pod that is not running should say nothing about what it is using"
}
echo "ok: a pod nobody is measuring says nothing, rather than using none"

# And what puts a pod back when it is deleted, which is in the pod: a job's pod
# says Job and a deployment's says ReplicaSet, as kubectl describe would.
for pod in migrate api; do
	name=$(row_of "$listed" "$pod" | awk '{print $1}')
	mine=$(row_of "$listed" "$pod" | awk '{print $8}')
	theirs=$(kubectl -n payments get pod "$name" -o jsonpath='{.metadata.ownerReferences[0].kind}')
	[ -n "$theirs" ] && [ "$mine" = "$theirs" ] || {
		printf '%s\n' "$listed" >&2
		fail "$name is controlled by a $theirs, and here it says $mine"
	}
done
echo "ok: a pod says what controls it"

# Put in order by how much, the hungriest is on top - which as text it would not
# be: every pod here that says Ki sorts after one that says 30.1Mi.
sorted=$(python3 tests/screen.py "$ROOT" '{tab}' '{right}' '{right}' '{right}' \
	'o' '{sleep}' 'o' '{sleep}' '{keep}' 2>&1)
printf '%s' "$sorted" | grep -q "order memory desc" || {
	printf '%s\n' "$sorted" >&2
	fail "o twice on the memory column should order by it, largest first"
}
[ "$(printf '%s\n' "$sorted" | sed -n '4p' | grid | awk '{print $1}')" = "hungry" ] || {
	printf '%s\n' "$sorted" >&2
	fail "ordered by memory, the pod using the most should come first"
}
echo "ok: ordered by memory, the pod using the most comes first"

# What it asked for and what it is limited to are on the screen about it, under
# what it is using - which is where the grid's old two columns went.
about=$(python3 tests/screen.py "$ROOT" '{tab}' '{right}' '{right}' '{right}' \
	'o' '{sleep}' 'o' '{sleep}' '{enter}' '{sleep}' '{keep}' 2>&1)
for expected in "memory  [0-9.]*Mi" "memory asked  48.0Mi" "memory limit  256.0Mi" "cpu asked  50m"; do
	printf '%s' "$about" | grep -q "$expected" || {
		printf '%s\n' "$about" >&2
		fail "the screen about a pod should say: $expected"
	}
done
echo "ok: the screen about a pod says what it uses, what it asked for and its limit"

# A node's row carries what it has room for.
row=$(python3 tests/screen.py "$ROOT" 's' 'GET nodes' '{ctrl-s}' '{sleep}' '{keep}' 2>&1)
printf '%s' "$row" | grep -qE 'cpu +memory +pods' || {
	printf '%s\n' "$row" >&2
	fail "a node should say what it has left for pods"
}
echo "ok: a node says what it has left to place pods in"

# A log is read across, not down: the one column it has takes the room nobody
# else wants, rather than the width a table column is clipped to.
kubectl -n payments delete pod tikac --ignore-not-found >/dev/null 2>&1
kubectl -n payments run tikac --image=busybox:1.36 --restart=Never -- \
	sh -c 'i=1; while [ $i -le 200 ]; do echo "radek $i - dost dlouhy radek, aby se poznalo, jestli se orizne nebo ne"; i=$((i+1)); done; sleep 3600' >/dev/null
for _ in $(seq 1 30); do
	[ "$(kubectl -n payments get pod tikac -o jsonpath='{.status.phase}' 2>/dev/null)" = "Running" ] && break
	sleep 2
done

wide=$(python3 tests/screen.py "$ROOT" 's' 'LOGS tikac' '{ctrl-s}' '{sleep}' '{keep}' 2>&1)
printf '%s' "$wide" | grep -q "jestli se orizne nebo ne" || {
	printf '%s\n' "$wide" >&2
	fail "a log line should have the width of the screen, not of a table column"
}
echo "ok: a log line is as wide as there is room for"

# And it says when each line was written. The kubelet knows, and a log read
# against a request somebody is chasing is a log with the clock on it.
printf '%s' "$wide" | grep -qE '[0-9][0-9]:[0-9][0-9]:[0-9][0-9]\.[0-9][0-9][0-9] radek' || {
	printf '%s\n' "$wide" >&2
	fail "a log line should carry the time it was written"
}
echo "ok: a log line carries the time it was written"

# And following one shows its end. A log opened at line one and followed from
# there grows at the end nobody is looking at.
#
# Two hundred lines, which is more than any screen this runs on: a log shorter
# than the window has no end to scroll to and would pass whatever this did.
# Not through `screen`: that helper takes five keys and this needs the waiting
# after `R` as well.
followed=$(python3 tests/screen.py "$ROOT" 's' 'LOGS tikac' '{ctrl-s}' '{sleep}' \
	'R' '{sleep}' '{sleep}' '{sleep}' '{keep}' 2>&1)
first=$(printf '%s' "$followed" | grep -o 'radek [0-9]*' | head -1 | awk '{print $2}')
test -n "$first" && [ "$first" -gt 1 ] || {
	printf '%s\n' "$followed" >&2
	fail "following a log should show the end of it, not the beginning"
}
echo "ok: following a log shows the end of it"

kubectl -n payments delete pod tikac --ignore-not-found >/dev/null 2>&1

# And the terminal is still there for something full screen.
terminal=$(python3 tests/screen.py "$ROOT" 's' 'EXEC -t shellme' '{ctrl-s}' '{sleep}' \
	'echo I-AM-$(hostname)' '{enter}' '{sleep}' '{keep}' 2>&1)
printf '%s' "$terminal" | grep -q "I-AM-shellme" ||
	fail "EXEC -t did not hand the terminal to a shell in the container"
echo "ok: EXEC -t hands the terminal over for something full screen"

# And what it says when the pod is not there, rather than a hung terminal.
#
# What went wrong is under the statement, in the editor that stays open over a
# run that failed, and its first line is along the bottom. It was behind `gm`
# before that, and on the bottom line before that.
missing=$(python3 tests/screen.py "$ROOT" 's' 'EXEC nosuchpod' '{ctrl-s}' '{sleep}' '{keep}' 2>&1)
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
	# With this pod, not with any pod. `broken` has been failing since the top of
	# this script, so waiting for a failure was over before it began - and the
	# shot was of a list in which billing was still being created.
	until kubectl -n payments get pods --no-headers 2>/dev/null |
		grep '^billing' | grep -q 'CrashLoopBackOff\|Error'; do
		printf .
		sleep 3
	done
	echo " it"
	# How far down the list it is comes from the list, for the reason the
	# namespaces above do: the pods in front of it are however many the checks
	# before this one left running, and three presses of `down` stopped being
	# billing the day one of them scaled a deployment.
	at=$(kubectl -n payments get pods --no-headers | awk '{print $1}' | LC_ALL=C sort |
		grep -n '^billing' | cut -d: -f1 | head -1)
	test -n "$at" || fail "billing should be in the list of pods"
	down=""
	i=1
	while [ $i -lt "$at" ]; do down="$down{down}"; i=$((i + 1)); done
	SHOT_COLS=104 SHOT_ROWS=14 python3 tests/shot.py docs/kubernetes.svg "$ROOT" '{tab}'
	SHOT_COLS=104 SHOT_ROWS=26 python3 tests/shot.py docs/pod.svg "$ROOT" \
		'{tab}' "$down" '{enter}' '{wait}'
	echo "ok: docs/kubernetes.svg and docs/pod.svg regenerated"
fi

# And a cluster may not know any of what its pods are using. This one stops
# knowing here - the API that metrics-server answers at is taken away, which is
# why this is last - so what is checked is that TOP says so rather than answering
# zero, which is the difference between "idle" and "nobody is measuring".
kubectl delete apiservice v1beta1.metrics.k8s.io >/dev/null
for _ in $(seq 1 30); do
	kubectl top nodes >/dev/null 2>&1 || break
	sleep 1
done
out=$(python3 tests/screen.py "$ROOT" 's' 'TOP nodes' '{ctrl-s}' '{sleep}' 'gm' '{sleep}' '{keep}' 2>&1)
printf '%s' "$out" | grep -q "no metrics-server" || {
	printf '%s\n' "$out" >&2
	fail "TOP on a cluster without metrics-server should say so"
}
echo "ok: TOP says when there is nothing measuring, rather than answering zero"

# The list of pods still opens there, with every pod in it and nothing made up.
unmeasured=$(screen "$ROOT" '{keep}')
row_of "$unmeasured" hungry | awk '{print $3, $4, $7}' | grep -q '^NULL NULL Running$' || {
	printf '%s\n' "$unmeasured" >&2
	fail "without metrics-server a pod should be listed, with nothing said about what it uses"
}
echo "ok: without metrics-server the pods are still listed, and their usage is empty"

echo "all good"
