#!/usr/bin/env bash
#
# FileBrowser installer / uninstaller (from source)
# Detects distro, installs Go + Node + Task, clones filebrowser,
# builds with `task build`, installs it, and creates a systemd service.
#
# Usage:
#   bash filebrowser-install.sh            # install
#   bash filebrowser-install.sh uninstall  # remove service, files, and optionally packages
#

set -euo pipefail

START_TIME=$(date +%s)
REPO_URL="https://github.com/filebrowser/filebrowser.git"
DEFAULT_DIR="/opt/filebrowser"
BUILD_DIR="/tmp/filebrowser-src"
SERVICE_NAME="filebrowser"
DEFAULT_PORT=8082
DEFAULT_ROOT="/srv/files"
MIN_GO="1.22"

# ── helpers (logs to stderr) ───────────────────────────────────────────────
die() { echo -e "\n\033[1;31mError:\033[0m $*" >&2; exit 1; }
info() { echo -e "\033[1;34m==>\033[0m $*" >&2; }
ok() { echo -e "\033[1;32m==>\033[0m $*" >&2; }
warn() { echo -e "\033[1;33m==>\033[0m $*" >&2; }
prompt() { local var="$1" msg="$2" default="$3"; read -rp "$msg [$default]: " input; printf -v "$var" '%s' "${input:-$default}"; }
ask_yn() { local msg="$1" default="${2:-n}"; local ans; read -rp "$msg [y/N]: " ans; ans="${ans:-$default}"; [[ "$ans" =~ ^[Yy] ]]; }

elapsed() {
  local end=$(date +%s)
  local secs=$((end - START_TIME))
  printf '%dm %ds' $((secs/60)) $((secs%60))
}

ver_ge() {
  printf '%s\n%s\n' "$2" "$1" | sort -V -C
}

# ── distro detection ───────────────────────────────────────────────────────
detect_distro() {
  if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    ID="${ID:-}"
    ID_LIKE="${ID_LIKE:-}"
  else
    die "Cannot detect distro (/etc/os-release missing)."
  fi

  case "$ID" in
    debian|ubuntu|linuxmint|pop|elementary|zorin) PKG="apt" ;;
    fedora|rhel|rocky|almalinux|centos|ol)         PKG="dnf" ;;
    arch|manjaro|endeavouros|garuda)               PKG="pacman" ;;
    opensuse*|sles)                                PKG="zypper" ;;
    alpine)                                        PKG="apk" ;;
    *)
      case "$ID_LIKE" in
        *debian*|*ubuntu*) PKG="apt" ;;
        *rhel*|*fedora*)   PKG="dnf" ;;
        *arch*)            PKG="pacman" ;;
        *suse*)            PKG="zypper" ;;
        *) die "Unsupported distro: $ID (ID_LIKE=$ID_LIKE). Supported: Debian/Ubuntu, Fedora/RHEL, Arch, openSUSE, Alpine." ;;
      esac
      ;;
  esac
  info "Detected: $ID ($PKG)"
}

# ── latest release check ───────────────────────────────────────────────────
check_latest() {
  info "Checking for latest release..."
  local api="https://api.github.com/repos/filebrowser/filebrowser/releases/latest"
  FB_LATEST=$(curl -fsSL "$api" 2>/dev/null | grep -oE '"tag_name":[[:space:]]*"[^"]+"' | head -1 | cut -d'"' -f4 || true)
  if [[ -n "${FB_LATEST:-}" ]]; then
    ok "Latest FileBrowser: $FB_LATEST"
  else
    warn "Could not query releases (will use master)"
    FB_LATEST=""
  fi
  echo
}

