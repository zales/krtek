#!/bin/sh
# Regenerate the screenshots in docs/. They are SVGs written from what the app
# actually drew - see tests/shot.py - so this is how they stay honest when the
# interface changes.
#
#     zig build && ./tests/shots.sh
set -e
cd "$(dirname "$0")/.."

# A short path, because it is in the header of every shot.
DB=${DB:-/tmp/books.db}
rm -f "$DB"
sqlite3 "$DB" <<'SQL'
CREATE TABLE authors (
	id INTEGER PRIMARY KEY,
	name TEXT NOT NULL,
	born INTEGER,
	note TEXT
);
CREATE TABLE books (
	id INTEGER PRIMARY KEY,
	author_id INTEGER NOT NULL REFERENCES authors(id) ON DELETE CASCADE,
	title TEXT NOT NULL,
	year INTEGER,
	price REAL,
	tags TEXT
);
CREATE INDEX books_year ON books (year, title);
CREATE VIEW in_print AS
	SELECT b.title, a.name AS author, b.year FROM books b JOIN authors a ON a.id = b.author_id;
INSERT INTO authors (name, born, note) VALUES
	('Karel Čapek', 1890, 'RUR, Válka s mloky'),
	('Bohumil Hrabal', 1914, NULL),
	('Milan Kundera', 1929, 'later wrote in French'),
	('Jaroslav Hašek', 1883, NULL);
INSERT INTO books (author_id, title, year, price, tags) VALUES
	(1, 'Válka s mloky', 1936, 249.5, '["classic","sci-fi"]'),
	(1, 'RUR', 1920, 189.0, '["play"]'),
	(2, 'Obsluhoval jsem krále', 1971, 199.0, NULL),
	(3, 'Žert', 1967, 279.0, '["novel"]'),
	(4, 'Osudy dobrého vojáka Švejka', 1921, 349.9, '["classic"]');
SQL

# A configuration of its own, so no screenshot shows somebody's real connections.
# A short, fixed path: it is on screen in the list of connections.
CONFIG=/tmp/krtek-shots
rm -rf "$CONFIG"
mkdir -p "$CONFIG/krtek"
{
	printf '# krtek connections\n'
	printf 'books\t%s\n' "$DB"
	printf 'shop (docker)\tpostgres://postgres@127.0.0.1:5432/shop\n'
	printf 'orders\tmysql://root@127.0.0.1:3306/orders\tkeychain\n'
	printf 'cache\tredis://127.0.0.1:6379/0\n'
	printf 'events\tkafka+ssl://alice@broker.example:9093\n'
	printf 'photos\ts3://photos?region=eu-central-1\n'
	printf 'broker\trabbit://guest@127.0.0.1:15672/%%2F\n'
} > "$CONFIG/krtek/connections"
export XDG_CONFIG_HOME="$CONFIG"
trap 'rm -rf "$CONFIG"' EXIT

# A small terminal, so a screenshot is a screenshot and not a wall.
export SHOT_COLS=${SHOT_COLS:-100}
export SHOT_ROWS=${SHOT_ROWS:-14}

take() {
	name=$1
	shift
	python3 tests/shot.py "docs/$name.svg" "$@"
}

take grid "$DB" '{down}{enter}'
take structure "$DB" '{down}{enter}' 'S'
SHOT_ROWS=16 take editor "$DB" 's' 'select title, year, price from books' '{enter}' \
	"where year < 1950 -- the old ones" '{enter}' 'order by year desc'
SHOT_ROWS=18 take palette "$DB" '{ctrl-k}' 'exp'
# An empty target is what opens the list of connections.
SHOT_ROWS=17 take connections ''

echo "screenshots in docs/"
