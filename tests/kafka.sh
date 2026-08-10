#!/bin/sh
# Bring up a Kafka that has everything the driver has to cope with, and check the
# driver against it:
#
#     zig build && ./tests/kafka.sh
#
# One broker in KRaft mode with four listeners - plain, SASL, SASL over TLS, and
# an internal one for Kafka's own tools - a topic in every compression codec, a
# PLAIN user and a SCRAM user. Then dbcheck against each way in, because that is
# the interface without the interface on top.
#
# Kafka's own tools do the writing on purpose: the records krtek reads are then
# ones the Java client wrote, compression framing and all, rather than ones this
# program made for itself.
set -e
cd "$(dirname "$0")/.."

NAME=${NAME:-krtek-kafka-test}
IMAGE=${IMAGE:-apache/kafka:3.9.0}
WORK=$(mktemp -d)
trap 'docker rm -f "$NAME" >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT

BIN=zig-out/bin/krtek
test -x "$BIN" || { echo "$BIN is not there - zig build first" >&2; exit 1; }

# The broker's own login information: PLAIN comes from this file, SCRAM from a
# credential created once the cluster is up.
cat > "$WORK/jaas.conf" <<'EOF'
KafkaServer {
  org.apache.kafka.common.security.plain.PlainLoginModule required
    username="admin"
    password="admin-secret"
    user_admin="admin-secret"
    user_alice="alice-secret";
  org.apache.kafka.common.security.scram.ScramLoginModule required;
};
EOF

