#!/usr/bin/env bash
#
# update-openclaw.sh — atualiza o OpenClaw (rodando via Docker) numa VPS,
# sozinho e com segurança. Feito para VPS tipo HostGator, mas 100%
# discovery-based: descobre o container, o diretório do compose, a porta e os
# volumes por conta própria. Não assume caminho nenhum.
#
# Uso:
#   bash <(curl -fsSL <URL>)           # atualiza para a última versão publicada
#   bash <(curl -fsSL <URL>) 1.2.3     # atualiza para uma versão específica
#   ./update-openclaw.sh --dry-run     # mostra o que faria, sem mudar nada
#
# Por que é seguro:
#   - backup do diretório do compose antes de qualquer alteração;
#   - config, token e modelo vivem em VOLUMES nomeados — nunca são tocados;
#   - a imagem ANTIGA só é removida no fim, depois do novo container passar no
#     healthcheck — então qualquer falha volta atrás sozinha (rollback);
#   - nada irreversível roda sem confirmação: falta de disco só é resolvida com
#     prune seguro (build cache / imagens órfãs), nunca apagando a imagem em uso.
#
set -euo pipefail

# ---------------------------------------------------------------- aparência ---
if [[ -t 1 ]]; then
  B=$'\033[1m'; DIM=$'\033[2m'; R=$'\033[0m'
  OK=$'\033[32m'; WARN=$'\033[33m'; ERR=$'\033[31m'; INFO=$'\033[36m'
else
  B=''; DIM=''; R=''; OK=''; WARN=''; ERR=''; INFO=''
fi
say()  { printf '%b\n' "${*}"; }
step() { printf '\n%s▸ %s%s\n' "$B$INFO" "$*" "$R"; }
ok()   { printf '  %s✓%s %s\n' "$OK" "$R" "$*"; }
warn() { printf '  %s!%s %s\n' "$WARN" "$R" "$*"; }
die()  { printf '\n%s✗ %s%s\n' "$B$ERR" "$*" "$R" >&2; exit 1; }

REPO="ghcr.io/openclaw/openclaw"
DRY_RUN=0
TARGET_VERSION=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)        die "opção desconhecida: $arg" ;;
    *)         TARGET_VERSION="$arg" ;;
  esac
done
run() { # executa um comando, ou só imprime em --dry-run
  if (( DRY_RUN )); then printf '  %s[dry-run]%s %s\n' "$DIM" "$R" "$*"; else eval "$*"; fi
}

# --------------------------------------------------------------- preflight ---
[[ $EUID -eq 0 ]] || die "rode como root (sudo). Mexer em Docker/compose exige."
command -v docker >/dev/null || die "docker não encontrado nesta VPS."

if docker compose version >/dev/null 2>&1; then
  DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  DC="docker-compose"
else
  die "nem 'docker compose' (v2) nem 'docker-compose' (v1) disponíveis."
fi

say "${B}OpenClaw VPS Updater${R} ${DIM}— @melgarafael${R}"
(( DRY_RUN )) && warn "modo DRY-RUN: nada será alterado."

# -------------------------------------------------------------- descoberta ---
step "Descobrindo o setup (não altero nada)"

CONTAINER=$(docker ps --format '{{.Names}}\t{{.Image}}' \
  | awk 'tolower($0) ~ /openclaw/ {print $1; exit}')
if [[ -z "$CONTAINER" ]]; then
  if docker ps -a --format '{{.Names}}\t{{.Image}}' | grep -qi openclaw; then
    die "achei um container OpenClaw parado. Suba ele ('$DC up -d') antes de atualizar."
  fi
  die "nenhum container OpenClaw rodando. Este script atualiza uma instalação Docker existente."
fi
ok "container: $CONTAINER"

