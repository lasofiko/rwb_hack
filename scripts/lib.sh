# Общее для build.sh и check.sh: psql внутри контейнера postgres.
# Подключается через source, сам по себе не запускается.
#
# Локальный psql не нужен: репозиторий смонтирован в контейнер как /work
# (см. docker-compose.yml), пути к SQL-файлам — от корня репозитория.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

die() { echo; echo "ОШИБКА: $1" >&2; [ $# -gt 1 ] && echo "$2" >&2; exit 1; }

if docker compose version >/dev/null 2>&1; then
  DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  DC="docker-compose"
else
  die "не найден docker compose" "Сначала окружение: bash scripts/setup.sh"
fi

# Поднимает postgres и ждёт готовности. Если контейнер уже запущен с той же
# конфигурацией, ничего не делает; если docker-compose.yml поменялся —
# пересоздаёт контейнер, данные остаются в volume.
db_up() {
  local out
  out=$($DC up -d postgres 2>&1) \
    || die "не удалось запустить postgres" "$out"
  for _ in $(seq 1 60); do
    $DC exec -T postgres pg_isready -U hack -d marketplace >/dev/null 2>&1 && break
    sleep 1
  done
  $DC exec -T postgres pg_isready -U hack -d marketplace >/dev/null 2>&1 \
    || die "база не отвечает" "Посмотрите логи:  $DC logs postgres"
  $DC exec -T postgres test -f /work/model/build.sql \
    || die "в контейнере не видно репозитория (/work)" \
           "Пересоздайте контейнер:  $DC up -d --force-recreate postgres"
}

# psql с остановкой на первой ошибке: ненулевой код, если что-то упало.
psql_run() {
  $DC exec -T -w /work postgres \
    psql -X -q -v ON_ERROR_STOP=1 -U hack -d marketplace "$@"
}
