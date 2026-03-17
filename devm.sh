#!/usr/bin/env bash
#
# devm: Run AI coding agents inside sandboxed Lima VMs
# https://github.com/sneko/devm
#
# Source this file in your shell config:
#   source /path/to/devm.sh
#
# Or install with:
#   curl -fsSL https://raw.githubusercontent.com/sneko/devm/main/devm.sh -o ~/.devm/devm.sh
#   echo 'source ~/.devm/devm.sh' >> ~/.zshrc
#
# Usage:
#   devm setup                 - Create the base VM template (run once)
#   devm create <name> [dirs]  - Add a VM definition to ~/.devmconfig
#   devm shell [name]          - Open a shell in the VM
#   devm run [name] <cmd>      - Run a command in the VM
#   devm stop [name]           - Stop the VM
#   devm rm [name]             - Destroy the VM (keeps config)
#   devm list                  - List all devm VMs
#   devm status                - Show status of all VMs
#   devm help                  - Show help
#

# ─── Embedded setup script (runs inside the VM during "devm setup") ─────────

read -r -d '' DEVM_SETUP_SCRIPT << 'SETUP_EOF'
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# Disable needrestart's interactive prompts
sudo mkdir -p /etc/needrestart/conf.d
echo '$nrconf{restart} = '"'"'a'"'"';' | sudo tee /etc/needrestart/conf.d/no-prompt.conf > /dev/null

echo "Installing base packages..."
sudo apt-get update
sudo apt-get install -y \
  git curl jq zsh \
  wget build-essential \
  python3 python3-pip python3-venv \
  ripgrep fd-find htop \
  unzip zip \
  ca-certificates \
  iptables

# Set zsh as default shell
sudo chsh -s /usr/bin/zsh "$(whoami)"

# Install Docker from official repo
echo "Installing Docker..."
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
sudo usermod -aG docker "$(whoami)"

# Install Node.js 24 LTS (needed for MCP servers and global npx)
echo "Installing Node.js 24..."
curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash -
sudo apt-get install -y nodejs

# Install Chromium and dependencies for headless browsing
echo "Installing Chromium..."
sudo apt-get install -y chromium fonts-liberation xvfb
sudo ln -sf /usr/bin/chromium /usr/bin/google-chrome
sudo ln -sf /usr/bin/chromium /usr/bin/google-chrome-stable
sudo mkdir -p /opt/google/chrome
sudo ln -sf /usr/bin/chromium /opt/google/chrome/chrome

# Install GitHub CLI
echo "Installing GitHub CLI..."
sudo mkdir -p -m 755 /etc/apt/keyrings
wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null
sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
sudo apt-get update
sudo apt-get install -y gh

# Install mise (manages .tool-versions, .nvmrc, .node-version, .python-version, etc.)
echo "Installing mise..."
curl https://mise.run | sh
echo 'eval "$(~/.local/bin/mise activate zsh)"' >> ~/.zshrc
echo 'eval "$(~/.local/bin/mise activate zsh)"' >> ~/.zshenv

# Install Claude Code
echo "Installing Claude Code..."
curl -fsSL https://claude.ai/install.sh | bash
echo 'export PATH=$HOME/.local/bin:$HOME/.claude/local/bin:$PATH' >> ~/.zshrc
echo 'export PS1="devm:%1~%% "' >> ~/.zshrc

# Install OpenCode
echo "Installing OpenCode..."
curl -fsSL https://opencode.ai/install | bash
echo 'export PATH=$HOME/.opencode/bin:$PATH' >> ~/.zshrc

# Add PATH to .zshenv so non-interactive shells also find the tools
echo 'export PATH=$HOME/.local/bin:$HOME/.claude/local/bin:$HOME/.opencode/bin:$PATH' >> ~/.zshenv

# Install Codex CLI
echo "Installing Codex CLI..."
sudo npm i -g @openai/codex

# Configure Chrome DevTools MCP server for Claude
echo "Configuring Chrome MCP server for Claude..."
CONFIG="$HOME/.claude.json"
if [ -f "$CONFIG" ]; then
  jq '.mcpServers["chrome-devtools"] = {
    "command": "npx",
    "args": ["-y", "chrome-devtools-mcp@latest", "--headless=true", "--isolated=true"]
  }' "$CONFIG" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
else
  cat > "$CONFIG" << 'JSON'
{
  "mcpServers": {
    "chrome-devtools": {
      "command": "npx",
      "args": ["-y", "chrome-devtools-mcp@latest", "--headless=true", "--isolated=true"]
    }
  }
}
JSON
fi

# Configure Chrome DevTools MCP server for OpenCode
echo "Configuring Chrome MCP server for OpenCode..."
OPENCODE_CONFIG_DIR="$HOME/.config/opencode"
mkdir -p "$OPENCODE_CONFIG_DIR"
OPENCODE_CONFIG="$OPENCODE_CONFIG_DIR/opencode.json"
if [ -f "$OPENCODE_CONFIG" ]; then
  jq '.mcp["chrome-devtools"] = {
    "type": "local",
    "command": ["npx", "-y", "chrome-devtools-mcp@latest", "--headless=true", "--isolated=true"],
    "enabled": true
  }' "$OPENCODE_CONFIG" > "$OPENCODE_CONFIG.tmp" && mv "$OPENCODE_CONFIG.tmp" "$OPENCODE_CONFIG"
