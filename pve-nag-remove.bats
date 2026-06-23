#!/usr/bin/env bats
# =============================================================================
# Тесты для pve-nag-remove.sh
# Требования: bats-core >= 1.5
#   Установка: apt install bats  или  brew install bats-core
#   Запуск:    bats pve-nag-remove.bats
# =============================================================================

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)/pve-nag-remove.sh"

# -----------------------------------------------------------------------------
# Вспомогательные функции — создают тестовые файлы
# -----------------------------------------------------------------------------

# Незапатченный файл — ровно одно вхождение сигнатуры
make_target_file() {
    cat > "$1" <<'EOF'
Ext.define('Proxmox.Utils', {
    singleton: true,
    getNoSubKeyHtml: function(url) {
        return '<p>No subscription</p>';
    },
    otherFunction: function() { return true; }
});
EOF
}

# Уже запатченный файл
make_patched_file() {
    cat > "$1" <<'EOF'
Ext.define('Proxmox.Utils', {
    singleton: true,
    _getNoSubKeyHtml: function(url) {
        return '<p>No subscription</p>';
    },
    otherFunction: function() { return true; }
});
EOF
}

# Файл с дублирующейся сигнатурой
make_duplicate_file() {
    cat > "$1" <<'EOF'
    getNoSubKeyHtml: function() { return ''; },
    getNoSubKeyHtml: function() { return ''; },
EOF
}

# Файл без целевой сигнатуры (другая структура)
make_incompatible_file() {
    cat > "$1" <<'EOF'
Ext.define('Proxmox.Utils', {
    singleton: true,
    checkSubscription: function() { return false; }
});
EOF
}

# -----------------------------------------------------------------------------
# Setup / Teardown
# -----------------------------------------------------------------------------

setup() {
    TEST_DIR="$(mktemp -d)"
    TEST_FILE="${TEST_DIR}/proxmoxlib.js"

    # Загружаем функции без вызова main()
    # shellcheck disable=SC1090
    source "$SCRIPT"

    # Переопределяем переменные на тестовые значения
    FILE_PATH="$TEST_FILE"
    RESOLVED_FILE="$TEST_FILE"
    AUTO_YES=false
    DRY_RUN=false
    QUIET=true
}

teardown() {
    rm -rf "$TEST_DIR"
}

# =============================================================================
# check_patch_state
# =============================================================================

@test "check_patch_state: 0 для незапатченного файла" {
    make_target_file "$TEST_FILE"
    run check_patch_state "$TEST_FILE"
    [ "$status" -eq 0 ]
}

@test "check_patch_state: 1 если патч уже применён" {
    make_patched_file "$TEST_FILE"
    run check_patch_state "$TEST_FILE"
    [ "$status" -eq 1 ]
}

@test "check_patch_state: 2 если сигнатура не найдена" {
    make_incompatible_file "$TEST_FILE"
    run check_patch_state "$TEST_FILE"
    [ "$status" -eq 2 ]
}

@test "check_patch_state: 3 если сигнатура встречается несколько раз" {
    make_duplicate_file "$TEST_FILE"
    run check_patch_state "$TEST_FILE"
    [ "$status" -eq 3 ]
}

# =============================================================================
# create_backup
# =============================================================================

@test "create_backup: создаёт файл backup" {
    make_target_file "$TEST_FILE"
    create_backup "$TEST_FILE"
    [ -f "$BACKUP_FILE_PATH" ]
}

@test "create_backup: backup не пустой" {
    make_target_file "$TEST_FILE"
    create_backup "$TEST_FILE"
    [ -s "$BACKUP_FILE_PATH" ]
}

@test "create_backup: создаёт sha256 файл" {
    make_target_file "$TEST_FILE"
    create_backup "$TEST_FILE"
    [ -f "${BACKUP_FILE_PATH}.sha256" ]
}

@test "create_backup: содержимое backup совпадает с оригиналом" {
    make_target_file "$TEST_FILE"
    original=$(cat "$TEST_FILE")
    create_backup "$TEST_FILE"
    backup_content=$(cat "$BACKUP_FILE_PATH")
    [ "$original" = "$backup_content" ]
}

@test "create_backup: имя включает временную метку YYYYMMDD_HHMMSS" {
    make_target_file "$TEST_FILE"
    create_backup "$TEST_FILE"
    [[ "$BACKUP_FILE_PATH" =~ \.bak\.[0-9]{8}_[0-9]{6}$ ]]
}

@test "create_backup: два вызова создают разные пути" {
    make_target_file "$TEST_FILE"
    create_backup "$TEST_FILE"
    first="$BACKUP_FILE_PATH"
    sleep 1
    create_backup "$TEST_FILE"
    second="$BACKUP_FILE_PATH"
    [ "$first" != "$second" ]
    [ -f "$first" ]
    [ -f "$second" ]
}

# =============================================================================
# apply_patch
# =============================================================================

@test "apply_patch: заменяет сигнатуру на префиксную" {
    make_target_file "$TEST_FILE"
    create_backup "$TEST_FILE"
    apply_patch "$TEST_FILE" "$BACKUP_FILE_PATH"
    grep -Fq "_getNoSubKeyHtml:" "$TEST_FILE"
}

@test "apply_patch: оригинальная сигнатура исчезает из файла" {
    make_target_file "$TEST_FILE"
    create_backup "$TEST_FILE"
    apply_patch "$TEST_FILE" "$BACKUP_FILE_PATH"
    # В файле не должно остаться голого "getNoSubKeyHtml:" (без префикса _)
    ! grep -P '(?<!_)getNoSubKeyHtml:' "$TEST_FILE"
}

