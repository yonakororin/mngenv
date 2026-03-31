#!/bin/bash
# =============================================================
# setup.sh — phpenv + PHP-FPM + nginx セットアップ TUI
#
# ダブルクリック or bash setup.sh で対話画面が起動します。
# 引数なしで起動するとプロジェクト一覧の編集画面が表示され、
# フォルダパス / PHP バージョン / サブドメイン名 を設定できます。
#
# 対応ディストリビューション:
#   Debian / Ubuntu / RHEL / CentOS / Rocky / Alma / Fedora
#   Arch / Manjaro / openSUSE / Alpine
# =============================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/.setup-projects.conf"
PHPENV_ROOT="${PHPENV_ROOT:-$HOME/.phpenv}"
NGINX_PORT="8080"

# ---- ログ関数 ----
info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
err()   { echo -e "\033[1;31m[ERR ]\033[0m $*" >&2; }
step()  { echo -e "\n\033[1;36m>>> $*\033[0m"; }

# =============================================================
# TUI: 画面描画ヘルパー
# =============================================================
ESC=$'\033'
CSI="${ESC}["

tui_clear()     { echo -ne "${CSI}2J${CSI}H"; }
tui_move()      { echo -ne "${CSI}${1};${2}H"; }  # row col
tui_bold()      { echo -ne "${CSI}1m$*${CSI}0m"; }
tui_dim()       { echo -ne "${CSI}2m$*${CSI}0m"; }
tui_cyan()      { echo -ne "${CSI}1;36m$*${CSI}0m"; }
tui_green()     { echo -ne "${CSI}1;32m$*${CSI}0m"; }
tui_yellow()    { echo -ne "${CSI}1;33m$*${CSI}0m"; }
tui_red()       { echo -ne "${CSI}1;31m$*${CSI}0m"; }
tui_reverse()   { echo -ne "${CSI}7m$*${CSI}0m"; }
tui_hide_cursor() { echo -ne "${CSI}?25l"; }
tui_show_cursor() { echo -ne "${CSI}?25h"; }
tui_erase_line()  { echo -ne "${CSI}2K"; }

# =============================================================
# TUI: プロジェクトデータ管理
# =============================================================
# 配列: PROJ_DIRS[], PROJ_PHPS[], PROJ_NAMES[]
declare -a PROJ_DIRS=()
declare -a PROJ_PHPS=()
declare -a PROJ_NAMES=()