# ── packages ───────────────────────────────────────────────────────────────
install_packages() {
  info "Installing build dependencies..."

  case "$PKG" in
    apt)
      sudo apt-get update -qq
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
        git curl ca-certificates tar gcc g++ make nodejs npm golang
      ;;
    dnf)
      sudo dnf install -y \
        git curl ca-certificates tar gcc gcc-c++ make nodejs npm golang
      ;;
    pacman)
      sudo pacman -Sy --noconfirm \
        git curl ca-certificates tar gcc make nodejs npm go
      ;;
    zypper)
      sudo zypper --non-interactive install \
        git curl ca-certificates tar gcc gcc-c++ make nodejs npm go
      ;;
    apk)
      sudo apk add --no-cache \
        git curl ca-certificates tar gcc g++ make nodejs npm go
      ;;
  esac

  ok "Build packages ready."
}

ensure_go() {
  if command -v go >/dev/null 2>&1; then
    local ver
    ver=$(go version | grep -oE 'go[0-9]+\.[0-9]+' | sed 's/go//')
    if ver_ge "$ver" "$MIN_GO"; then
      ok "Go $ver is new enough"
      return 0
    fi
    warn "Go $ver is older than $MIN_GO — installing official tarball"
  else
    warn "Go not found — installing official tarball"
  fi

  local tarball="/tmp/go.tar.gz"
  local url="https://go.dev/dl/go1.25.3.linux-amd64.tar.gz"
  info "Downloading $url"
  curl -fsSL -o "$tarball" "$url" || die "Failed to download Go tarball"
  sudo rm -rf /usr/local/go
  sudo tar -C /usr/local -xzf "$tarball"
  rm -f "$tarball"
  export PATH="/usr/local/go/bin:$PATH"
  ok "Installed $(go version)"
}

ensure_task() {
  if command -v task >/dev/null 2>&1; then
    ok "task already installed"
  else
    info "Installing task (go-task)..."
    if [[ -d /usr/local/go/bin ]]; then
      export PATH="/usr/local/go/bin:$PATH"
    fi
    sh -c "$(curl -fsSL https://taskfile.dev/install.sh)" -- -d -b /tmp/taskbin || true
    if [[ -x /tmp/taskbin/task ]]; then
      sudo mv /tmp/taskbin/task /usr/local/bin/task
      ok "task installed"
    else
      warn "Could not install task. Will fall back to 'go build'."
    fi
  fi
}

ensure_pnpm() {
  if command -v pnpm >/dev/null 2>&1; then
    ok "pnpm already installed"
    return 0
  fi
  info "Installing pnpm via npm..."
  # npm -g works under sudo; the official pnpm install script does not.
  if command -v npm >/dev/null 2>&1; then
    sudo npm install -g pnpm || die "npm install -g pnpm failed"
  else
    # fallback: pinned standalone binary (latest redirect is unreliable)
    local arch url
    case "$(uname -m)" in
      x86_64|amd64) arch="x64" ;;
      aarch64|arm64) arch="arm64" ;;
      *) die "Unsupported arch for pnpm: $(uname -m)" ;;
    esac
    url="https://github.com/pnpm/pnpm/releases/download/v10.15.0/pnpm-linux-${arch}"
    sudo curl -fsSL -o /usr/local/bin/pnpm -L "$url" || die "Failed to download pnpm"
    sudo chmod +x /usr/local/bin/pnpm
  fi
  export PATH="/usr/local/bin:$PATH"
  if command -v pnpm >/dev/null 2>&1; then
    ok "pnpm installed: $(pnpm --version)"
  else
    die "pnpm is required to build the frontend. Install it and re-run."
  fi
}