@test "apply_patch: остальное содержимое файла не изменяется" {
    make_target_file "$TEST_FILE"
    create_backup "$TEST_FILE"
    lines_before=$(grep -c "otherFunction" "$TEST_FILE")
    apply_patch "$TEST_FILE" "$BACKUP_FILE_PATH"
    lines_after=$(grep -c "otherFunction" "$TEST_FILE")
    [ "$lines_before" -eq "$lines_after" ]
}

# =============================================================================
# restore_backup
# =============================================================================

@test "restore_backup: восстанавливает оригинальное содержимое" {
    make_target_file "$TEST_FILE"
    original=$(cat "$TEST_FILE")
    create_backup "$TEST_FILE"
    echo "corrupted" > "$TEST_FILE"
    restore_backup "$TEST_FILE" "$BACKUP_FILE_PATH"
    restored=$(cat "$TEST_FILE")
    [ "$original" = "$restored" ]
}

@test "restore_backup: завершается с ошибкой если backup не существует" {
    make_target_file "$TEST_FILE"
    run restore_backup "$TEST_FILE" "/nonexistent/backup.bak"
    [ "$status" -ne 0 ]
}

# =============================================================================
# check_file_exists
# =============================================================================

@test "check_file_exists: OK для существующего файла" {
    make_target_file "$TEST_FILE"
    run check_file_exists "$TEST_FILE"
    [ "$status" -eq 0 ]
}

@test "check_file_exists: ошибка если файл не найден" {
    run check_file_exists "/nonexistent/proxmoxlib.js"
    [ "$status" -ne 0 ]
}

# =============================================================================
# check_dependencies
# =============================================================================

@test "check_dependencies: проходит на стандартном Linux" {
    run check_dependencies
    [ "$status" -eq 0 ]
}

# =============================================================================
# parse_args
# =============================================================================

@test "parse_args: --yes устанавливает AUTO_YES=true" {
    parse_args --yes
    [ "$AUTO_YES" = "true" ]
}

@test "parse_args: --dry-run устанавливает DRY_RUN=true" {
    parse_args --dry-run
    [ "$DRY_RUN" = "true" ]
}

@test "parse_args: --quiet устанавливает QUIET=true" {
    parse_args --quiet
    [ "$QUIET" = "true" ]
}

@test "parse_args: -y является алиасом --yes" {
    parse_args -y
    [ "$AUTO_YES" = "true" ]
}

@test "parse_args: -n является алиасом --dry-run" {
    parse_args -n
    [ "$DRY_RUN" = "true" ]
}

@test "parse_args: --file задаёт RESOLVED_FILE" {
    parse_args --file /tmp/custom.js
    [ "$RESOLVED_FILE" = "/tmp/custom.js" ]
}

@test "parse_args: неизвестный флаг завершается с ошибкой" {
    run parse_args --unknown-flag
    [ "$status" -ne 0 ]
}

# =============================================================================
# Интеграционные тесты (main без root)
# =============================================================================

# Хелпер: запускает main в изолированном bash-процессе с замоканными root/systemd
# Это необходимо потому что:
#   1. `exit` внутри main завершил бы bats-тест при прямом вызове
#   2. `run` создаёт subshell — функции-моки туда не наследуются
_run_main() {
    local file="$1"; shift
    run bash -c "
        source '${SCRIPT}'
        FILE_PATH='${file}'
        RESOLVED_FILE='${file}'
        QUIET=true
        check_root()    { return 0; }
        restart_proxy() { return 0; }
        main $*
    "
}

@test "main --dry-run: файл не изменяется" {
    make_target_file "$TEST_FILE"
    content_before=$(cat "$TEST_FILE")
    _run_main "$TEST_FILE" --dry-run --yes --file "'$TEST_FILE'"
    content_after=$(cat "$TEST_FILE")
    [ "$content_before" = "$content_after" ]
    [ "$status" -eq 0 ]
}

@test "main --yes: патч применяется" {
    make_target_file "$TEST_FILE"
    _run_main "$TEST_FILE" --yes --file "'$TEST_FILE'"
    [ "$status" -eq 0 ]
    grep -Fq "_getNoSubKeyHtml:" "$TEST_FILE"
}

@test "main --yes: создаётся backup файл" {
    make_target_file "$TEST_FILE"
    _run_main "$TEST_FILE" --yes --file "'$TEST_FILE'"
    [ "$status" -eq 0 ]
    ls "${TEST_DIR}/"*.bak.* >/dev/null 2>&1
}

@test "main: выходит 0 если патч уже применён" {
    make_patched_file "$TEST_FILE"
    _run_main "$TEST_FILE" --yes --file "'$TEST_FILE'"
    [ "$status" -eq 0 ]
}

@test "main: выходит с ошибкой если сигнатура не найдена" {
    make_incompatible_file "$TEST_FILE"
    _run_main "$TEST_FILE" --yes --file "'$TEST_FILE'"
    [ "$status" -ne 0 ]
}

@test "main: выходит с ошибкой при дублирующейся сигнатуре" {
    make_duplicate_file "$TEST_FILE"
    _run_main "$TEST_FILE" --yes --file "'$TEST_FILE'"
    [ "$status" -ne 0 ]
}

@test "main: после патча оригинальная сигнатура отсутствует" {
    make_target_file "$TEST_FILE"
    _run_main "$TEST_FILE" --yes --file "'$TEST_FILE'"
    [ "$status" -eq 0 ]
    ! grep -P '(?<!_)getNoSubKeyHtml:' "$TEST_FILE"
}