# 設定ファイルから読み込み
load_projects() {
    PROJ_DIRS=()
    PROJ_PHPS=()
    PROJ_NAMES=()
    if [ -f "$CONFIG_FILE" ]; then
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            [[ "$line" == \#* ]] && continue
            # 設定値の復元
            if [[ "$line" == NGINX_PORT=* ]]; then
                NGINX_PORT="${line#NGINX_PORT=}"
                continue
            fi
            if [[ "$line" == PHPENV_ROOT=* ]]; then
                PHPENV_ROOT="${line#PHPENV_ROOT=}"
                continue
            fi
            # プロジェクト行
            IFS='|' read -r dir php name <<< "$line"
            [ -z "$dir" ] && continue
            PROJ_DIRS+=("$dir")
            PROJ_PHPS+=("$php")
            PROJ_NAMES+=("$name")
        done < "$CONFIG_FILE"
    fi
}

# 設定ファイルに書き出し
save_projects() {
    {
        echo "# setup-projects.conf"
        echo "# フォルダパス|PHPバージョン|サブドメイン名"
        echo "#"
        echo "NGINX_PORT=${NGINX_PORT}"
        echo "PHPENV_ROOT=${PHPENV_ROOT}"
        for i in "${!PROJ_DIRS[@]}"; do
            echo "${PROJ_DIRS[$i]}|${PROJ_PHPS[$i]}|${PROJ_NAMES[$i]}"
        done
    } > "$CONFIG_FILE"
}

# =============================================================
# TUI: インライン編集
# =============================================================
# 指定位置でテキストを編集し、結果を EDIT_RESULT に格納
EDIT_RESULT=""

tui_edit_field() {
    local row=$1 col=$2 width=$3 initial="$4"
    local buf="$initial"
    local cursor=${#buf}

    tui_show_cursor

    while true; do
        # 描画
        tui_move "$row" "$col"
        tui_erase_line
        tui_move "$row" "$col"

        # バッファ表示 (幅に収める)
        local display="$buf"
        if [ ${#display} -gt "$width" ]; then
            local start=$((cursor - width + 5))
            [ "$start" -lt 0 ] && start=0
            display="${buf:$start:$width}"
        fi
        echo -ne "${CSI}4m${display}${CSI}0m"

        # カーソル位置
        local screen_cursor=$((col + cursor))
        if [ ${#buf} -gt "$width" ]; then
            local start=$((cursor - width + 5))
            [ "$start" -lt 0 ] && start=0
            screen_cursor=$((col + cursor - start))
        fi
        tui_move "$row" "$screen_cursor"

        # キー入力
        IFS= read -rsn1 key
        case "$key" in
            $ESC)
                read -rsn2 -t 0.1 seq || true
                case "$seq" in
                    '[D')  # ←
                        [ "$cursor" -gt 0 ] && ((cursor--))
                        ;;
                    '[C')  # →
                        [ "$cursor" -lt ${#buf} ] && cursor=$((cursor + 1))
                        ;;
                    '[H'|'[1~')  # Home
                        cursor=0
                        ;;
                    '[F'|'[4~')  # End
                        cursor=${#buf}
                        ;;
                    '[3~')  # Delete
                        if [ "$cursor" -lt ${#buf} ]; then
                            buf="${buf:0:$cursor}${buf:$((cursor+1))}"
                        fi
                        ;;
                    *)
                        # ESC 単体 → キャンセル
                        if [ -z "$seq" ]; then
                            EDIT_RESULT="$initial"
                            tui_hide_cursor
                            return 1
                        fi
                        ;;
                esac
                ;;
            $'\x7f'|$'\b')  # Backspace
                if [ "$cursor" -gt 0 ]; then
                    buf="${buf:0:$((cursor-1))}${buf:$cursor}"
                    ((cursor--))
                fi
                ;;
            ''|$'\n')  # Enter → 確定
                EDIT_RESULT="$buf"
                tui_hide_cursor
                return 0
                ;;
            *)  # 通常文字
                buf="${buf:0:$cursor}${key}${buf:$cursor}"
                ((cursor++))
                ;;
        esac
    done
}

# =============================================================
# TUI: サービス状態管理
# =============================================================
_svc_status_nginx() {
    if command -v systemctl &>/dev/null && systemctl is-active nginx &>/dev/null 2>&1; then
        echo "active"
    elif command -v rc-service &>/dev/null && rc-service nginx status &>/dev/null 2>&1; then
        echo "active"
    else
        echo "stopped"
    fi
}

_svc_status_fpm() {
    local unit="$1"
    if command -v systemctl &>/dev/null && systemctl --user is-active "$unit" &>/dev/null 2>&1; then
        echo "active"
    elif command -v rc-service &>/dev/null && rc-service "$unit" status &>/dev/null 2>&1; then
        echo "active"
    else
        echo "stopped"
    fi
}

declare -a SVC_NAMES=()
declare -a SVC_UNITS=()
declare -a SVC_TYPES=()

build_service_list() {
    SVC_NAMES=("nginx")
    SVC_UNITS=("nginx")
    SVC_TYPES=("nginx")
    if [ -d "$PHPENV_ROOT/versions" ]; then
        for _ver_dir in "$PHPENV_ROOT/versions"/*/; do
            [ -d "$_ver_dir" ] || continue
            [ -x "${_ver_dir}sbin/php-fpm" ] || continue
            local _full_ver _short _unit
            _full_ver=$(basename "$_ver_dir")
            _short=$(echo "$_full_ver" | cut -d. -f1,2)
            _unit="php-fpm-$(echo "$_short" | tr -d '.')"
            SVC_NAMES+=("php-fpm ${_full_ver}")
            SVC_UNITS+=("$_unit")
            SVC_TYPES+=("fpm")
        done
    fi
}

toggle_service() {
    local idx="$1"
    local svc_type="${SVC_TYPES[$idx]}"
    local unit="${SVC_UNITS[$idx]}"
    local status
    tui_show_cursor
    if [ "$svc_type" = "nginx" ]; then
        status=$(_svc_status_nginx)
        if [ "$status" = "active" ]; then
            if command -v systemctl &>/dev/null; then
                sudo systemctl stop nginx 2>/dev/null || true
            else
                sudo rc-service nginx stop 2>/dev/null || true
            fi
        else
            if command -v systemctl &>/dev/null; then
                sudo systemctl start nginx 2>/dev/null || true
            else
                sudo rc-service nginx start 2>/dev/null || true
            fi
        fi
    else
        status=$(_svc_status_fpm "$unit")
        if [ "$status" = "active" ]; then
            if command -v systemctl &>/dev/null; then
                systemctl --user stop "$unit" 2>/dev/null || true
            else
                sudo rc-service "$unit" stop 2>/dev/null || true
            fi
        else
            if command -v systemctl &>/dev/null; then
                systemctl --user start "$unit" 2>/dev/null || true
            else
                sudo rc-service "$unit" start 2>/dev/null || true
            fi
        fi
    fi
    sleep 0.3
    tui_hide_cursor
}

# =============================================================
# TUI: メイン画面
# =============================================================
tui_main() {
    local cursor_row=0       # 選択中の行
    local cursor_col=0       # 選択中の列 (0=dir, 1=php, 2=name)
    local col_names=("フォルダパス" "PHPバージョン" "サブドメイン名")
    local cursor_section="projects"  # "projects" or "services"
    local cursor_service=0           # 選択中のサービス行

    load_projects

    # 初期エントリがなければ1行追加
    if [ ${#PROJ_DIRS[@]} -eq 0 ]; then
        PROJ_DIRS+=("$HOME/projects/my-app")
        PROJ_PHPS+=("8.3.8")
        PROJ_NAMES+=("my-app")
    fi

    tui_hide_cursor

    while true; do
        tui_clear

        # ---- ヘッダ ----
        tui_move 1 1
        tui_cyan "╔════════════════════════════════════════════════════════════════════════════════════════════════════════════╗"
        tui_move 2 1
        tui_cyan "║"
        tui_move 2 3
        tui_bold "  phpenv + PHP-FPM + nginx セットアップ"
        tui_move 2 110
        tui_cyan "║"
        tui_move 3 1
        tui_cyan "╠════════════════════════════════════════════════════════════════════════════════════════════════════════════╣"

        # ---- 設定値 ----
        tui_move 4 1
        tui_cyan "║"
        tui_move 4 3
        tui_dim "PHPENV_ROOT: $PHPENV_ROOT    nginx port: $NGINX_PORT"
        tui_move 4 110
        tui_cyan "║"
        tui_move 5 1
        tui_cyan "╠════════════════════════════════════════════════════════════════════════════════════════════════════════════╣"

        # ---- テーブルヘッダ ----
        tui_move 6 1
        tui_cyan "║"
        tui_move 6 3
        printf "\033[1m  %-42s %-12s %-18s %-28s\033[0m" "フォルダパス" "PHPバージョン" "サブドメイン名" "URL"
        tui_move 6 110
        tui_cyan "║"
        tui_move 7 1
        tui_cyan "║"
        tui_move 7 3
        echo -n "  ────────────────────────────────────────── ──────────── ────────────────── ────────────────────────────"
        tui_move 7 110
        tui_cyan "║"

        # ---- テーブル本体 ----
        local row_start=8
        for i in "${!PROJ_DIRS[@]}"; do
            local r=$((row_start + i))
            tui_move "$r" 1
            tui_cyan "║"
            tui_move "$r" 110
            tui_cyan "║"

            local url="http://${PROJ_NAMES[$i]}.localhost:${NGINX_PORT}"
            local fields=("${PROJ_DIRS[$i]}" "${PROJ_PHPS[$i]}" "${PROJ_NAMES[$i]}" "$url")
            local cols=(5 48 61 80)
            local widths=(42 12 18 28)

            for c in 0 1 2 3; do
                tui_move "$r" "${cols[$c]}"
                local val="${fields[$c]}"
                # 幅に収める
                if [ ${#val} -gt "${widths[$c]}" ]; then
                    val="${val:0:$((${widths[$c]}-2))}.."
                fi
                if [ "$c" -eq 3 ]; then
                    # URL は表示のみ（編集不可）
                    tui_dim "$(printf "%-${widths[$c]}s" "$val")"
                elif [ "$i" -eq "$cursor_row" ] && [ "$c" -eq "$cursor_col" ]; then
                    tui_reverse "$(printf "%-${widths[$c]}s" "$val")"
                else
                    printf "%-${widths[$c]}s" "$val"
                fi
            done
        done

        # ---- プロジェクトテーブル下部罫線 ----
        local bottom=$((row_start + ${#PROJ_DIRS[@]}))
        tui_move "$bottom" 1
        tui_cyan "╠════════════════════════════════════════════════════════════════════════════════════════════════════════════╣"

        # ---- サービスセクション ----
        build_service_list
        local svc_hdr=$((bottom + 1))
        tui_move "$svc_hdr" 1; tui_cyan "║"
        tui_move "$svc_hdr" 110; tui_cyan "║"
        tui_move "$svc_hdr" 3
        printf "\033[1m  %-22s %-12s %s\033[0m" "サービス" "状態" "操作"

        local svc_sep=$((svc_hdr + 1))
        tui_move "$svc_sep" 1; tui_cyan "║"
        tui_move "$svc_sep" 110; tui_cyan "║"
        tui_move "$svc_sep" 3
        echo -n "  ──────────────────────── ──────────── ──────"

        local svc_row_start=$((svc_sep + 1))
        local si
        for si in "${!SVC_NAMES[@]}"; do
            local sr=$((svc_row_start + si))
            tui_move "$sr" 1; tui_cyan "║"
            tui_move "$sr" 110; tui_cyan "║"

            local svc_status
            if [ "${SVC_TYPES[$si]}" = "nginx" ]; then
                svc_status=$(_svc_status_nginx)
            else
                svc_status=$(_svc_status_fpm "${SVC_UNITS[$si]}")
            fi

            local svc_action
            [ "$svc_status" = "active" ] && svc_action="[停止]" || svc_action="[起動]"

            tui_move "$sr" 5
            if [ "$cursor_section" = "services" ] && [ "$si" -eq "$cursor_service" ]; then
                tui_reverse "$(printf "%-24s" "${SVC_NAMES[$si]}")"
            else
                printf "%-24s" "${SVC_NAMES[$si]}"
            fi

            tui_move "$sr" 30
            if [ "$svc_status" = "active" ]; then
                tui_green "● active  "
            else
                tui_red   "○ stopped "
            fi

            tui_move "$sr" 41
            if [ "$cursor_section" = "services" ] && [ "$si" -eq "$cursor_service" ]; then
                tui_reverse "$svc_action"
            else
                echo -n "$svc_action"
            fi
        done

        local svc_bottom=$((svc_row_start + ${#SVC_NAMES[@]}))
        tui_move "$svc_bottom" 1
        tui_cyan "╠════════════════════════════════════════════════════════════════════════════════════════════════════════════╣"

        # ---- 操作ガイド ----
        local guide=$((svc_bottom + 1))
        tui_move "$guide" 1
        tui_cyan "║"
        tui_move "$guide" 110
        tui_cyan "║"
        tui_move "$guide" 3
        echo -n "  "
        tui_bold "↑↓←→"
        echo -n " 移動  "
        tui_bold "Enter"
        echo -n " 編集/起動停止  "
        tui_bold "a"
        echo -n " 追加  "
        tui_bold "d"
        echo -n " 削除  "
        tui_bold "p"
        echo -n " ポート変更"

        local guide2=$((guide + 1))
        tui_move "$guide2" 1
        tui_cyan "║"
        tui_move "$guide2" 110
        tui_cyan "║"
        tui_move "$guide2" 3
        echo -n "  "
        tui_bold "F5/r"
        echo -n " PHPENV_ROOT変更  "
        tui_bold "F10/x"
        echo -n " 実行  "
        tui_bold "q/ESC"
        echo -n " 終了"

        local guide3=$((guide2 + 1))
        tui_move "$guide3" 1
        tui_cyan "╚════════════════════════════════════════════════════════════════════════════════════════════════════════════╝"

        # ---- キー入力 ----
        IFS= read -rsn1 key
        case "$key" in
            $ESC)
                read -rsn2 -t 0.1 seq || true
                case "$seq" in
                    '[A')  # ↑
                        if [ "$cursor_section" = "projects" ]; then
                            [ "$cursor_row" -gt 0 ] && ((cursor_row--))
                        else
                            if [ "$cursor_service" -gt 0 ]; then
                                ((cursor_service--))
                            else
                                cursor_section="projects"
                                cursor_row=$((${#PROJ_DIRS[@]} - 1))
                            fi
                        fi
                        ;;
                    '[B')  # ↓
                        if [ "$cursor_section" = "projects" ]; then
                            if [ "$cursor_row" -lt $((${#PROJ_DIRS[@]} - 1)) ]; then
                                cursor_row=$((cursor_row + 1))
                            else
                                cursor_section="services"
                                cursor_service=0
                            fi
                        else
                            [ "$cursor_service" -lt $((${#SVC_NAMES[@]} - 1)) ] && cursor_service=$((cursor_service + 1))
                        fi
                        ;;
                    '[D')  # ←
                        [ "$cursor_section" = "projects" ] && [ "$cursor_col" -gt 0 ] && ((cursor_col--))
                        ;;
                    '[C')  # →
                        [ "$cursor_section" = "projects" ] && [ "$cursor_col" -lt 2 ] && cursor_col=$((cursor_col + 1))
                        ;;
                    '[15~')  # F5
                        tui_edit_phpenv_root
                        save_projects
                        ;;
                    '[21~')  # F10
                        save_projects
                        tui_show_cursor
                        return 0
                        ;;
                    '')  # ESC 単体
                        tui_show_cursor
                        tui_clear
                        echo "中止しました"
                        exit 0
                        ;;
                esac
                ;;
            ''|$'\n')  # Enter → セル編集 / サービス起動停止
                if [ "$cursor_section" = "projects" ]; then
                    tui_edit_cell "$cursor_row" "$cursor_col"
                    save_projects
                else
                    toggle_service "$cursor_service"
                fi
                ;;
            'a'|'A')  # 追加
                PROJ_DIRS+=("$HOME/projects/new-project")
                PROJ_PHPS+=("8.3.8")
                PROJ_NAMES+=("new-project")
                cursor_row=$((${#PROJ_DIRS[@]} - 1))
                cursor_col=0
                save_projects
                ;;
            'd'|'D')  # 削除
                if [ ${#PROJ_DIRS[@]} -gt 1 ]; then
                    local tmp_dirs=() tmp_phps=() tmp_names=()
                    for i in "${!PROJ_DIRS[@]}"; do
                        [ "$i" -eq "$cursor_row" ] && continue
                        tmp_dirs+=("${PROJ_DIRS[$i]}")
                        tmp_phps+=("${PROJ_PHPS[$i]}")
                        tmp_names+=("${PROJ_NAMES[$i]}")
                    done
                    PROJ_DIRS=("${tmp_dirs[@]}")
                    PROJ_PHPS=("${tmp_phps[@]}")
                    PROJ_NAMES=("${tmp_names[@]}")
                    [ "$cursor_row" -ge ${#PROJ_DIRS[@]} ] && ((cursor_row--))
                    save_projects
                fi
                ;;
            'p'|'P')  # ポート変更
                tui_edit_port
                save_projects
                ;;
            'r'|'R')  # PHPENV_ROOT 変更
                tui_edit_phpenv_root
                save_projects
                ;;
            'x'|'X')  # 実行
                save_projects
                tui_show_cursor
                return 0
                ;;
            'q'|'Q')  # 終了
                tui_show_cursor
                tui_clear
                echo "中止しました"
                exit 0
                ;;
        esac
    done
}

# セル編集
tui_edit_cell() {
    local row=$1 col=$2
    local r=$((8 + row))
    local cols=(5 48 61)
    local widths=(42 12 18)

    local current=""
    case "$col" in
        0) current="${PROJ_DIRS[$row]}" ;;
        1) current="${PROJ_PHPS[$row]}" ;;
        2) current="${PROJ_NAMES[$row]}" ;;
    esac

    if tui_edit_field "$r" "${cols[$col]}" "${widths[$col]}" "$current"; then
        case "$col" in
            0) PROJ_DIRS[$row]="$EDIT_RESULT" ;;
            1) PROJ_PHPS[$row]="$EDIT_RESULT" ;;
            2) PROJ_NAMES[$row]="$EDIT_RESULT" ;;
        esac
    fi
}

# ポート変更
tui_edit_port() {
    local bottom=$((8 + ${#PROJ_DIRS[@]} + 3))
    tui_move "$bottom" 3
    tui_erase_line
    tui_move "$bottom" 3
    echo -ne "  nginx ポート [$NGINX_PORT]: "
    tui_show_cursor
    local input
    read -r input
    tui_hide_cursor
    if [[ "$input" =~ ^[0-9]+$ ]] && [ "$input" -ge 1 ] && [ "$input" -le 65535 ]; then
        NGINX_PORT="$input"
    fi
}

# PHPENV_ROOT 変更
tui_edit_phpenv_root() {
    local bottom=$((8 + ${#PROJ_DIRS[@]} + 3))
    tui_move "$bottom" 3
    tui_erase_line
    tui_move "$bottom" 3
    echo -ne "  PHPENV_ROOT [$PHPENV_ROOT]: "
    tui_show_cursor
    local input
    read -r input
    tui_hide_cursor
    if [ -n "$input" ]; then
        PHPENV_ROOT="$(realpath -m "$input")"
    fi
}

# =============================================================
# 0. ディストリビューション検出
# =============================================================
DISTRO_FAMILY=""
PKG_MANAGER=""
INIT_SYSTEM=""

detect_distro() {
    step "ディストリビューション検出"

    if [ ! -f /etc/os-release ]; then
        err "/etc/os-release が見つかりません。対応外の環境です。"
        exit 1
    fi

    source /etc/os-release

    case "${ID:-}" in
        debian|ubuntu|linuxmint|pop|kali|raspbian)
            DISTRO_FAMILY="debian"; PKG_MANAGER="apt" ;;
        rhel|centos|rocky|almalinux|ol)
            DISTRO_FAMILY="rhel"
            command -v dnf &>/dev/null && PKG_MANAGER="dnf" || PKG_MANAGER="yum"
            ;;
        fedora)
            DISTRO_FAMILY="rhel"; PKG_MANAGER="dnf" ;;
        arch|manjaro|endeavouros)
            DISTRO_FAMILY="arch"; PKG_MANAGER="pacman" ;;
        opensuse*|sles)
            DISTRO_FAMILY="suse"; PKG_MANAGER="zypper" ;;
        alpine)
            DISTRO_FAMILY="alpine"; PKG_MANAGER="apk" ;;
        *)
            case "${ID_LIKE:-}" in
                *debian*|*ubuntu*)  DISTRO_FAMILY="debian"; PKG_MANAGER="apt" ;;
                *rhel*|*centos*|*fedora*)
                    DISTRO_FAMILY="rhel"
                    command -v dnf &>/dev/null && PKG_MANAGER="dnf" || PKG_MANAGER="yum"
                    ;;
                *arch*)   DISTRO_FAMILY="arch";  PKG_MANAGER="pacman" ;;
                *suse*)   DISTRO_FAMILY="suse";  PKG_MANAGER="zypper" ;;
                *)
                    err "未対応のディストリビューション: ${ID:-unknown}"
                    exit 1 ;;
            esac ;;
    esac

    if command -v systemctl &>/dev/null && [ -d /run/systemd/system ]; then
        INIT_SYSTEM="systemd"
    elif command -v rc-service &>/dev/null; then
        INIT_SYSTEM="openrc"
    else
        INIT_SYSTEM="unknown"
    fi

    ok "ディストリ: ${PRETTY_NAME:-$ID} (pkg=$PKG_MANAGER, init=$INIT_SYSTEM)"
}

# =============================================================
# パッケージインストール (ディストリ別)
# =============================================================
pkg_install() {
    local packages=("$@")
    case "$PKG_MANAGER" in
        apt)    sudo apt-get update -qq; sudo apt-get install -y --no-install-recommends "${packages[@]}" ;;
        dnf)    sudo dnf install -y "${packages[@]}" ;;
        yum)    sudo yum install -y "${packages[@]}" ;;
        pacman) sudo pacman -Sy --noconfirm --needed "${packages[@]}" ;;
        zypper) sudo zypper install -y "${packages[@]}" ;;
        apk)    sudo apk add --no-cache "${packages[@]}" ;;
    esac
}

# =============================================================
# 1. phpenv / php-build
# =============================================================
setup_phpenv() {
    step "phpenv 確認"

    if ! command -v git &>/dev/null; then
        info "git をインストール中..."
        pkg_install git
    fi

    if [ -d "$PHPENV_ROOT" ] && [ -x "$PHPENV_ROOT/bin/phpenv" ]; then
        ok "phpenv 検出: $PHPENV_ROOT"
    else
        info "phpenv をインストール中..."
        git clone https://github.com/phpenv/phpenv.git "$PHPENV_ROOT"
        ok "phpenv インストール完了"
    fi

    if [ -x "$PHPENV_ROOT/plugins/php-build/bin/phpenv-install" ]; then
        ok "php-build 検出"
    else
        if [ -d "$PHPENV_ROOT/plugins/php-build" ]; then
            warn "php-build が不完全です。再インストール中..."
            rm -rf "$PHPENV_ROOT/plugins/php-build"
        else
            info "php-build をインストール中..."
        fi
        git clone https://github.com/php-build/php-build.git "$PHPENV_ROOT/plugins/php-build"
        ok "php-build インストール完了"
    fi

    export PHPENV_ROOT
    export PATH="$PHPENV_ROOT/bin:$PHPENV_ROOT/shims:$PATH"

    local shell_rc="$HOME/.bashrc"
    [ -f "$HOME/.zshrc" ] && [ ! -f "$HOME/.bashrc" ] && shell_rc="$HOME/.zshrc"
    if ! grep -q 'PHPENV_ROOT' "$shell_rc" 2>/dev/null; then
        cat >> "$shell_rc" << EOF

# --- phpenv ---
export PHPENV_ROOT="${PHPENV_ROOT}"
export PATH="\$PHPENV_ROOT/bin:\$PATH"
eval "\$(phpenv init -)"
EOF
        ok "$shell_rc に phpenv 設定を追加"
    fi
}

# =============================================================
# 2. ビルド依存パッケージ
# =============================================================
install_deps() {
    step "ビルド依存パッケージ ($DISTRO_FAMILY / $PKG_MANAGER)"

    local marker="$PHPENV_ROOT/.deps-installed-${DISTRO_FAMILY}"
    if [ -f "$marker" ]; then
        ok "依存パッケージはインストール済み"
        return 0
    fi

    info "ビルド依存パッケージをインストール中..."

    case "$DISTRO_FAMILY" in
        debian)
            pkg_install build-essential pkg-config autoconf bison re2c \
                libxml2-dev libsqlite3-dev libcurl4-openssl-dev \
                libonig-dev libreadline-dev libzip-dev \
                libpng-dev libjpeg-dev libfreetype-dev \
                libssl-dev libsystemd-dev libmysqlclient-dev libffi-dev ;;
        rhel)
            if [ "$PKG_MANAGER" = "dnf" ]; then
                sudo dnf groupinstall -y "Development Tools" 2>/dev/null || true
                sudo dnf install -y epel-release 2>/dev/null || true
            else
                sudo yum groupinstall -y "Development Tools" 2>/dev/null || true
                sudo yum install -y epel-release 2>/dev/null || true
            fi
            pkg_install autoconf bison re2c pkgconfig \
                libxml2-devel sqlite-devel libcurl-devel \
                oniguruma-devel readline-devel libzip-devel \
                libpng-devel libjpeg-turbo-devel freetype-devel \
                openssl-devel systemd-devel mysql-devel libffi-devel ;;
        arch)
            pkg_install base-devel autoconf bison re2c \
                libxml2 sqlite curl oniguruma readline libzip \
                libpng libjpeg-turbo freetype2 openssl systemd-libs mariadb-libs libffi ;;
        suse)
            sudo zypper install -y -t pattern devel_C_C++ 2>/dev/null || true
            pkg_install autoconf bison re2c pkg-config \
                libxml2-devel sqlite3-devel libcurl-devel \
                oniguruma-devel readline-devel libzip-devel \
                libpng16-devel libjpeg8-devel freetype2-devel \
                libopenssl-devel systemd-devel libmysqlclient-devel libffi-devel ;;
        alpine)
            pkg_install build-base autoconf bison re2c pkgconfig \
                libxml2-dev sqlite-dev curl-dev oniguruma-dev readline-dev libzip-dev \
                libpng-dev libjpeg-turbo-dev freetype-dev openssl-dev linux-headers mariadb-dev libffi-dev ;;
    esac

    touch "$marker"
    ok "依存パッケージ インストール完了"
}

# =============================================================
# 3. PHP ビルド
# =============================================================
build_php() {
    local PHP_VERSION="$1"

    step "PHP $PHP_VERSION ビルド"

    local configure_opts="--enable-fpm --enable-mbstring --enable-opcache \
        --with-curl --with-openssl --with-readline --with-zip \
        --with-mysqli --with-pdo-mysql --enable-gd --with-freetype --with-jpeg \
        --enable-pcntl --enable-sockets --enable-bcmath --with-ffi"
    [ "$DISTRO_FAMILY" != "alpine" ] && [ "$INIT_SYSTEM" = "systemd" ] && \
        configure_opts+=" --with-fpm-systemd"

    local opts_hash hash_file
    opts_hash=$(echo "$configure_opts" | md5sum | cut -d' ' -f1)
    hash_file="$PHPENV_ROOT/versions/$PHP_VERSION/.configure-opts.md5"

    if [ -x "$PHPENV_ROOT/versions/$PHP_VERSION/sbin/php-fpm" ]; then
        if [ -f "$hash_file" ] && [ "$(cat "$hash_file")" = "$opts_hash" ]; then
            ok "PHP $PHP_VERSION は既にビルド済み"
            return 0
        fi
        warn "PHP $PHP_VERSION のビルドオプションが変更されました。再ビルドします..."
        if [ -x "$PHPENV_ROOT/bin/phpenv" ]; then
            "$PHPENV_ROOT/bin/phpenv" uninstall --force "$PHP_VERSION" 2>/dev/null || \
                rm -rf "$PHPENV_ROOT/versions/$PHP_VERSION"
        else
            rm -rf "$PHPENV_ROOT/versions/$PHP_VERSION"
        fi
        ok "PHP $PHP_VERSION を削除しました"
    elif [ -d "$PHPENV_ROOT/versions/$PHP_VERSION" ]; then
        warn "PHP $PHP_VERSION に php-fpm が含まれていません。既存バージョンを削除して再ビルドします..."
        if [ -x "$PHPENV_ROOT/bin/phpenv" ]; then
            "$PHPENV_ROOT/bin/phpenv" uninstall --force "$PHP_VERSION" 2>/dev/null || \
                rm -rf "$PHPENV_ROOT/versions/$PHP_VERSION"
        else
            rm -rf "$PHPENV_ROOT/versions/$PHP_VERSION"
        fi
        ok "PHP $PHP_VERSION を削除しました"
    fi

    # 定義ファイルの確認・自動取得
    local defs_dir="$PHPENV_ROOT/plugins/php-build/share/php-build/definitions"
    if [ ! -f "$defs_dir/$PHP_VERSION" ]; then
        info "定義が見つかりません。php-build を更新中..."
        (cd "$PHPENV_ROOT/plugins/php-build" && git pull --quiet 2>/dev/null) || true

        if [ ! -f "$defs_dir/$PHP_VERSION" ]; then
            info "定義ファイルを自動生成..."
            local major_minor
            major_minor=$(echo "$PHP_VERSION" | cut -d. -f1,2)
            local base_def
            base_def=$(ls "$defs_dir" 2>/dev/null | grep -E "^${major_minor}\.[0-9]+$" | sort -V | tail -1 || true)
            if [ -n "$base_def" ] && [ -f "$defs_dir/$base_def" ]; then
                sed "s/${base_def}/${PHP_VERSION}/g" "$defs_dir/$base_def" > "$defs_dir/$PHP_VERSION"
                ok "定義を生成: $base_def → $PHP_VERSION"
            else
                err "PHP $PHP_VERSION の定義を生成できません"
                exit 1
            fi
        fi
    fi

    export PHP_BUILD_CONFIGURE_OPTS="$configure_opts"

    if [ ! -x "$PHPENV_ROOT/plugins/php-build/bin/phpenv-install" ]; then
        err "php-build プラグインが見つかりません。setup.sh を再実行するか、手動で以下を実行してください:"
        err "  git clone https://github.com/php-build/php-build.git $PHPENV_ROOT/plugins/php-build"
        exit 1
    fi

    info "ビルド中... (数分かかります)"
    "$PHPENV_ROOT/bin/phpenv" install "$PHP_VERSION"
    "$PHPENV_ROOT/bin/phpenv" rehash
    echo "$opts_hash" > "$hash_file"
    ok "PHP $PHP_VERSION ビルド完了"
}

# =============================================================
# 4. php-fpm 設定 + サービス登録
# =============================================================
setup_fpm() {
    local PHP_VERSION="$1"
    local SHORT_VER SHORT_NUM FPM_PORT UNIT_NAME
    SHORT_VER=$(echo "$PHP_VERSION" | cut -d. -f1,2)
    SHORT_NUM=$(echo "$SHORT_VER" | tr -d '.')
    FPM_PORT="90${SHORT_NUM}"
    UNIT_NAME="php-fpm-${SHORT_NUM}"

    step "PHP-FPM $PHP_VERSION (port $FPM_PORT)"

    local ver_dir="$PHPENV_ROOT/versions/$PHP_VERSION"
    mkdir -p "$ver_dir/var/run" "$ver_dir/var/log" "$ver_dir/etc/php-fpm.d"

    cat > "$ver_dir/etc/php-fpm.conf" << EOF
[global]
pid = ${ver_dir}/var/run/php-fpm.pid
error_log = ${ver_dir}/var/log/php-fpm.log
daemonize = no
include = ${ver_dir}/etc/php-fpm.d/*.conf
EOF

    cat > "$ver_dir/etc/php-fpm.d/www.conf" << EOF
[www]
user = $(whoami)
group = $(id -gn)
listen = 127.0.0.1:${FPM_PORT}
pm = dynamic
pm.max_children = 10
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 4
catch_workers_output = yes
decorate_workers_output = no
access.log = ${ver_dir}/var/log/access.log
slowlog = ${ver_dir}/var/log/slow.log
request_slowlog_timeout = 5s
EOF

    if [ ! -f "$ver_dir/etc/php.ini" ]; then
        for c in "$ver_dir/etc/php.ini-development" "$ver_dir/lib/php.ini-development"; do
            [ -f "$c" ] && cp "$c" "$ver_dir/etc/php.ini" && break
        done
    fi

    ok "php-fpm 設定完了"

    # systemd サービス
    if [ "$INIT_SYSTEM" = "systemd" ]; then
        mkdir -p "$HOME/.config/systemd/user"
        cat > "$HOME/.config/systemd/user/${UNIT_NAME}.service" << EOF
[Unit]
Description=PHP-FPM ${PHP_VERSION} (port ${FPM_PORT})
After=network.target
[Service]
Type=simple
ExecStart=${ver_dir}/sbin/php-fpm --fpm-config ${ver_dir}/etc/php-fpm.conf --nodaemonize
ExecReload=/bin/kill -USR2 \$MAINPID
Restart=on-failure
RestartSec=5
[Install]
WantedBy=default.target
EOF
        systemctl --user daemon-reload
        if systemctl --user is-active "$UNIT_NAME" &>/dev/null; then
            systemctl --user restart "$UNIT_NAME"
            ok "$UNIT_NAME 再起動"
        else
            systemctl --user enable --now "$UNIT_NAME"
            ok "$UNIT_NAME 起動"
        fi
        loginctl enable-linger "$(whoami)" 2>/dev/null || true

    elif [ "$INIT_SYSTEM" = "openrc" ]; then
        local init_script="/etc/init.d/${UNIT_NAME}"
        sudo tee "$init_script" > /dev/null << EOF
#!/sbin/openrc-run
name="PHP-FPM ${PHP_VERSION}"
command="${ver_dir}/sbin/php-fpm"
command_args="--fpm-config ${ver_dir}/etc/php-fpm.conf --nodaemonize"
command_background=true
pidfile="${ver_dir}/var/run/php-fpm.pid"
depend() { need net; }
EOF
        sudo chmod +x "$init_script"
        sudo rc-update add "$UNIT_NAME" default 2>/dev/null || true
        sudo rc-service "$UNIT_NAME" restart
        ok "$UNIT_NAME 起動 (OpenRC)"
    fi
}

# =============================================================
# 5. nginx インストール
# =============================================================
install_nginx() {
    step "nginx インストール確認"

    if ! command -v lsof &>/dev/null; then
        info "lsof をインストール中..."
        pkg_install lsof
    fi

    if command -v nginx &>/dev/null; then
        ok "nginx 検出: $(nginx -v 2>&1)"
        return 0
    fi

    info "nginx をインストール中..."
    pkg_install nginx

    case "$INIT_SYSTEM" in
        systemd) sudo systemctl enable nginx 2>/dev/null || true ;;
        openrc)  sudo rc-update add nginx default 2>/dev/null || true ;;
    esac

    ok "nginx インストール完了"
}

# =============================================================
# 6. nginx vhost 設定 (1プロジェクト分)
# =============================================================
setup_nginx_vhost() {
    local PHP_VERSION="$1"
    local PROJECT_DIR="$2"
    local SERVER_HOSTNAME="$3"

    local SHORT_NUM
    SHORT_NUM=$(echo "$PHP_VERSION" | cut -d. -f1,2 | tr -d '.')
    local upstream_name="php${SHORT_NUM}"
    local FPM_PORT="90${SHORT_NUM}"

    # nginx conf.d ディレクトリ検出
    local nginx_conf_dir=""
    for candidate in /etc/nginx/conf.d /etc/nginx/http.d; do
        [ -d "$candidate" ] && nginx_conf_dir="$candidate" && break
    done
    if [ -z "$nginx_conf_dir" ]; then
        nginx_conf_dir="/etc/nginx/conf.d"
        sudo mkdir -p "$nginx_conf_dir"
    fi

    # ドキュメントルート
    local docroot="$PROJECT_DIR"
    [ -d "$PROJECT_DIR/webroot" ] && docroot="$PROJECT_DIR/webroot"

    # upstream
    local upstream_file="${nginx_conf_dir}/${upstream_name}-upstream.conf"
    if [ ! -f "$upstream_file" ]; then
        sudo tee "$upstream_file" > /dev/null << EOF
upstream ${upstream_name} {
    server 127.0.0.1:${FPM_PORT};
}
EOF
        ok "upstream ${upstream_name} → :${FPM_PORT}"
    fi

    # 旧ホスト名の掃除
    if [ -f "$PROJECT_DIR/.setup-hostname" ]; then
        local prev_hostname
        prev_hostname=$(cat "$PROJECT_DIR/.setup-hostname")
        if [ "$prev_hostname" != "$SERVER_HOSTNAME" ]; then
            local old_conf
            old_conf=$(echo "$prev_hostname" | tr '.' '-')
            sudo rm -f "${nginx_conf_dir}/${old_conf}.conf"
            info "旧 vhost 削除: ${old_conf}.conf"
        fi
    fi

    # server ブロック
    local conf_name
    conf_name=$(echo "$SERVER_HOSTNAME" | tr '.' '-')
    sudo tee "${nginx_conf_dir}/${conf_name}.conf" > /dev/null << EOF
server {
    listen ${NGINX_PORT};
    server_name ${SERVER_HOSTNAME};
    root ${docroot};
    index index.php index.html;

    access_log /var/log/nginx/${conf_name}-access.log;
    error_log  /var/log/nginx/${conf_name}-error.log;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        fastcgi_pass ${upstream_name};
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_read_timeout 300;
    }

    location ~ /\.(ht|git) {
        deny all;
    }
}
EOF

    # /etc/hosts
    if ! grep -q "$SERVER_HOSTNAME" /etc/hosts 2>/dev/null; then
        echo "127.0.0.1  $SERVER_HOSTNAME" | sudo tee -a /etc/hosts > /dev/null
    fi

    ok "vhost: $SERVER_HOSTNAME → $docroot (PHP $PHP_VERSION)"
}

# nginx リロード
reload_nginx() {
    # default site 無効化
    [ -L /etc/nginx/sites-enabled/default ] && sudo rm -f /etc/nginx/sites-enabled/default
    [ ! -d /var/log/nginx ] && sudo mkdir -p /var/log/nginx

    if sudo nginx -t 2>/dev/null; then
        case "$INIT_SYSTEM" in
            systemd)
                if systemctl is-active nginx &>/dev/null; then
                    sudo systemctl reload nginx
                else
                    sudo systemctl start nginx
                fi ;;
            openrc)
                if rc-service nginx status &>/dev/null; then
                    sudo rc-service nginx reload
                else
                    sudo rc-service nginx start
                fi ;;
            *)  sudo nginx -s reload 2>/dev/null || sudo nginx ;;
        esac
        ok "nginx リロード完了"
    else
        err "nginx 設定テストに失敗:"
        sudo nginx -t
        exit 1
    fi
}

# =============================================================
# 7. プロジェクト設定
# =============================================================
setup_project() {
    local PHP_VERSION="$1"
    local PROJECT_DIR="$2"
    local SERVER_HOSTNAME="$3"

    mkdir -p "$PROJECT_DIR"

    # .php-version
    local prev=""
    [ -f "$PROJECT_DIR/.php-version" ] && prev=$(cat "$PROJECT_DIR/.php-version")
    echo "$PHP_VERSION" > "$PROJECT_DIR/.php-version"
    if [ -n "$prev" ] && [ "$prev" != "$PHP_VERSION" ]; then
        ok ".php-version: $prev → $PHP_VERSION"
    else
        ok ".php-version → $PHP_VERSION"
    fi

    echo "$SERVER_HOSTNAME" > "$PROJECT_DIR/.setup-hostname"

    # webroot
    [ ! -d "$PROJECT_DIR/webroot" ] && mkdir -p "$PROJECT_DIR/webroot"

    # テストページ
    if [ ! -f "$PROJECT_DIR/webroot/index.php" ]; then
        cat > "$PROJECT_DIR/webroot/index.php" << 'PHPTEST'
<?php
echo "<h1>" . php_uname('n') . "</h1>";
echo "<p>PHP " . phpversion() . "</p>";
echo "<pre>"; print_r(get_loaded_extensions()); echo "</pre>";
PHPTEST
    fi
}

# =============================================================
# 8. CLI ラッパー
# =============================================================
install_cli_wrapper() {
    step "CLI ラッパー"

    mkdir -p "$HOME/.local/bin"

    # php ラッパー
    cat > "$HOME/.local/bin/php" << 'WRAPPER'
#!/bin/bash
set -euo pipefail
PHPENV_ROOT="${PHPENV_ROOT:-__PHPENV_ROOT_PLACEHOLDER__}"
resolve_version() {
    local dir="$PWD"
    while [ "$dir" != "/" ]; do
        [ -f "$dir/.php-version" ] && cat "$dir/.php-version" && return 0
        dir="$(dirname "$dir")"
    done
    [ -f "$PHPENV_ROOT/version" ] && cat "$PHPENV_ROOT/version" && return 0
    return 1
}
if VERSION="$(resolve_version)"; then
    PHP_BIN="$PHPENV_ROOT/versions/$VERSION/bin/php"
    [ -x "$PHP_BIN" ] && exec "$PHP_BIN" "$@"
    echo "Error: PHP $VERSION not installed" >&2; exit 1
fi
SYSTEM_PHP="$(command -v php.orig 2>/dev/null || command -v /usr/bin/php 2>/dev/null || true)"
[ -n "$SYSTEM_PHP" ] && [ -x "$SYSTEM_PHP" ] && exec "$SYSTEM_PHP" "$@"
echo "Error: PHP not found" >&2; exit 1
WRAPPER
    chmod +x "$HOME/.local/bin/php"
    sed -i "s|__PHPENV_ROOT_PLACEHOLDER__|${PHPENV_ROOT}|g" "$HOME/.local/bin/php"

    # composer ラッパー
    cat > "$HOME/.local/bin/composer" << 'WRAPPER'
#!/bin/bash
set -euo pipefail
PHPENV_ROOT="${PHPENV_ROOT:-__PHPENV_ROOT_PLACEHOLDER__}"
resolve_version() {
    local dir="$PWD"
    while [ "$dir" != "/" ]; do
        [ -f "$dir/.php-version" ] && cat "$dir/.php-version" && return 0
        dir="$(dirname "$dir")"
    done
    [ -f "$PHPENV_ROOT/version" ] && cat "$PHPENV_ROOT/version" && return 0
    return 1
}
if VERSION="$(resolve_version)"; then
    VER_DIR="$PHPENV_ROOT/versions/$VERSION"
    PHP_BIN="$VER_DIR/bin/php"
    [ ! -x "$PHP_BIN" ] && echo "Error: PHP $VERSION not installed" >&2 && exit 1
    [ -x "$VER_DIR/bin/composer" ] && exec "$PHP_BIN" "$VER_DIR/bin/composer" "$@"
    for c in "$PHPENV_ROOT/composer.phar" "$HOME/.local/bin/composer.phar" /usr/local/bin/composer /usr/bin/composer; do
        [ -f "$c" ] && exec "$PHP_BIN" "$c" "$@"
    done
    echo "Error: composer not found" >&2; exit 1
fi
SYS="$(command -v composer.orig 2>/dev/null || command -v /usr/local/bin/composer 2>/dev/null || true)"
[ -n "$SYS" ] && [ -x "$SYS" ] && exec "$SYS" "$@"
echo "Error: composer not found" >&2; exit 1
WRAPPER
    chmod +x "$HOME/.local/bin/composer"
    sed -i "s|__PHPENV_ROOT_PLACEHOLDER__|${PHPENV_ROOT}|g" "$HOME/.local/bin/composer"

    # phpenv-fpm-status
    cat > "$HOME/.local/bin/phpenv-fpm-status" << 'WRAPPER'
#!/bin/bash
PHPENV_ROOT="${PHPENV_ROOT:-__PHPENV_ROOT_PLACEHOLDER__}"
echo ""
printf "  %-14s %-8s %-10s %s\n" "VERSION" "PORT" "STATUS" "SERVICE"
echo "  -----------------------------------------------"
for ver_dir in "$PHPENV_ROOT/versions"/*/; do
    [ -d "$ver_dir" ] || continue
    full_ver=$(basename "$ver_dir")
    short=$(echo "$full_ver" | cut -d. -f1,2)
    port=":90$(echo "$short" | tr -d '.')"
    unit="php-fpm-$(echo "$short" | tr -d '.')"
    if command -v systemctl &>/dev/null && systemctl --user is-active "$unit" &>/dev/null; then
        status="\033[32mactive\033[0m"
    elif [ -f "$HOME/.config/systemd/user/${unit}.service" ] || [ -f "/etc/init.d/${unit}" ]; then
        status="\033[33mstopped\033[0m"
    else
        status="\033[90mno unit\033[0m"
    fi
    printf "  %-14s %-8s $(echo -e "$status")%-4s %s\n" "$full_ver" "$port" "" "$unit"
done
echo ""
WRAPPER
    chmod +x "$HOME/.local/bin/phpenv-fpm-status"
    sed -i "s|__PHPENV_ROOT_PLACEHOLDER__|${PHPENV_ROOT}|g" "$HOME/.local/bin/phpenv-fpm-status"

    # PATH
    local shell_rc="$HOME/.bashrc"
    [ -f "$HOME/.zshrc" ] && [ ! -f "$HOME/.bashrc" ] && shell_rc="$HOME/.zshrc"
    if ! grep -q '\.local/bin' "$shell_rc" 2>/dev/null; then
        local tmp; tmp=$(mktemp)
        { echo ''; echo '# --- CLI wrappers ---'; echo 'export PATH="$HOME/.local/bin:$PATH"'; echo ''; cat "$shell_rc"; } > "$tmp"
        mv "$tmp" "$shell_rc"
    fi
    export PATH="$HOME/.local/bin:$PATH"
    ok "CLI ラッパー インストール完了"
}

# =============================================================
# 全プロジェクトの一括セットアップ
# =============================================================
run_setup_all() {
    echo ""
    echo "======================================"
    echo "  セットアップ開始"
    echo "  プロジェクト数: ${#PROJ_DIRS[@]}"
    echo "======================================"

    detect_distro
    setup_phpenv
    install_deps
    install_nginx

    # 必要な PHP バージョンをユニークに取得してビルド
    local -A built_versions=()
    for php_ver in "${PROJ_PHPS[@]}"; do
        if [ -z "${built_versions[$php_ver]+x}" ]; then
            build_php "$php_ver"
            setup_fpm "$php_ver"
            built_versions[$php_ver]=1
        fi
    done

    # 各プロジェクトを設定
    for i in "${!PROJ_DIRS[@]}"; do
        local dir="${PROJ_DIRS[$i]}"
        local php="${PROJ_PHPS[$i]}"
        local name="${PROJ_NAMES[$i]}.localhost"

        step "プロジェクト: $dir"
        setup_project "$php" "$dir" "$name"
        setup_nginx_vhost "$php" "$dir" "$name"
    done

    reload_nginx
    install_cli_wrapper

    # サマリ
    echo ""
    echo "======================================"
    echo -e "\033[1;32m  セットアップ完了\033[0m"
    echo "======================================"
    echo ""
    local port_suffix=""
    [ "$NGINX_PORT" != "80" ] && port_suffix=":${NGINX_PORT}"

    for i in "${!PROJ_DIRS[@]}"; do
        local name="${PROJ_NAMES[$i]}.localhost"
        echo "  ${PROJ_DIRS[$i]}"
        echo "    PHP ${PROJ_PHPS[$i]}  →  http://${name}${port_suffix}/"
        echo ""
    done

    echo "  確認: phpenv-fpm-status"
    echo "  CLI:  cd <project-dir> && php -v"
    echo ""
}

# =============================================================
# メイン
# =============================================================
main() {
    tui_main
    run_setup_all
}

main