# ── build ──────────────────────────────────────────────────────────────────
build_filebrowser() {
  info "Cloning FileBrowser..."
  rm -rf "$BUILD_DIR"
  if [[ -n "${FB_LATEST:-}" ]]; then
    info "Checking out release $FB_LATEST"
    git clone --depth 1 --branch "$FB_LATEST" "$REPO_URL" "$BUILD_DIR" || \
      git clone "$REPO_URL" "$BUILD_DIR"
  else
    git clone "$REPO_URL" "$BUILD_DIR"
  fi
  cd "$BUILD_DIR"

  if [[ -d /usr/local/go/bin ]]; then
    export PATH="/usr/local/go/bin:$PATH"
  fi
  export PATH="/usr/local/bin:$PATH"

  info "Building frontend (pnpm)..."
  if [[ -d frontend ]]; then
    (cd frontend && pnpm install && pnpm run build) || die "Frontend build failed."
  fi

  info "Building backend — this can take a few minutes..."
  if command -v task >/dev/null 2>&1 && [[ -f Taskfile.yml || -f Taskfile.yaml ]]; then
    task build || go build -o filebrowser
  else
    go build -o filebrowser
  fi

  [[ -x "$BUILD_DIR/filebrowser" ]] || die "Build finished but binary not found."
  info "Build complete."
}

# ── install ────────────────────────────────────────────────────────────────
install_files() {
  info "Installing to $INSTALL_DIR ..."
  sudo mkdir -p "$INSTALL_DIR" "$ROOT_DIR"
  # Fedora SELinux blocks binaries in /opt
  sudo cp "$BUILD_DIR/filebrowser" /usr/local/bin/filebrowser
  sudo chmod +x /usr/local/bin/filebrowser
  if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce 2>/dev/null)" != "Disabled" ]]; then
    info "SELinux is enforcing — setting bin_t context"
    sudo chcon -t bin_t /usr/local/bin/filebrowser || true
  fi

  # init config and database
  if [[ ! -f "$INSTALL_DIR/filebrowser.db" ]]; then
    info "Initializing config..."
    (cd "$INSTALL_DIR" && /usr/local/bin/filebrowser config init) || true
    (cd "$INSTALL_DIR" && /usr/local/bin/filebrowser config set --address "0.0.0.0" --port "$PORT" --root "$ROOT_DIR") || true
    info "Creating admin user (password must be 12+ characters)..."
    # Default admin / admin12345678 — meets the 12-char minimum
    (cd "$INSTALL_DIR" && /usr/local/bin/filebrowser users add admin admin12345678 --perm.admin) || \
      (cd "$INSTALL_DIR" && /usr/local/bin/filebrowser users update admin --password admin12345678) || true
  fi

  sudo chown -R "$USER:$USER" "$INSTALL_DIR" "$ROOT_DIR" 2>/dev/null || true
  ok "Files installed."
}

create_service() {
  local bin="/usr/local/bin/filebrowser"
  [[ -x "$bin" ]] || die "filebrowser binary not found at $bin"

  if command -v systemctl >/dev/null 2>&1; then
    info "Creating systemd service..."
    sudo tee "/etc/systemd/system/${SERVICE_NAME}.service" >/dev/null <<UNIT
[Unit]
Description=FileBrowser
After=network.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$INSTALL_DIR
ExecStart=$bin -d $INSTALL_DIR/filebrowser.db -r $ROOT_DIR -a 0.0.0.0 -p $PORT
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
    sudo systemctl daemon-reload
    sudo systemctl enable --now "$SERVICE_NAME"
    ok "systemd service enabled and started."

    if systemctl is-active --quiet firewalld 2>/dev/null; then
      info "Opening firewall port ${PORT}/tcp..."
      sudo firewall-cmd --permanent --add-port="${PORT}/tcp" || true
      sudo firewall-cmd --reload || true
      ok "Firewall updated."
    fi

    sleep 2
    if ss -tlnp 2>/dev/null | grep -q ":${PORT} "; then
      ok "Web UI is listening on port ${PORT}"
    else
      warn "Web UI is not listening on port ${PORT}."
      warn "Last log lines:"
      sudo journalctl -u "$SERVICE_NAME" -n 20 --no-pager || true
    fi
  else
    warn "No systemd detected. Start manually with: $bin -r $ROOT_DIR -a 0.0.0.0 -p $PORT"
  fi
}

