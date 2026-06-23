#!/bin/bash

# =============================================================================
# PROXMOX SUBSCRIPTION NAG REMOVER v2.0.0
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Цвета
# -----------------------------------------------------------------------------
GREEN='\033[0;32m'
BRIGHT_GREEN='\033[1;32m'
AMBER='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

# -----------------------------------------------------------------------------
# Константы
# -----------------------------------------------------------------------------
FILE_PATH="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
TARGET_STR="getNoSubKeyHtml:"
REPLACEMENT_STR="_getNoSubKeyHtml:"
readonly SCRIPT_VERSION="2.0.0"

# -----------------------------------------------------------------------------
# Флаги
# -----------------------------------------------------------------------------
AUTO_YES=false
DRY_RUN=false
QUIET=false

# Глобальная переменная для возврата пути backup из функции
BACKUP_FILE_PATH=""

# -----------------------------------------------------------------------------
# Вспомогательные функции вывода
# -----------------------------------------------------------------------------
log_info()    { $QUIET || echo -e "${GREEN}[ INFO ]${NC} $*"; }
log_ok()      { $QUIET || echo -e "${BRIGHT_GREEN}[ OK ]${NC} $*"; }
log_warn()    { echo -e "${AMBER}[ WARN ]${NC} $*" >&2; }
log_error()   { echo -e "${RED}[ ERROR ]${NC} $*" >&2; }
log_success() { $QUIET || echo -e "${BRIGHT_GREEN}[ SUCCESS ]${NC} $*"; }

# -----------------------------------------------------------------------------
# Использование
# -----------------------------------------------------------------------------
usage() {
    cat <<EOF
Использование: $(basename "$0") [ОПЦИИ]

Опции:
  -y, --yes       Не спрашивать подтверждения (автоматический режим)
  -n, --dry-run   Показать что будет сделано, без изменений
  -q, --quiet     Минимальный вывод (только ошибки)
  -f, --file      Путь к файлу (по умолчанию: $FILE_PATH)
  -h, --help      Показать это сообщение

Пример:
  sudo $(basename "$0") --yes
  sudo $(basename "$0") --dry-run
EOF
}

# -----------------------------------------------------------------------------
# Разбор аргументов
# -----------------------------------------------------------------------------
parse_args() {
    RESOLVED_FILE="$FILE_PATH"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -y|--yes)       AUTO_YES=true ;;
            -n|--dry-run)   DRY_RUN=true ;;
            -q|--quiet)     QUIET=true ;;
            -f|--file)      shift; RESOLVED_FILE="$1" ;;
            -h|--help)      usage; exit 0 ;;
            *) log_error "Неизвестный аргумент: $1"; usage; exit 1 ;;
        esac
        shift
    done
}

# -----------------------------------------------------------------------------
# Проверки окружения
# -----------------------------------------------------------------------------
check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        log_error "Запустите скрипт от root или через sudo."
        exit 1
    fi
}

check_dependencies() {
    local missing=()
    for cmd in grep sed cp sha256sum systemctl; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Не найдены утилиты: ${missing[*]}"
        exit 1
    fi
}

check_file_exists() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        log_error "Файл не найден: $file"
        exit 1
    fi
    if [[ ! -r "$file" ]]; then
        log_error "Нет прав на чтение файла: $file"
        exit 1
    fi
    if [[ ! -w "$file" ]]; then
        log_error "Нет прав на запись в файл: $file"
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Проверка состояния патча
# Возвращает:
#   0 — патч ещё не применён, можно применять
#   1 — патч уже применён
#   2 — сигнатура не найдена (несовместимая версия файла)
#   3 — сигнатура встречается несколько раз (небезопасно)
# -----------------------------------------------------------------------------
check_patch_state() {
    local file="$1"

    if grep -Fq "$REPLACEMENT_STR" "$file"; then
        return 1
    fi

    local count
    count=$(grep -Fc "$TARGET_STR" "$file" || true)

    if [[ "$count" -eq 0 ]]; then
        return 2
    fi

    if [[ "$count" -gt 1 ]]; then
        return 3
    fi

    return 0
}

# -----------------------------------------------------------------------------
# Backup — путь сохраняется в глобальной BACKUP_FILE_PATH
# -----------------------------------------------------------------------------
create_backup() {
    local file="$1"
    BACKUP_FILE_PATH="${file}.bak.$(date +%Y%m%d_%H%M%S)"

    log_info "Создание резервной копии..."

    if ! cp "$file" "$BACKUP_FILE_PATH"; then
        log_error "Не удалось создать резервную копию."
        exit 1
    fi

    if [[ ! -s "$BACKUP_FILE_PATH" ]]; then
        log_error "Резервная копия оказалась пустой: $BACKUP_FILE_PATH"
        rm -f "$BACKUP_FILE_PATH"
        exit 1
    fi

    sha256sum "$BACKUP_FILE_PATH" > "${BACKUP_FILE_PATH}.sha256"

    log_ok "Резервная копия: $BACKUP_FILE_PATH"
}