# A certificate of the broker's own making, which is why the TLS check below asks
# for insecure=1 - and why the one without it has to fail.
mkdir -p "$WORK/secrets"
docker run --rm -v "$WORK/secrets:/secrets" --entrypoint bash "$IMAGE" -c '
  keytool -genkeypair -alias broker -keyalg RSA -keysize 2048 -validity 30 \
    -dname "CN=localhost, O=krtek, C=CZ" -ext "SAN=dns:localhost,ip:127.0.0.1" \
    -keystore /secrets/server.keystore.jks -storepass changeit -keypass changeit \
    -storetype JKS >/dev/null 2>&1
  printf changeit > /secrets/keystore_creds
  printf changeit > /secrets/key_creds
  chmod 644 /secrets/*'

echo "starting $IMAGE"
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" \
	-p 9093:9095 -p 9097:9096 -p 9101:9100 \
	-v "$WORK/jaas.conf:/etc/kafka/jaas.conf:ro" \
	-v "$WORK/secrets:/etc/kafka/secrets:ro" \
	-e KAFKA_NODE_ID=1 -e KAFKA_PROCESS_ROLES=broker,controller \
	-e KAFKA_LISTENERS=INTERNAL://:9092,EXTERNAL://:9095,SASL://:9096,SASLSSL://:9100,CONTROLLER://:9094 \
	-e KAFKA_ADVERTISED_LISTENERS=INTERNAL://localhost:9092,EXTERNAL://127.0.0.1:9093,SASL://127.0.0.1:9097,SASLSSL://127.0.0.1:9101 \
	-e KAFKA_LISTENER_SECURITY_PROTOCOL_MAP=CONTROLLER:PLAINTEXT,INTERNAL:PLAINTEXT,EXTERNAL:PLAINTEXT,SASL:SASL_PLAINTEXT,SASLSSL:SASL_SSL \
	-e KAFKA_INTER_BROKER_LISTENER_NAME=INTERNAL \
	-e KAFKA_SASL_ENABLED_MECHANISMS=PLAIN,SCRAM-SHA-256,SCRAM-SHA-512 \
	-e KAFKA_OPTS=-Djava.security.auth.login.config=/etc/kafka/jaas.conf \
	-e KAFKA_SSL_KEYSTORE_FILENAME=server.keystore.jks \
	-e KAFKA_SSL_KEYSTORE_CREDENTIALS=keystore_creds \
	-e KAFKA_SSL_KEY_CREDENTIALS=key_creds \
	-e KAFKA_SSL_CLIENT_AUTH=none \
	-e KAFKA_CONTROLLER_QUORUM_VOTERS=1@localhost:9094 \
	-e KAFKA_CONTROLLER_LISTENER_NAMES=CONTROLLER \
	-e KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR=1 \
	-e KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR=1 \
	-e KAFKA_TRANSACTION_STATE_LOG_MIN_ISR=1 \
	"$IMAGE" >/dev/null

kafka() { docker exec "$NAME" "/opt/kafka/bin/$@"; }

printf 'waiting for the broker'
until kafka kafka-topics.sh --bootstrap-server localhost:9092 --list >/dev/null 2>&1; do
	printf .
	sleep 3
done
echo " up"

kafka kafka-topics.sh --bootstrap-server localhost:9092 --create --topic orders \
	--partitions 3 --replication-factor 1 >/dev/null
docker exec "$NAME" bash -c 'for i in $(seq 1 9); do echo "key$i:zaznam $i"; done |
	/opt/kafka/bin/kafka-console-producer.sh --bootstrap-server localhost:9092 --topic orders \
	  --property parse.key=true --property key.separator=:' >/dev/null 2>&1

# One topic per codec, with a value long enough that compression does something.
for codec in gzip snappy lz4 zstd; do
	kafka kafka-topics.sh --bootstrap-server localhost:9092 --create --topic "c-$codec" \
		--partitions 1 --replication-factor 1 >/dev/null
	docker exec "$NAME" bash -c "for i in 1 2 3; do
			echo \"k\$i:zprava \$i zabalena pomoci $codec, dost dlouha na to aby se komprese projevila\"
		done | /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server localhost:9092 \
			--topic c-$codec --property parse.key=true --property key.separator=: \
			--compression-codec $codec" >/dev/null 2>&1
done

kafka kafka-configs.sh --bootstrap-server localhost:9092 --alter \
	--add-config 'SCRAM-SHA-256=[password=bob-secret]' \
	--entity-type users --entity-name bob >/dev/null

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

check "plaintext" "kafka://127.0.0.1:9093" "connected:"

# Twelve records over three partitions, which is the shape that catches paging:
# a page is a window over the whole topic, so every record has to come back
# exactly once across the pages and none of them twice. This was wrong twice -
# once because the page was applied to every partition separately, once because a
# fetch answers with whole batches and the records before the offset it was asked
# for were kept.
kafka kafka-topics.sh --bootstrap-server localhost:9092 --create --topic pages \
	--partitions 3 --replication-factor 1 >/dev/null
docker exec "$NAME" bash -c 'for i in $(seq -w 1 12); do echo "k$i:zaznam-$i"; done |
	/opt/kafka/bin/kafka-console-producer.sh --bootstrap-server localhost:9092 --topic pages \
	  --property parse.key=true --property key.separator=:' >/dev/null 2>&1
check "pages neither overlap nor skip" "kafka://127.0.0.1:9093" "paged: 12 records, 12 distinct" pages
check "every partition is counted" "kafka://127.0.0.1:9093" "orders rows~9 exact=9"
for codec in gzip snappy lz4 zstd; do
	check "$codec unpacks" "kafka://127.0.0.1:9093" "c-$codec rows~3 exact=3"
done
check "SASL/PLAIN" "kafka://alice:alice-secret@127.0.0.1:9097" "connected:"
check "SASL/SCRAM-SHA-256" "kafka://bob:bob-secret@127.0.0.1:9097?mechanism=SCRAM-SHA-256" "connected:"
check "TLS with SASL" "kafka+ssl://alice:alice-secret@127.0.0.1:9101?insecure=1" "connected:"
check "TLS with SCRAM" "kafka+ssl://bob:bob-secret@127.0.0.1:9101?mechanism=SCRAM-SHA-256&insecure=1" "connected:"

# The refusals matter as much as the connections: a wrong password must not look
# like a network problem, and a certificate that does not check out must not be
# waved through.
check "a wrong password is refused, in the broker's own words" \
	"kafka://alice:nope@127.0.0.1:9097" "Invalid username or password"
check "a wrong SCRAM password is refused" \
	"kafka://bob:nope@127.0.0.1:9097?mechanism=SCRAM-SHA-256" "invalid credentials"
check "a user with no password asks for one" \
	"kafka://bob@127.0.0.1:9097" "wants a password"
check "an unverifiable certificate is not waved through" \
	"kafka+ssl://alice:alice-secret@127.0.0.1:9101" "certificate verify failed"

echo
echo "kafka: everything the driver claims, against a real broker"