# ── uninstall ──────────────────────────────────────────────────────────────
remove_service() {
  info "Removing service..."
  if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    sudo systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    sudo rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    sudo systemctl daemon-reload
    ok "systemd service removed."
  fi
}

remove_files() {
  local dir="${1:-$DEFAULT_DIR}"
  sudo rm -f /usr/local/bin/filebrowser
  if [[ -d "$dir" ]]; then
    if ask_yn "Remove install directory $dir (includes database and config)?"; then
      sudo rm -rf "$dir"
      ok "Directory removed."
    else
      info "Kept $dir"
    fi
  else
    warn "Install directory $dir not found."
  fi
}

remove_build_dir() {
  if [[ -d "$BUILD_DIR" ]]; then
    if ask_yn "Remove build directory $BUILD_DIR?"; then
      rm -rf "$BUILD_DIR"
      ok "Build directory removed."
    fi
  fi
}

remove_packages() {
  if ask_yn "Also remove Go tarball install (/usr/local/go)?"; then
    sudo rm -rf /usr/local/go
    ok "Go removed."
  fi
  if ask_yn "Also remove build packages (gcc, nodejs, etc.)? (may affect other software)"; then
    info "Removing packages..."
    case "$PKG" in
      apt)    sudo apt-get remove -y gcc g++ nodejs npm golang || true ;;
      dnf)    sudo dnf remove -y gcc gcc-c++ nodejs npm golang || true ;;
      pacman) sudo pacman -Rns --noconfirm gcc nodejs npm go || true ;;
      zypper) sudo zypper --non-interactive remove gcc gcc-c++ nodejs npm go || true ;;
      apk)    sudo apk del gcc g++ nodejs npm go || true ;;
    esac
    ok "Package removal finished."
  else
    info "Packages kept."
  fi
}

uninstall() {
  echo "FileBrowser uninstaller"
  echo "======================="
  detect_distro
  remove_service

  echo
  prompt INSTALL_DIR "Install directory to remove" "$DEFAULT_DIR"
  remove_files "$INSTALL_DIR"
  remove_build_dir
  remove_packages

  echo
  ok "Uninstall finished in $(elapsed)"
}

# ── main ───────────────────────────────────────────────────────────────────
main() {
  local mode="${1:-install}"

  case "$mode" in
    uninstall|remove|--uninstall|-u)
      uninstall
      ;;
    install|"")
      echo "FileBrowser installer (from source)"
      echo "==================================="
      detect_distro
      check_latest
      install_packages
      ensure_go
      ensure_task
      ensure_pnpm

      echo
      prompt INSTALL_DIR "Install directory" "$DEFAULT_DIR"
      prompt PORT "Listen port" "$DEFAULT_PORT"
      prompt ROOT_DIR "Root directory to serve" "$DEFAULT_ROOT"

      [[ "$PORT" =~ ^[0-9]+$ ]] || die "Port must be a number."

      build_filebrowser
      install_files
      create_service

      local ip
      ip=$(hostname -I 2>/dev/null | awk '{print $1}') || ip="localhost"

      echo
      ok "Done in $(elapsed)"
      echo
      echo "  Open:  http://${ip:-localhost}:${PORT}"
      echo "  Files: $INSTALL_DIR"
      echo "  Root:  $ROOT_DIR"
      echo
      echo "Default login: admin / admin12345678"
      echo "Change the password on first login. (minimum 12 characters)"
      echo
      echo "Service commands:"
      if command -v systemctl >/dev/null 2>&1; then
        echo "  sudo systemctl status $SERVICE_NAME"
        echo "  sudo systemctl restart $SERVICE_NAME"
      fi
      echo
      echo "To uninstall later: bash $0 uninstall"
      ;;
    *)
      die "Unknown option: $mode. Use: $0 [install|uninstall]"
      ;;
  esac
}

main "$@"