# -----------------------------------------------------------------------------
# Применение патча
# -----------------------------------------------------------------------------
apply_patch() {
    local file="$1"
    local backup="$2"

    log_info "Применение патча..."

    if ! sed -i "s/${TARGET_STR}/${REPLACEMENT_STR}/" "$file"; then
        log_error "sed завершился с ошибкой."
        restore_backup "$file" "$backup"
        exit 1
    fi

    if ! grep -Fq "$REPLACEMENT_STR" "$file"; then
        log_error "Замена не применилась — файл не изменился."
        restore_backup "$file" "$backup"
        exit 1
    fi

    if grep -Fq "$TARGET_STR" "$file"; then
        log_warn "Оригинальная сигнатура всё ещё присутствует в файле."
    fi

    log_success "Патч успешно применён."
}

# -----------------------------------------------------------------------------
# Восстановление из backup
# -----------------------------------------------------------------------------
restore_backup() {
    local file="$1"
    local backup="$2"

    if [[ -f "$backup" ]]; then
        log_warn "Восстановление из резервной копии: $backup"
        cp "$backup" "$file"
        log_ok "Файл восстановлен."
    else
        log_error "Резервная копия не найдена: $backup"
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# Перезапуск pveproxy
# -----------------------------------------------------------------------------
restart_proxy() {
    log_info "Перезапуск pveproxy..."

    if systemctl restart pveproxy; then
        log_ok "pveproxy перезапущен."
    else
        log_warn "Не удалось перезапустить pveproxy автоматически."
        log_warn "Выполните вручную: systemctl restart pveproxy"
    fi
}

# -----------------------------------------------------------------------------
# Запрос подтверждения
# -----------------------------------------------------------------------------
confirm() {
    if $AUTO_YES; then
        return 0
    fi

    local answer
    echo -ne "${AMBER}---> Выполнить модификацию? (y/n) [таймаут 30 сек]: ${NC}"
    if ! read -r -t 30 answer; then
        echo
        log_warn "Таймаут ожидания ввода. Операция отменена."
        exit 0
    fi

    case "$answer" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) return 1 ;;
    esac
}

# -----------------------------------------------------------------------------
# Основная логика
# -----------------------------------------------------------------------------
main() {
    parse_args "$@"

    local target_file="${RESOLVED_FILE:-$FILE_PATH}"

    $QUIET || {
        clear
        echo -e "${BRIGHT_GREEN}[==================================================]"
        echo -e "[*]  PROXMOX SUBSCRIPTION NAG REMOVER v${SCRIPT_VERSION}    [*]"
        echo -e "[==================================================]${NC}"
        echo
    }

    check_root
    check_dependencies
    check_file_exists "$target_file"

    if command -v pveversion >/dev/null 2>&1; then
        log_info "Версия системы: $(pveversion)"
    fi

    echo

    log_info "Сканирование файла..."
    echo "    $target_file"
    echo

    local state
    check_patch_state "$target_file" && state=$? || state=$?

    case "$state" in
        1)
            log_ok "Патч уже применён. Дополнительных действий не требуется."
            exit 0
            ;;
        2)
            log_error "Целевая сигнатура не найдена: ${TARGET_STR}"
            log_warn "Структура файла могла измениться после обновления Proxmox."
            exit 1
            ;;
        3)
            log_error "Сигнатура встречается несколько раз — патч небезопасен."
            log_warn "Проверьте файл вручную: grep -n '${TARGET_STR}' ${target_file}"
            exit 1
            ;;
        0)
            log_info "Обнаружено окно проверки подписки Proxmox."
            ;;
    esac

    if $DRY_RUN; then
        log_info "[DRY RUN] Без изменений. Планируемые действия:"
        echo "    1. Создать backup: ${target_file}.bak.<timestamp>"
        echo "    2. Заменить '${TARGET_STR}' → '${REPLACEMENT_STR}'"
        echo "    3. systemctl restart pveproxy"
        exit 0
    fi

    if ! confirm; then
        echo
        log_warn "Операция отменена пользователем."
        exit 0
    fi

    echo

    create_backup "$target_file"

    echo
    apply_patch "$target_file" "$BACKUP_FILE_PATH"

    echo
    restart_proxy

    echo
    log_warn "После обновления пакета proxmox-widget-toolkit патч будет перезаписан."
    echo
    log_success "Готово."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