else
  cat > "$OPENCODE_CONFIG" << 'JSON'
{
  "$schema": "https://opencode.ai/config.json",
  "mcp": {
    "chrome-devtools": {
      "type": "local",
      "command": ["npx", "-y", "chrome-devtools-mcp@latest", "--headless=true", "--isolated=true"],
      "enabled": true
    }
  }
}
JSON
fi

# Create /devm mount root
sudo mkdir -p /devm

echo "VM setup complete."
SETUP_EOF

# ─── Constants ──────────────────────────────────────────────────────────────

DEVM_TEMPLATE="devm-base"
DEVM_STATE_DIR="${HOME}/.devm"
DEVM_CONFIG="${HOME}/.devmconfig"

# ─── Config parsing ────────────────────────────────────────────────────────

# Resolve a path: expand ~ and ./ to absolute
_devm_resolve_path() {
  local p="$1"
  # Strip :rw or :ro suffix for resolution
  local suffix=""
  if [[ "$p" =~ :(rw|ro)$ ]]; then
    suffix=":${BASH_REMATCH[1]}"
    p="${p%:*}"
  fi
  # Expand ~
  p="${p/#\~/$HOME}"
  # Resolve relative paths
  if [[ "$p" != /* ]]; then
    p="$(cd "$(pwd)" && realpath -m "$p" 2>/dev/null || echo "$(pwd)/$p")"
  fi
  echo "${p}${suffix}"
}

# Get VM mount path from host path
_devm_vm_path() {
  echo "/devm${1}"
}

# Get a key=value setting from config for a project
_devm_config_get() {
  local project="$1" key="$2"
  local in_section=0
  [[ -f "$DEVM_CONFIG" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -z "$line" ]] && continue
    if [[ "$line" =~ ^\[(.+)\]$ ]]; then
      [[ "${BASH_REMATCH[1]}" == "$project" ]] && in_section=1 || in_section=0
      continue
    fi
    if [[ $in_section -eq 1 ]] && [[ "$line" =~ ^${key}=(.+)$ ]]; then
      echo "${BASH_REMATCH[1]}"
      return 0
    fi
  done < "$DEVM_CONFIG"
  return 1
}

# List folder lines (raw, with :rw/:ro suffix) for a project
_devm_config_folders_raw() {
  local project="$1"
  local in_section=0
  [[ -f "$DEVM_CONFIG" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -z "$line" ]] && continue
    if [[ "$line" =~ ^\[(.+)\]$ ]]; then
      [[ "${BASH_REMATCH[1]}" == "$project" ]] && in_section=1 || in_section=0
      continue
    fi
    if [[ $in_section -eq 1 ]]; then
      # Skip key=value settings
      [[ "$line" =~ ^[a-z]+=.+$ ]] && continue
      echo "$(_devm_resolve_path "$line")"
    fi
  done < "$DEVM_CONFIG"
}

# List resolved folder paths (without suffix) for a project
_devm_config_folders() {
  local project="$1"
  _devm_config_folders_raw "$project" | while IFS= read -r line; do
    echo "${line%:rw}"  | sed 's/:ro$//'
  done
}

# Get mount mode for a folder line: "rw", "ro", or "auto"
_devm_config_folder_mode() {
  local line="$1"
  if [[ "$line" =~ :rw$ ]]; then
    echo "rw"
  elif [[ "$line" =~ :ro$ ]]; then
    echo "ro"
  else
    echo "auto"
  fi
}

# List all project names from config
_devm_config_projects() {
  [[ -f "$DEVM_CONFIG" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^\[(.+)\]$ ]]; then
      echo "${BASH_REMATCH[1]}"
    fi
  done < "$DEVM_CONFIG"
}

# Check if a project name exists in config
_devm_config_has_project() {
  _devm_config_projects | grep -qx "$1" 2>/dev/null
}

# Find project name that contains a given directory
_devm_find_project_for_dir() {
  local dir="$1"
  local project folder
  while IFS= read -r project; do
    [[ -z "$project" ]] && continue
    while IFS= read -r folder; do
      [[ -z "$folder" ]] && continue
      if [[ "$dir" == "$folder" || "$dir" == "$folder/"* ]]; then
        echo "$project"
        return 0
      fi
    done <<< "$(_devm_config_folders "$project")"
  done <<< "$(_devm_config_projects)"
  return 1
}

# ─── Config writing ────────────────────────────────────────────────────────

# Write or update a project section in the config file
# Usage: _devm_config_write_project <name> [--cpus N] [--memory GB] [--disk GB] [folders...]
_devm_config_write_project() {
  local name="$1"; shift
  local cpus="" memory="" disk=""
  local folders=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cpus)   cpus="$2"; shift 2 ;;
      --memory) memory="$2"; shift 2 ;;
      --disk)   disk="$2"; shift 2 ;;
      *)        folders+=("$1"); shift ;;
    esac
  done

  # Read existing values as defaults
  local old_cpus old_memory old_disk
  old_cpus=$(_devm_config_get "$name" "cpus" 2>/dev/null || echo "")
  old_memory=$(_devm_config_get "$name" "memory" 2>/dev/null || echo "")
  old_disk=$(_devm_config_get "$name" "disk" 2>/dev/null || echo "")

  cpus="${cpus:-${old_cpus:-1}}"
  memory="${memory:-${old_memory:-2}}"
  disk="${disk:-${old_disk:-10}}"

  # Get existing folders if no new folders provided
  if [[ ${#folders[@]} -eq 0 ]]; then
    while IFS= read -r f; do
      [[ -n "$f" ]] && folders+=("$f")
    done <<< "$(_devm_config_folders_raw "$name" 2>/dev/null)"
  fi

  if [[ ${#folders[@]} -eq 0 ]]; then
    echo "Error: No folders specified for '$name'." >&2
    return 1
  fi

  # Remove existing section if present
  [[ -f "$DEVM_CONFIG" ]] || touch "$DEVM_CONFIG"
  local tmpfile
  tmpfile=$(mktemp)
  local skip=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^\[(.+)\]$ ]]; then
      if [[ "${BASH_REMATCH[1]}" == "$name" ]]; then
        skip=1
        continue
      else
        skip=0
      fi
    fi
    [[ $skip -eq 0 ]] && echo "$line" >> "$tmpfile"
  done < "$DEVM_CONFIG"

  # Append new section
  # Add newline before section if file is non-empty
  if [[ -s "$tmpfile" ]]; then
    echo "" >> "$tmpfile"
  fi
  echo "[$name]" >> "$tmpfile"
  echo "cpus=$cpus" >> "$tmpfile"
  echo "memory=$memory" >> "$tmpfile"
  echo "disk=$disk" >> "$tmpfile"
  for f in "${folders[@]}"; do
    echo "$f" >> "$tmpfile"
  done

  mv "$tmpfile" "$DEVM_CONFIG"
}

# ─── VM helpers ─────────────────────────────────────────────────────────────

_devm_vm_name() {
  echo "devm-${1}"
}

_devm_exists() {
  limactl list -q 2>/dev/null | grep -q "^${1}$"
}

_devm_running() {
  limactl list --format '{{.Name}} {{.Status}}' 2>/dev/null | grep -q "^${1} Running$"
}

_devm_print_resources() {
  local vm_name="$1"
  local info
  info=$(limactl list --format '{{.Name}}|{{.CPUs}}|{{.Memory}}|{{.Disk}}' 2>/dev/null | grep "^${vm_name}|" | head -1)
  if [[ -n "$info" ]]; then
    local cpus mem_bytes disk_bytes
    IFS='|' read -r _ cpus mem_bytes disk_bytes <<< "$info"
    local mem_gib=$((mem_bytes / 1073741824))
    local disk_gib=$((disk_bytes / 1073741824))
    echo "  Resources: CPUs: ${cpus}, Memory: ${mem_gib} GiB, Disk: ${disk_gib} GiB"
  fi
}

# Build Lima mounts JSON from project config
# Returns JSON array for .mounts setting
_devm_build_mounts() {
  local project="$1"
  local mounts="["
  local first=1
  local raw_line folder mode writable host_path vm_mount

  while IFS= read -r raw_line; do
    [[ -z "$raw_line" ]] && continue
    mode=$(_devm_config_folder_mode "$raw_line")
    # Strip suffix to get clean path
    folder="${raw_line%:rw}"
    folder="${folder%:ro}"

    # Determine writability
    case "$mode" in
      rw) writable=true ;;
      ro) writable=false ;;
      auto)
        if [[ -d "$folder/.git" ]]; then
          writable=true
        else
          writable=false
        fi
        ;;
    esac

    host_path="$folder"
    vm_mount="$(_devm_vm_path "$folder")"

    [[ $first -eq 1 ]] && first=0 || mounts+=","
    mounts+="{\"location\":\"${host_path}\",\"mountPoint\":\"${vm_mount}\",\"writable\":${writable}}"
  done <<< "$(_devm_config_folders_raw "$project")"

  mounts+="]"
  echo "$mounts"
}

# Resolve project name from argument or cwd
# Sets: DEVM_PROJECT, DEVM_WORKDIR (vm path)
_devm_resolve_project() {
  local candidate="$1"
  local cwd
  cwd="$(pwd)"

  # Check if candidate is a known project name
  if [[ -n "$candidate" ]] && _devm_config_has_project "$candidate"; then
    DEVM_PROJECT="$candidate"
    # Determine workdir: if cwd is within a project folder, use it
    DEVM_WORKDIR=""
    local first_folder=""
    while IFS= read -r folder; do
      [[ -z "$folder" ]] && continue
      [[ -z "$first_folder" ]] && first_folder="$folder"
      if [[ "$cwd" == "$folder" || "$cwd" == "$folder/"* ]]; then
        DEVM_WORKDIR="$(_devm_vm_path "$cwd")"
        break
      fi
    done <<< "$(_devm_config_folders "$candidate")"
    [[ -z "$DEVM_WORKDIR" ]] && DEVM_WORKDIR="$(_devm_vm_path "$first_folder")"
    return 0
  fi

  # Auto-detect from cwd
  local detected
  if detected=$(_devm_find_project_for_dir "$cwd"); then
    DEVM_PROJECT="$detected"
    DEVM_WORKDIR="$(_devm_vm_path "$cwd")"
    return 0
  fi

  return 1
}

# Ensure the VM exists and is running
_devm_ensure_running() {
  local vm_name="$1"
  local project="$2"
  shift 2
  local disk="" memory="" cpus="" reset="" offline=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --disk)    disk="$2"; shift 2 ;;
      --memory)  memory="$2"; shift 2 ;;
      --cpus)    cpus="$2"; shift 2 ;;
      --reset)   reset=1; shift ;;
      --offline) offline=1; shift ;;
      *)         shift ;;
    esac
  done

  # Check base template
  if ! limactl list -q 2>/dev/null | grep -q "^${DEVM_TEMPLATE}$"; then
    echo "Error: Base VM not found. Run 'devm setup' first." >&2
    return 1
  fi

  # Get config values as defaults
  local cfg_cpus cfg_memory cfg_disk
  cfg_cpus=$(_devm_config_get "$project" "cpus" 2>/dev/null || echo "1")
  cfg_memory=$(_devm_config_get "$project" "memory" 2>/dev/null || echo "2")
  cfg_disk=$(_devm_config_get "$project" "disk" 2>/dev/null || echo "10")

  # CLI overrides config; update config if CLI provided
  if [[ -n "$cpus" || -n "$memory" || -n "$disk" ]]; then
    _devm_config_write_project "$project" \
      ${cpus:+--cpus "$cpus"} \
      ${memory:+--memory "$memory"} \
      ${disk:+--disk "$disk"}
    echo "Updated ~/.devmconfig with new resource settings."
  fi

  cpus="${cpus:-$cfg_cpus}"
  memory="${memory:-$cfg_memory}"
  disk="${disk:-$cfg_disk}"

  # Get folders
  local folders=()
  while IFS= read -r f; do
    [[ -n "$f" ]] && folders+=("$f")
  done <<< "$(_devm_config_folders "$project")"

  if [[ ${#folders[@]} -eq 0 ]]; then
    echo "Error: No folders configured for '$project' in $DEVM_CONFIG" >&2
    return 1
  fi

  # Reset if requested
  if [[ -n "$reset" ]] && _devm_exists "$vm_name"; then
    echo "Resetting VM '$vm_name'..."
    limactl stop "$vm_name" &>/dev/null
    limactl delete "$vm_name" --force &>/dev/null
    rm -f "$DEVM_STATE_DIR/.devm-version-${vm_name}"
  fi

  if ! _devm_exists "$vm_name"; then
    echo "Creating VM '$vm_name'..."
    limactl clone "$DEVM_TEMPLATE" "$vm_name" --tty=false &>/dev/null

    local mounts_json
    mounts_json=$(_devm_build_mounts "$project")

    local edit_args=()
    edit_args+=(--set ".mounts = ${mounts_json}")
    edit_args+=(--memory "$memory")
    edit_args+=(--cpus "$cpus")
    (cd /tmp && limactl edit "$vm_name" "${edit_args[@]}") &>/dev/null

    if ! (cd /tmp && limactl edit "$vm_name" --disk "$disk") &>/dev/null; then
      echo "Warning: Cannot set disk to ${disk} GiB (shrinking not supported). Re-run 'devm setup --disk ${disk}' for a smaller base." >&2
    fi

    _devm_print_resources "$vm_name"

    local base_ver="$DEVM_STATE_DIR/.devm-base-version"
    if [[ -f "$base_ver" ]]; then
      cp "$base_ver" "$DEVM_STATE_DIR/.devm-version-${vm_name}"
    fi
  elif [[ -n "$disk" || -n "$memory" || -n "$cpus" ]]; then
    # Resize existing VM
    if _devm_running "$vm_name"; then
      echo "VM '$vm_name' is running. Must stop to apply resource changes."
      printf "Stop and apply? [y/N] "
      local reply
      read -r reply
      if [[ ! "$reply" =~ ^[Yy]$ ]]; then
        echo "Aborted. Starting with current settings."
      else
        limactl stop "$vm_name" &>/dev/null

        local mounts_json
        mounts_json=$(_devm_build_mounts "$project")
        local edit_args=(--set ".mounts = ${mounts_json}" --memory "$memory" --cpus "$cpus")
        (cd /tmp && limactl edit "$vm_name" "${edit_args[@]}") &>/dev/null
        if [[ -n "$disk" ]]; then
          (cd /tmp && limactl edit "$vm_name" --disk "$disk") &>/dev/null || \
            echo "Warning: Cannot set disk to ${disk} GiB." >&2
        fi
        _devm_print_resources "$vm_name"
      fi
    fi
  fi

  # Version check
  local base_ver="$DEVM_STATE_DIR/.devm-base-version"
  local vm_ver="$DEVM_STATE_DIR/.devm-version-${vm_name}"
  if [[ -f "$base_ver" ]] && { [[ ! -f "$vm_ver" ]] || [[ "$(cat "$base_ver")" != "$(cat "$vm_ver")" ]]; }; then
    echo "Warning: Base VM updated since this VM was cloned. Use --reset to re-clone." >&2
  fi

  if ! _devm_running "$vm_name"; then
    echo "Starting VM '$vm_name'..."
    limactl start "$vm_name" &>/dev/null
  fi

  # Determine first folder for runtime scripts
  local first_folder="${folders[0]}"
  local first_vm_path
  first_vm_path="$(_devm_vm_path "$first_folder")"

  # Run per-user runtime script
  if [[ -f "$DEVM_STATE_DIR/runtime.sh" ]]; then
    echo "Running user runtime setup..."
    limactl shell --workdir "$first_vm_path" "$vm_name" zsh -l < "$DEVM_STATE_DIR/runtime.sh"
  fi

  # Run project-specific runtime script
  if [[ -f "${first_folder}/.devm.runtime.sh" ]]; then
    echo "Running directory runtime setup..."
    limactl shell --workdir "$first_vm_path" "$vm_name" zsh -l < "${first_folder}/.devm.runtime.sh"
  fi

  # Install tool versions via mise if config files exist
  for folder in "${folders[@]}"; do
    if [[ -f "$folder/.tool-versions" || -f "$folder/.nvmrc" || -f "$folder/.node-version" || -f "$folder/.python-version" || -f "$folder/.mise.toml" ]]; then
      local vm_folder
      vm_folder="$(_devm_vm_path "$folder")"
      echo "Installing tool versions for $(basename "$folder")..."
      limactl shell --workdir "$vm_folder" "$vm_name" zsh -lc "mise install --yes" 2>/dev/null || true
    fi
  done

  # Apply .git read-only for git folders (unless explicitly :ro which is already fully read-only)
  while IFS= read -r raw_line; do
    [[ -z "$raw_line" ]] && continue
    local mode folder
    mode=$(_devm_config_folder_mode "$raw_line")
    folder="${raw_line%:rw}"
    folder="${folder%:ro}"

    # Only bind-mount .git for writable git folders
    if [[ "$mode" != "ro" ]] && [[ -d "$folder/.git" ]]; then
      local vm_folder
      vm_folder="$(_devm_vm_path "$folder")"
      echo "Protecting .git in $(basename "$folder")..."
      limactl shell "$vm_name" sudo mount --bind "$vm_folder/.git" "$vm_folder/.git" 2>/dev/null
      limactl shell "$vm_name" sudo mount -o remount,ro,bind "$vm_folder/.git" 2>/dev/null
    fi
  done <<< "$(_devm_config_folders_raw "$project")"

  # Offline mode
  if [[ -n "$offline" ]]; then
    echo "Enabling offline mode..."
    limactl shell "$vm_name" sudo iptables -F OUTPUT 2>/dev/null
    limactl shell "$vm_name" sudo iptables -A OUTPUT -o lo -j ACCEPT
    limactl shell "$vm_name" sudo iptables -A OUTPUT -d 10.0.0.0/8 -j ACCEPT
    limactl shell "$vm_name" sudo iptables -A OUTPUT -d 172.16.0.0/12 -j ACCEPT
    limactl shell "$vm_name" sudo iptables -A OUTPUT -d 192.168.0.0/16 -j ACCEPT
    limactl shell "$vm_name" sudo iptables -P OUTPUT DROP
  fi
}

# ─── Commands ───────────────────────────────────────────────────────────────

devm() {
  local vm_opts=()
  local rm_after=""

  # Parse global options before the subcommand
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --disk)           vm_opts+=(--disk "$2"); shift 2 ;;
      --disk=*)         vm_opts+=(--disk "${1#*=}"); shift ;;
      --memory|--ram)   vm_opts+=(--memory "$2"); shift 2 ;;
      --memory=*|--ram=*) vm_opts+=(--memory "${1#*=}"); shift ;;
      --cpus)           vm_opts+=(--cpus "$2"); shift 2 ;;
      --cpus=*)         vm_opts+=(--cpus "${1#*=}"); shift ;;
      --reset)          vm_opts+=(--reset); shift ;;
      --offline)        vm_opts+=(--offline); shift ;;
      --rm)             rm_after=1; shift ;;
      *)                break ;;
    esac
  done

  local cmd="${1:-help}"
  shift 2>/dev/null || true

  case "$cmd" in
    setup)
      _devm_setup "${vm_opts[@]}" "$@"
      ;;
    create)
      _devm_create "${vm_opts[@]}" "$@"
      ;;
    shell)
      _devm_shell "${vm_opts[@]}" "$@"
      [[ -n "$rm_after" ]] && _devm_destroy_current
      ;;
    run)
      _devm_run "${vm_opts[@]}" "$@"
      local rc=$?
      [[ -n "$rm_after" ]] && _devm_destroy_current
      return $rc
      ;;
    stop)
      _devm_stop "$@"
      ;;
    rm|destroy)
      _devm_destroy "$@"
      ;;
    destroy-all)
      _devm_destroy_all "$@"
      ;;
    list|ls)
      _devm_list "$@"
      ;;
    status|ps)
      _devm_status "$@"
      ;;
    help|--help|-h)
      _devm_help
      ;;
    *)
      echo "Unknown command: $cmd" >&2
      echo "Run 'devm help' for usage." >&2
      return 1
      ;;
  esac
}

_devm_help() {
  cat << 'EOF'
Usage: devm [options] <command> [args]

Commands:
  setup                           Create the base VM template (run once)
  create <name> [dirs] [opts]     Add/update a VM definition in ~/.devmconfig
  shell [name]                    Open a shell in the VM
  run [name] <cmd> [args]         Run a command in the VM
  stop [name]                     Stop the VM
  rm [name]                       Destroy the VM (keeps config entry)
  destroy-all                     Destroy all devm VMs
  list                            List all devm VMs
  status                          Show status of all VMs
  help                            Show this help

Options (for shell, run):
  --disk GB          VM disk size (default: from config or 10)
  --memory GB        VM memory (default: from config or 2)
  --cpus N           Number of CPUs (default: from config or 1)
  --reset            Destroy and re-clone the VM from the base template
  --offline          Block outbound internet (keeps host/VM communication)
  --rm               Destroy the VM after the command exits

Name resolution:
  If [name] is omitted, devm auto-detects it by matching your current
  directory against folders listed in ~/.devmconfig.

Config file (~/.devmconfig):
  Each section defines a named VM with folders to mount:

    [myapp]
    cpus=2
    memory=4
    disk=10
    ~/code/myapp

    [fullstack]
    cpus=4
    memory=8
    disk=20
    ~/code/frontend
    ~/code/backend
    ~/shared/libs:rw
    ~/reference/docs

  Mount modes (suffix on folder paths):
    :rw    Force writable mount
    :ro    Force read-only mount
    (none) Smart default: git repos are writable (with .git read-only),
           non-git folders are read-only

  Folder paths in the VM are under /devm/<absolute-host-path>, e.g.:
    ~/code/myapp → /devm/Users/you/code/myapp

  Resource settings (cpus, memory, disk) are stored per VM.
  Edit ~/.devmconfig directly to customize or backup your configuration.

Examples:
  devm setup                                    # Create base VM
  devm create myapp ~/code/myapp --cpus 2       # Define a VM
  devm shell myapp                              # Shell into the VM
  devm run myapp npm install                    # Run a command
  devm --offline shell myapp                    # No internet access
  devm --rm run myapp npm test                  # Destroy VM after test
  devm --reset shell myapp                      # Fresh VM from template
  devm shell                                    # Auto-detect VM from cwd

Customization:
  ~/.devm/setup.sh                Per-user setup (runs during "devm setup")
  ~/.devm/runtime.sh              Per-user runtime (runs on each VM start)
  <dir>/.devm.runtime.sh          Per-directory runtime (runs on each VM start)

More info: https://github.com/sneko/devm
EOF
}

_devm_setup() {
  local disk=10 memory=2 cpus=1

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help|-h)
        echo "Usage: devm setup [--disk GB] [--memory GB] [--cpus N]"
        echo ""
        echo "Create a base VM template with dev tools and agents pre-installed."
        echo ""
        echo "Options:"
        echo "  --disk GB      VM disk size (default: 10)"
        echo "  --memory GB    VM memory (default: 2)"
        echo "  --cpus N       Number of CPUs (default: 1)"
        return 0
        ;;
      --disk)   disk="$2"; shift 2 ;;
      --disk=*) disk="${1#*=}"; shift ;;
      --memory|--ram) memory="$2"; shift 2 ;;
      --memory=*|--ram=*) memory="${1#*=}"; shift ;;
      --cpus)   cpus="$2"; shift 2 ;;
      --cpus=*) cpus="${1#*=}"; shift ;;
      --reset|--offline|--rm) shift ;;
      *)
        echo "Unknown option: $1" >&2
        return 1
        ;;
    esac
  done

  if ! command -v limactl &>/dev/null; then
    if command -v brew &>/dev/null; then
      echo "Installing Lima..."
      brew install lima
    else
      echo "Error: Lima is required. Install from https://lima-vm.io/docs/installation/" >&2
      return 1
    fi
  fi

  limactl stop "$DEVM_TEMPLATE" &>/dev/null
  limactl delete "$DEVM_TEMPLATE" --force &>/dev/null

  echo "Creating base VM..."
  local create_args=(
    --set '.mounts=[]'
    --disk="$disk"
    --memory="$memory"
    --tty=false
  )
  [[ -n "$cpus" ]] && create_args+=(--cpus="$cpus")
  limactl create --name="$DEVM_TEMPLATE" template:debian-13 \
    "${create_args[@]}" &>/dev/null || { echo "Error: Failed to create base VM." >&2; return 1; }

  _devm_print_resources "$DEVM_TEMPLATE"

  limactl start "$DEVM_TEMPLATE" &>/dev/null || { echo "Error: Failed to start base VM." >&2; return 1; }

  # Run the embedded setup script inside the VM
  echo "Installing packages inside VM..."
  echo "$DEVM_SETUP_SCRIPT" | limactl shell "$DEVM_TEMPLATE" bash -l || { echo "Error: Setup script failed." >&2; return 1; }

  # Run user's custom setup script if it exists
  local user_setup="$DEVM_STATE_DIR/setup.sh"
  if [[ -f "$user_setup" ]]; then
    echo "Running custom setup from $user_setup..."
    limactl shell "$DEVM_TEMPLATE" zsh -l < "$user_setup" || { echo "Error: Custom setup script failed." >&2; return 1; }
  fi

  limactl stop "$DEVM_TEMPLATE" &>/dev/null

  # Record base VM version
  mkdir -p "$DEVM_STATE_DIR"
  date +%s > "$DEVM_STATE_DIR/.devm-base-version"

  echo ""
  echo "Base VM ready."
  echo "Define VMs in ~/.devmconfig, then use 'devm shell <name>' to start."
  echo "Run 'devm help' for usage and config format."
}

_devm_create() {
  local name="" cpus="" memory="" disk=""
  local folders=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cpus)   cpus="$2"; shift 2 ;;
      --cpus=*) cpus="${1#*=}"; shift ;;
      --memory|--ram) memory="$2"; shift 2 ;;
      --memory=*|--ram=*) memory="${1#*=}"; shift ;;
      --disk)   disk="$2"; shift 2 ;;
      --disk=*) disk="${1#*=}"; shift ;;
      --help|-h)
        echo "Usage: devm create <name> [folder...] [--cpus N] [--memory GB] [--disk GB]"
        echo ""
        echo "Add or update a VM definition in ~/.devmconfig."
        echo "Folders can use :rw or :ro suffix to override mount mode."
        echo ""
        echo "Examples:"
        echo "  devm create myapp ~/code/myapp"
        echo "  devm create myapp ~/code/myapp --cpus 4 --memory 8"
        echo "  devm create fullstack ~/code/frontend ~/code/backend ~/libs:rw"
        return 0
        ;;
      --reset|--offline|--rm) shift ;;
      *)
        if [[ -z "$name" ]]; then
          name="$1"
        else
          folders+=("$(_devm_resolve_path "$1")")
        fi
        shift
        ;;
    esac
  done

  if [[ -z "$name" ]]; then
    echo "Usage: devm create <name> [folder...] [--cpus N] [--memory GB] [--disk GB]" >&2
    return 1
  fi

  local write_args=()
  [[ -n "$cpus" ]]   && write_args+=(--cpus "$cpus")
  [[ -n "$memory" ]] && write_args+=(--memory "$memory")
  [[ -n "$disk" ]]   && write_args+=(--disk "$disk")

  _devm_config_write_project "$name" "${write_args[@]}" "${folders[@]}" || return 1

  echo "VM '$name' saved to $DEVM_CONFIG"
  echo ""
  echo "Configured folders:"
  _devm_config_folders "$name" | while IFS= read -r f; do
    local mode="auto"
    # Re-check raw to show mode
    echo "  $f"
  done
  echo ""
  echo "Resources: cpus=$(_devm_config_get "$name" cpus), memory=$(_devm_config_get "$name" memory) GiB, disk=$(_devm_config_get "$name" disk) GiB"
  echo ""
  echo "Edit $DEVM_CONFIG directly to customize or backup your configuration."
  echo "Run 'devm shell $name' to start the VM."
}

_devm_shell() {
  local vm_opts=()
  local project_arg=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --disk)   vm_opts+=(--disk "$2"); shift 2 ;;
      --memory) vm_opts+=(--memory "$2"); shift 2 ;;
      --cpus)   vm_opts+=(--cpus "$2"); shift 2 ;;
      --reset)  vm_opts+=(--reset); shift ;;
      --offline) vm_opts+=(--offline); shift ;;
      --rm)     shift ;; # handled by caller
      *)
        if [[ -z "$project_arg" ]] && _devm_config_has_project "$1"; then
          project_arg="$1"
        fi
        shift
        ;;
    esac
  done

  DEVM_PROJECT="" DEVM_WORKDIR=""
  if ! _devm_resolve_project "$project_arg"; then
    if [[ -n "$project_arg" ]]; then
      echo "Error: Unknown VM name '$project_arg'. Check $DEVM_CONFIG" >&2
    else
      echo "Error: No VM found for $(pwd). Add one with 'devm create' or edit $DEVM_CONFIG" >&2
    fi
    return 1
  fi

  local vm_name
  vm_name=$(_devm_vm_name "$DEVM_PROJECT")

  _devm_ensure_running "$vm_name" "$DEVM_PROJECT" "${vm_opts[@]}" || return 1
  _devm_print_resources "$vm_name"

  echo "VM: $vm_name | Name: $DEVM_PROJECT | Dir: $DEVM_WORKDIR"
  echo "Type 'exit' to leave. Use 'devm stop $DEVM_PROJECT' to stop the VM."

  # Track current project for --rm cleanup
  DEVM_LAST_PROJECT="$DEVM_PROJECT"
  limactl shell --workdir "$DEVM_WORKDIR" "$vm_name" zsh -l
}

_devm_run() {
  local vm_opts=()
  local project_arg=""
  local cmd_args=()
  local found_cmd=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --disk)   vm_opts+=(--disk "$2"); shift 2 ;;
      --memory) vm_opts+=(--memory "$2"); shift 2 ;;
      --cpus)   vm_opts+=(--cpus "$2"); shift 2 ;;
      --reset)  vm_opts+=(--reset); shift ;;
      --offline) vm_opts+=(--offline); shift ;;
      --rm)     shift ;; # handled by caller
      *)
        if [[ $found_cmd -eq 0 ]] && [[ -z "$project_arg" ]] && _devm_config_has_project "$1"; then
          project_arg="$1"
          shift
          continue
        fi
        found_cmd=1
        cmd_args+=("$1")
        shift
        ;;
    esac
  done

  if [[ ${#cmd_args[@]} -eq 0 ]]; then
    echo "Usage: devm run [name] <command> [args]" >&2
    return 1
  fi

  DEVM_PROJECT="" DEVM_WORKDIR=""
  if ! _devm_resolve_project "$project_arg"; then
    if [[ -n "$project_arg" ]]; then
      echo "Error: Unknown VM name '$project_arg'. Check $DEVM_CONFIG" >&2
    else
      echo "Error: No VM found for $(pwd). Add one with 'devm create' or edit $DEVM_CONFIG" >&2
    fi
    return 1
  fi

  local vm_name
  vm_name=$(_devm_vm_name "$DEVM_PROJECT")

  _devm_ensure_running "$vm_name" "$DEVM_PROJECT" "${vm_opts[@]}" || return 1

  DEVM_LAST_PROJECT="$DEVM_PROJECT"
  limactl shell --workdir "$DEVM_WORKDIR" "$vm_name" "${cmd_args[@]}"
}

_devm_resolve_project_arg() {
  local arg="$1"
  if [[ -n "$arg" ]] && _devm_config_has_project "$arg"; then
    echo "$arg"
    return 0
  fi
  _devm_find_project_for_dir "$(pwd)"
}

_devm_stop() {
  local project
  project=$(_devm_resolve_project_arg "$1")
  if [[ -z "$project" ]]; then
    echo "Error: No VM name specified and none found for $(pwd)." >&2
    return 1
  fi

  local vm_name
  vm_name=$(_devm_vm_name "$project")

  if ! _devm_exists "$vm_name"; then
    echo "No VM found for '$project'." >&2
    return 1
  fi

  echo "Stopping VM '$vm_name'..."
  limactl stop "$vm_name" &>/dev/null
  echo "VM stopped."
}

_devm_destroy() {
  local project
  project=$(_devm_resolve_project_arg "$1")
  if [[ -z "$project" ]]; then
    echo "Error: No VM name specified and none found for $(pwd)." >&2
    return 1
  fi

  local vm_name
  vm_name=$(_devm_vm_name "$project")

  if ! _devm_exists "$vm_name"; then
    echo "No VM found for '$project'." >&2
    return 1
  fi

  echo "Stopping and deleting VM '$vm_name'..."
  limactl stop "$vm_name" &>/dev/null
  limactl delete "$vm_name" --force &>/dev/null
  rm -f "$DEVM_STATE_DIR/.devm-version-${vm_name}"
  echo "VM destroyed. Config entry for '$project' kept in $DEVM_CONFIG"
}

# Helper for --rm cleanup
_devm_destroy_current() {
  if [[ -n "${DEVM_LAST_PROJECT:-}" ]]; then
    local vm_name
    vm_name=$(_devm_vm_name "$DEVM_LAST_PROJECT")
    echo "Removing VM '$vm_name'..."
    limactl stop "$vm_name" &>/dev/null
    limactl delete "$vm_name" --force &>/dev/null
    rm -f "$DEVM_STATE_DIR/.devm-version-${vm_name}"
  fi
}

_devm_destroy_all() {
  local vms
  vms=$(limactl list -q 2>/dev/null | grep "^devm-" | grep -v "^devm-base$" || true)
  if [[ -z "$vms" ]]; then
    echo "No devm VMs found."
    return 0
  fi
  echo "This will destroy the following VMs:"
  echo "$vms"
  printf "Continue? [y/N] "
  local reply
  read -r reply
  if [[ ! "$reply" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    return 0
  fi
  echo "$vms" | while read -r vm; do
    echo "Destroying $vm..."
    limactl stop "$vm" &>/dev/null
    limactl delete "$vm" --force &>/dev/null
    rm -f "$DEVM_STATE_DIR/.devm-version-${vm}"
  done
  echo "All VMs destroyed."
}

_devm_list() {
  limactl list | head -1
  limactl list | grep "^devm-" | grep -v "^devm-base " || echo "(no VMs)"
}

_devm_status() {
  local cwd
  cwd="$(pwd)"
  local current_project
  current_project=$(_devm_find_project_for_dir "$cwd" 2>/dev/null || echo "")
  local current_vm=""
  [[ -n "$current_project" ]] && current_vm=$(_devm_vm_name "$current_project")

  echo "VMs (current directory: $cwd):"
  echo ""

  local header
  header=$(limactl list | head -1)
  echo "$header" | sed 's/^/  /'

  limactl list | grep "^devm-" | grep -v "^devm-base " | while read -r line; do
    local vm_name
    vm_name=$(echo "$line" | awk '{print $1}')
    if [[ "$vm_name" == "$current_vm" ]]; then
      echo "$line" | sed 's/^/> /'
    else
      echo "$line" | sed 's/^/  /'
    fi
  done || echo "  (no VMs)"
}

# ─── Entrypoint ─────────────────────────────────────────────────────────────
# If executed directly (not sourced), run the devm function with all arguments.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]] || [[ "${ZSH_EVAL_CONTEXT:-}" != *:file:* && "${BASH_SOURCE[0]:-}" == "" ]]; then
  devm "$@"
fi