CUR_IMAGE=$(docker inspect "$CONTAINER" --format '{{.Config.Image}}')
CUR_VERSION="${CUR_IMAGE##*:}"
[[ "$CUR_IMAGE" == "$CUR_VERSION" ]] && CUR_VERSION="latest"  # imagem sem tag explícita
ok "versão atual: $CUR_VERSION  ${DIM}($CUR_IMAGE)${R}"

COMPOSE_DIR=$(docker inspect "$CONTAINER" \
  --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}')
[[ -n "$COMPOSE_DIR" && -d "$COMPOSE_DIR" ]] \
  || die "este container não foi criado via docker compose (sem diretório de compose). Não sei atualizar um 'docker run' cru com segurança."
ok "diretório do compose: $COMPOSE_DIR"

SERVICE=$(docker inspect "$CONTAINER" \
  --format '{{ index .Config.Labels "com.docker.compose.service" }}')
[[ -n "$SERVICE" ]] || SERVICE="openclaw"
ok "serviço no compose: $SERVICE"

# porta interna que o gateway escuta (usada no healthcheck)
PORT=$(docker inspect "$CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' \
  | awk -F= '/^PORT=/{print $2; exit}')
[[ -z "$PORT" && -f "$COMPOSE_DIR/.env" ]] && \
  PORT=$(awk -F= '/^PORT=/{print $2; exit}' "$COMPOSE_DIR/.env")
[[ -n "$PORT" ]] || PORT=18789  # default do OpenClaw
ok "porta do gateway: $PORT"

# diretório de config persistente (o volume). É pra onde apontamos o novo state
# dir da 7.x na migração, para a config não cair em storage efêmero.
CONFIG_DIR=$(docker inspect "$CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' \
  | awk -F= '/^XDG_CONFIG_HOME=/{print $2; exit}')
[[ -n "$CONFIG_DIR" ]] && ok "config dir (volume): $CONFIG_DIR"

# volumes (só pra mostrar que persistem — nunca são tocados)
say "  ${DIM}volumes preservados:${R}"
docker inspect "$CONTAINER" --format '{{range .Mounts}}{{if eq .Type "volume"}}    {{.Name}} -> {{.Destination}}{{"\n"}}{{end}}{{end}}' | sed '/^$/d' || true

# ---------------------------------------------------------- versão-alvo ---
step "Descobrindo a última versão publicada"
if [[ -n "$TARGET_VERSION" ]]; then
  NEW_VERSION="$TARGET_VERSION"
  ok "versão pedida na linha de comando: $NEW_VERSION"
else
  NEW_VERSION=$(docker exec "$CONTAINER" sh -lc 'npm view openclaw version 2>/dev/null' 2>/dev/null | tr -d '[:space:]' || true)
  [[ -z "$NEW_VERSION" ]] && NEW_VERSION=$(npm view openclaw version 2>/dev/null | tr -d '[:space:]' || true)
  [[ -n "$NEW_VERSION" ]] \
    || die "não consegui descobrir a última versão (sem npm no container nem no host). Rode de novo passando a versão: ./update-openclaw.sh 1.2.3"
  ok "última versão publicada: $NEW_VERSION"
fi
[[ "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+ ]] || die "versão '$NEW_VERSION' não parece válida (esperado algo tipo 1.2.3)."

if [[ "$NEW_VERSION" == "$CUR_VERSION" ]]; then
  say "\n${B}${OK}Já está na versão mais recente ($CUR_VERSION). Nada a fazer.${R}"
  exit 0
fi

# confirma que a imagem nova existe no registry ANTES de mexer em qualquer coisa
docker manifest inspect "$REPO:$NEW_VERSION" >/dev/null 2>&1 \
  || die "a imagem $REPO:$NEW_VERSION não existe no registry. Versão errada?"
ok "imagem $REPO:$NEW_VERSION existe no registry"

say "\n${B}Plano: $CUR_VERSION → $NEW_VERSION${R}"

# ------------------------------------------------------------------ disco ---
step "Checando espaço em disco"
DATA_ROOT=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)
FREE_KB=$(df -Pk "$DATA_ROOT" | awk 'NR==2{print $4}')
# ponytail: piso fixo de 5GB de folga pro pull/build da imagem nova. O .Size do
# Docker subestima muito (reporta content size — 486MB — vs ~2GB de uso real em
# disco), então um piso fixo é mais honesto que aritmética sobre um número enganoso.
NEED_KB=$(( 5 * 1024 * 1024 ))
ok "livre em $DATA_ROOT: $((FREE_KB/1024/1024))GB · folga mínima p/ atualizar: 5GB"

if (( FREE_KB < NEED_KB )); then
  warn "pouco espaço — liberando com prune seguro (build cache + imagens órfãs)"
  run "docker builder prune -af >/dev/null 2>&1 || true"
  run "docker image prune -f  >/dev/null 2>&1 || true"
  if (( ! DRY_RUN )); then
    FREE_KB=$(df -Pk "$DATA_ROOT" | awk 'NR==2{print $4}')
    ok "livre agora: $((FREE_KB/1024/1024))GB"
    (( FREE_KB < NEED_KB )) && die "ainda sem 5GB livres para atualizar com segurança. Libere disco (a imagem antiga não é apagada automaticamente pra não te deixar sem rollback) e rode de novo."
  fi
fi

# ------------------------------------------------------------------ backup ---
step "Backup (obrigatório antes de alterar)"
STAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="${COMPOSE_DIR%/}.bak-$STAMP"
run "cp -a '$COMPOSE_DIR' '$BACKUP_DIR'"
ok "compose salvo em: $BACKUP_DIR"
say "  ${DIM}config/token/modelo estão em volumes Docker — não precisam de backup, persistem sozinhos.${R}"

# a partir daqui, qualquer erro faz rollback automático -----------------------
OVERRIDE_FILE="$COMPOSE_DIR/docker-compose.override.yml"
CREATED_OVERRIDE=0
rollback() {
  local rc=$?
  trap - EXIT
  printf '\n%s↩ Falhou (código %s) — revertendo para %s…%s\n' "$B$WARN" "$rc" "$CUR_VERSION" "$R" >&2
  (( CREATED_OVERRIDE )) && rm -f "$OVERRIDE_FILE"
  cp -a "$BACKUP_DIR/." "$COMPOSE_DIR/" 2>/dev/null || true
  ( cd "$COMPOSE_DIR" && $DC up -d ) >/dev/null 2>&1 || true
  printf '%sRevertido. Config/dados intactos (volumes). Backup do compose: %s%s\n' \
    "$WARN" "$BACKUP_DIR" "$R" >&2
  exit "$rc"
}
# trap em EXIT, não ERR: 'die' usa exit, que dispara o EXIT trap mas NÃO o ERR.
# Em EXIT, qualquer saída não-zero (die ou set -e) cai no rollback; a saída
# limpa no fim desarma o trap ('trap - EXIT') antes do resumo.
(( DRY_RUN )) || trap rollback EXIT

# -------------------------------------------------------- trocar as tags ---
step "Atualizando os tags de versão nos arquivos"
bump() { # bump <arquivo> <prefixo-da-linha>
  local f="$1" pat="$2"
  [[ -f "$f" ]] || return 0
  if (( DRY_RUN )); then
    printf '  %s[dry-run]%s %s: %s%s → :%s\n' "$DIM" "$R" "${f##*/}" "$pat" "$CUR_VERSION" "$NEW_VERSION"
  else
    sed -i -E "s#(${pat}${REPO}:)[A-Za-z0-9._-]+#\1${NEW_VERSION}#g" "$f"
    grep -q "$REPO:$NEW_VERSION" "$f" && ok "${f##*/} → $NEW_VERSION"
  fi
}
bump "$COMPOSE_DIR/Dockerfile"          'FROM +'
bump "$COMPOSE_DIR/docker-compose.yml"  'image: *'
bump "$COMPOSE_DIR/docker-compose.yaml" 'image: *'

# ------------------------------------------------------------------- build ---
step "Buildando a nova imagem (o container atual segue no ar)"
say "  ${DIM}pode demorar — camadas grandes vêm do cache; o download real costuma ser 1-2GB.${R}"
run "( cd '$COMPOSE_DIR' && $DC build --pull )"
if (( ! DRY_RUN )); then
  docker image inspect "$REPO:$NEW_VERSION" >/dev/null 2>&1 \
    || { false; }  # dispara o trap de rollback
  ok "imagem $NEW_VERSION pronta"
fi

# --------------------------------------------------------- recriar container ---
# --force-recreate: camada nova e limpa. Necessário na travessia 6.x→7.x, onde a
# imagem traz um esqueleto .openclaw que confunde a migração num container reciclado.
step "Recriando o container na nova versão"
run "( cd '$COMPOSE_DIR' && $DC up -d --force-recreate )"
if (( ! DRY_RUN )); then
  sleep 3
  NOW_IMAGE=$(docker inspect "$CONTAINER" --format '{{.Config.Image}}' 2>/dev/null || echo "?")
  ok "rodando: $NOW_IMAGE"
fi

# ------------------------------------------------- pegadinha do healthcheck ---
# A imagem nova traz um healthcheck embutido apontando pra porta PADRÃO. Se este
# deploy usa porta custom, o container fica preso em "unhealthy" mesmo 100% OK.
# Corrigimos com um override aditivo (não toca no compose original).
step "Ajustando o healthcheck para a porta real ($PORT)"
if (( DRY_RUN )); then
  printf '  %s[dry-run]%s criaria %s apontando healthcheck para :%s\n' "$DIM" "$R" "${OVERRIDE_FILE##*/}" "$PORT"
else
  HC=$(docker inspect "$CONTAINER" --format '{{json .Config.Healthcheck}}' 2>/dev/null || echo null)
  if [[ "$HC" == "null" ]]; then
    ok "imagem não define healthcheck — nada a ajustar"
  elif [[ "$HC" == *":$PORT/"* || "$HC" == *"127.0.0.1:$PORT"* ]]; then
    ok "healthcheck já aponta pra porta certa ($PORT)"
  else
    cat > "$OVERRIDE_FILE" <<YAML
# Gerado por update-openclaw.sh — corrige o healthcheck para a porta real deste deploy.
services:
  ${SERVICE}:
    healthcheck:
      test: ["CMD-SHELL", "node -e \"fetch('http://127.0.0.1:${PORT}/healthz').then((r)=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))\""]
      interval: 180s
      timeout: 10s
      start_period: 30s
      retries: 3
YAML
    CREATED_OVERRIDE=1
    ( cd "$COMPOSE_DIR" && $DC up -d ) >/dev/null
    ok "healthcheck corrigido via override (porta $PORT)"
  fi
fi

# espera o /healthz responder 200 (o gateway leva ~30s pra ficar ready; se estiver
# em crash-loop, o docker exec falha e a gente só continua tentando até o timeout).
wait_healthy() {
  local tries="$1" http
  for ((i=0; i<tries; i++)); do
    http=$(docker exec "$CONTAINER" sh -lc \
      "node -e \"fetch('http://127.0.0.1:${PORT}/healthz').then(r=>{console.log(r.status);process.exit(r.ok?0:1)}).catch(()=>process.exit(1))\"" 2>/dev/null) \
      && { printf '%s' "$http"; return 0; }
    sleep 6
  done
  return 1
}

# Remédio da travessia 6.x→7.x: a 7.x renomeou o state dir para .openclaw e passou
# a EXIGIR a migração; como a imagem já traz um .openclaw esqueleto, ela trava. A
# correção é apontar o state dir da 7.x para o volume de config que já persiste e
# rodar 'doctor --fix' no boot para gerar a config no formato novo. Idempotente.
apply_state_dir_migration() {
  local cf="$COMPOSE_DIR/docker-compose.yml"
  [[ -f "$cf" ]] || cf="$COMPOSE_DIR/docker-compose.yaml"
  [[ -f "$cf" ]] || { warn "sem docker-compose.yml para migrar"; return 1; }
  if ! grep -q OPENCLAW_STATE_DIR "$cf" && [[ -n "$CONFIG_DIR" ]]; then
    sed -i -E "s#^([[:space:]]*)(XDG_CONFIG_HOME:.*)#\1\2\n\1OPENCLAW_STATE_DIR: ${CONFIG_DIR}#" "$cf"
    ok "OPENCLAW_STATE_DIR → $CONFIG_DIR (config passa a persistir no volume)"
  fi
  if ! grep -q 'doctor --fix' "$cf"; then
    if grep -q 'node dist/index.js gateway' "$cf"; then
      sed -i 's#node dist/index.js gateway#node dist/index.js doctor --fix || true; node dist/index.js gateway#' "$cf"
      ok "doctor --fix injetado antes do gateway"
    elif grep -q 'openclaw gateway' "$cf"; then
      sed -i 's#openclaw gateway#openclaw doctor --fix || true; openclaw gateway#' "$cf"
      ok "doctor --fix injetado antes do gateway"
    else
      warn "não localizei o comando do gateway no compose para injetar doctor --fix"
    fi
  fi
}

# --------------------------------------------------------------- verificação ---
step "Verificando a saúde do gateway (pode levar ~30s)"
if (( ! DRY_RUN )); then
  if HTTP=$(wait_healthy 15); then
    ok "gateway respondeu $HTTP no /healthz — saudável"
  elif docker logs --tail 40 "$CONTAINER" 2>&1 | grep -q "State dir migration skipped"; then
    warn "travessia 6.x→7.x detectada (state dir renomeado). Aplicando o remédio…"
    apply_state_dir_migration
    ( cd "$COMPOSE_DIR" && $DC up -d --force-recreate ) >/dev/null
    if HTTP=$(wait_healthy 15); then
      ok "gateway saudável após a migração ($HTTP) — modelo/canais preservados"
    else
      warn "sem saúde mesmo após a migração. Últimos logs:"
      docker logs --tail 20 "$CONTAINER" 2>&1 | sed 's/^/    /' || true
      die "gateway não ficou saudável nem após a migração."
    fi
  else
    warn "gateway não respondeu 200. Últimos logs:"
    docker logs --tail 20 "$CONTAINER" 2>&1 | sed 's/^/    /' || true
    die "gateway não ficou saudável."
  fi
fi

# ------------------------------------------------------------------ limpeza ---
step "Limpando a imagem antiga (agora sem uso)"
if [[ "$CUR_VERSION" != "latest" && "$CUR_VERSION" != "$NEW_VERSION" ]]; then
  run "docker rmi '$REPO:$CUR_VERSION' >/dev/null 2>&1 || true"
  ok "imagem $CUR_VERSION removida"
fi

(( DRY_RUN )) || trap - EXIT

# ------------------------------------------------------------------- resumo ---
say ""
say "${B}${OK}══════════════════════════════════════════════${R}"
say "${B}${OK} OpenClaw atualizado: $CUR_VERSION → $NEW_VERSION${R}"
say "${B}${OK}══════════════════════════════════════════════${R}"
say "  container : $CONTAINER"
say "  saúde     : ${OK}healthy${R} (200 no /healthz, porta $PORT)"
say "  backup    : $BACKUP_DIR"
say "  config    : preservada (volumes intactos — token, modelo, canais)"
say ""
say "Próximo passo: ${B}openclaw${R} → configure o modelo → mande um 'oi' pra validar."
