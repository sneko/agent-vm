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
#   devm provision [name]      - Update dev tools in a running VM
#   devm stop [name]           - Stop the VM
#   devm rm [name]             - Destroy the VM (keeps config)
#   devm list                  - List all devm VMs
#   devm status                - Show status of all VMs
#   devm help                  - Show help
#

# ─── Embedded setup script (runs inside the VM during "devm setup") ─────────

# ─── Base setup script (runs inside VM during "devm setup") ─────────────────
# Installs OS-level packages that rarely change. Baked into the template.

read -r -d '' DEVM_BASE_SETUP << 'BASE_SETUP_EOF'
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
  iptables \
  zsh-syntax-highlighting \
  zsh-autosuggestions

# Set zsh as default shell
sudo chsh -s /usr/bin/zsh "$(whoami)"

# Enable zsh plugins and colors
cat >> ~/.zshrc << 'ZSHRC'
# Syntax highlighting and autosuggestions
[ -f /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh ] && source /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
[ -f /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh ] && source /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh

# Colors
alias ls='ls --color=auto'
alias grep='grep --color=auto'
export CLICOLOR=1
ZSHRC

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

# Create /devm mount root
sudo mkdir -p /devm

# Shell config (PS1, PATH placeholders)
echo 'export PS1="%F{cyan}devm%f:%F{yellow}%1~%f%% "' >> ~/.zshrc

echo "Base setup complete."
BASE_SETUP_EOF

# ─── Provision script (runs on first start of each VM, idempotent) ──────────
# Installs user-space tools (claude, mise, etc.). Can be re-run to update.

read -r -d '' DEVM_PROVISION_SCRIPT << 'PROVISION_EOF'
set -euo pipefail

echo "Provisioning/updating dev tools..."

# Install mise (manages .tool-versions, .nvmrc, .node-version, .python-version, etc.)
echo "Installing/updating mise..."
curl -fsSL https://mise.run | sh
grep -q 'mise activate' ~/.zshrc 2>/dev/null || echo 'eval "$(~/.local/bin/mise activate zsh)"' >> ~/.zshrc
grep -q 'mise activate' ~/.zshenv 2>/dev/null || echo 'eval "$(~/.local/bin/mise activate zsh)"' >> ~/.zshenv

# Install Claude Code
echo "Installing/updating Claude Code..."
curl -fsSL https://claude.ai/install.sh | bash
grep -q '.claude/local/bin' ~/.zshrc 2>/dev/null || echo 'export PATH=$HOME/.local/bin:$HOME/.claude/local/bin:$PATH' >> ~/.zshrc

# Install OpenCode
echo "Installing/updating OpenCode..."
curl -fsSL https://opencode.ai/install | bash
grep -q '.opencode/bin' ~/.zshrc 2>/dev/null || echo 'export PATH=$HOME/.opencode/bin:$PATH' >> ~/.zshrc

# Ensure PATH in .zshenv for non-interactive shells
grep -q '.claude/local/bin' ~/.zshenv 2>/dev/null || echo 'export PATH=$HOME/.local/bin:$HOME/.claude/local/bin:$HOME/.opencode/bin:$PATH' >> ~/.zshenv

# Install Codex CLI
echo "Installing/updating Codex CLI..."
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

echo "Provisioning complete."
PROVISION_EOF

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
  # Resolve relative paths to absolute
  if [[ "$p" != /* ]]; then
    if [[ -d "$p" ]]; then
      p="$(cd "$p" && pwd)"
    else
      # Path doesn't exist yet — resolve as best we can
      p="$(cd "$(dirname "$p")" 2>/dev/null && echo "$(pwd)/$(basename "$p")" || echo "$(pwd)/$p")"
    fi
  fi
  # Remove any trailing slashes or dots
  p="${p%/}"
  p="${p%.}"
  p="${p%/}"
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

# List mount lines (raw, with :rw/:ro suffix) for a project
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
    if [[ $in_section -eq 1 ]] && [[ "$line" =~ ^mount=(.+)$ ]]; then
      echo "$(_devm_resolve_path "${BASH_REMATCH[1]}")"
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
# Usage: _devm_config_write_project <name> [--cpus N] [--memory GB] [--disk GB] [--ports LIST] [folders...]
_devm_config_write_project() {
  local name="$1"; shift
  local cpus="" memory="" disk="" ports=""
  local folders=()
  local env_entries=()
  local env_provided=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cpus)   cpus="$2"; shift 2 ;;
      --memory) memory="$2"; shift 2 ;;
      --disk)   disk="$2"; shift 2 ;;
      --ports)  ports="$2"; shift 2 ;;
      --env)
        env_provided=1
        # Parse comma-separated: VAR=value or VAR (forward from host)
        IFS=',' read -ra items <<< "$2"
        for item in "${items[@]}"; do
          item="$(echo "$item" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
          [[ -z "$item" ]] && continue
          if [[ "$item" == *=* ]]; then
            # VAR=value → hardcoded
            env_entries+=("env.${item}")
          else
            # VAR → forward from host (no =)
            env_entries+=("env.${item}")
          fi
        done
        shift 2
        ;;
      *)        folders+=("$1"); shift ;;
    esac
  done

  # Read existing values as defaults
  local old_cpus old_memory old_disk old_ports
  old_cpus=$(_devm_config_get "$name" "cpus" 2>/dev/null || echo "")
  old_memory=$(_devm_config_get "$name" "memory" 2>/dev/null || echo "")
  old_disk=$(_devm_config_get "$name" "disk" 2>/dev/null || echo "")
  old_ports=$(_devm_config_get "$name" "ports" 2>/dev/null || echo "")

  cpus="${cpus:-${old_cpus:-1}}"
  memory="${memory:-${old_memory:-2}}"
  disk="${disk:-${old_disk:-10}}"
  ports="${ports:-${old_ports:-}}"

  # Preserve existing env entries if --env was not provided
  if [[ $env_provided -eq 0 ]] && [[ -f "$DEVM_CONFIG" ]]; then
    local in_section=0
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      if [[ "$line" =~ ^\[(.+)\]$ ]]; then
        [[ "${BASH_REMATCH[1]}" == "$name" ]] && in_section=1 || in_section=0
        continue
      fi
      if [[ $in_section -eq 1 ]] && [[ "$line" =~ ^env\.[a-zA-Z_] ]]; then
        env_entries+=("$line")
      fi
    done < "$DEVM_CONFIG"
  fi

  # Get existing folders if no new folders provided
  if [[ ${#folders[@]} -eq 0 ]]; then
    while IFS= read -r f; do
      [[ -n "$f" ]] && folders+=("$f")
    done <<< "$(_devm_config_folders_raw "$name" 2>/dev/null)"
  fi

  if [[ ${#folders[@]} -eq 0 ]]; then
    echo "Error: No folders specified for '$name'." >&2
    echo "" >&2
    echo "Usage: devm create <name> <folder> [folder...] [options]" >&2
    echo "" >&2
    echo "You must specify at least one folder to mount in the VM." >&2
    echo "The first folder is used as the default working directory." >&2
    echo "" >&2
    echo "Examples:" >&2
    echo "  devm create $name ~/code/$name" >&2
    echo "  devm create $name ~/code/frontend ~/code/backend --cpus 4" >&2
    echo "  devm create $name ~/code/myrepo ~/shared/libs:rw" >&2
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
  [[ -n "$ports" ]] && echo "ports=$ports" >> "$tmpfile"
  for e in "${env_entries[@]}"; do
    echo "$e" >> "$tmpfile"
  done
  for f in "${folders[@]}"; do
    echo "mount=$f" >> "$tmpfile"
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
# Security: each mount uses sshfs.followSymlinks=false to prevent symlink escape
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
    mounts+="{\"location\":\"${host_path}\",\"mountPoint\":\"${vm_mount}\",\"writable\":${writable},\"sshfs\":{\"followSymlinks\":false}}"
  done <<< "$(_devm_config_folders_raw "$project")"

  mounts+="]"
  echo "$mounts"
}

# Build Lima portForwards JSON from config ports= setting
# Disables automatic port forwarding; only listed ports are forwarded to localhost
_devm_build_port_forwards() {
  local project="$1"
  local ports_str
  ports_str=$(_devm_config_get "$project" "ports" 2>/dev/null || echo "")

  local forwards="["
  local first=1

  # Add explicit port forwards
  if [[ -n "$ports_str" ]]; then
    IFS=',' read -ra port_list <<< "$ports_str"
    for port in "${port_list[@]}"; do
      port="$(echo "$port" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
      [[ -z "$port" ]] && continue
      [[ $first -eq 1 ]] && first=0 || forwards+=","
      forwards+="{\"guestPort\":${port},\"hostPort\":${port},\"guestIP\":\"127.0.0.1\",\"hostIP\":\"127.0.0.1\",\"proto\":\"tcp\"}"
    done
  fi

  # Disable automatic port forwarding for all other ports
  [[ $first -eq 1 ]] && first=0 || forwards+=","
  forwards+="{\"guestIP\":\"127.0.0.1\",\"proto\":\"tcp\",\"ignore\":true}"

  forwards+="]"
  echo "$forwards"
}

# Parse env vars from config for a project
# Config format:
#   env.VAR_NAME          → forward from host environment
#   env.VAR_NAME=         → set to empty string
#   env.VAR_NAME=value    → hardcoded value
# Outputs export commands
_devm_build_env_exports() {
  local project="$1"
  local in_section=0
  [[ -f "$DEVM_CONFIG" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -z "$line" ]] && continue
    if [[ "$line" =~ ^\[(.+)\]$ ]]; then
      [[ "${BASH_REMATCH[1]}" == "$project" ]] && in_section=1 || in_section=0
      continue
    fi
    if [[ $in_section -eq 1 ]] && [[ "$line" =~ ^env\.([a-zA-Z_][a-zA-Z0-9_]*)(=(.*))?$ ]]; then
      local var_name="${BASH_REMATCH[1]}"
      local has_equals="${BASH_REMATCH[2]}"
      local var_val="${BASH_REMATCH[3]}"

      if [[ -z "$has_equals" ]]; then
        # env.VAR (no =) → forward from host
        local host_val="${!var_name:-}"
        if [[ -n "$host_val" ]]; then
          host_val="${host_val//\'/\'\\\'\'}"
          echo "export ${var_name}='${host_val}'"
        else
          echo "# Warning: ${var_name} not set on host" >&2
        fi
      elif [[ -n "$var_val" ]]; then
        # env.VAR=value → hardcoded
        var_val="${var_val//\'/\'\\\'\'}"
        echo "export ${var_name}='${var_val}'"
      else
        # env.VAR= → empty string
        echo "export ${var_name}=''"
      fi
    fi
  done < "$DEVM_CONFIG"
}

# Run a command inside the VM with env vars from config injected
# Usage: _devm_shell_exec <vm_name> <project> <workdir> [cmd...]
_devm_shell_exec() {
  local vm_name="$1" project="$2" workdir="$3"
  shift 3

  local env_exports
  env_exports=$(_devm_build_env_exports "$project")

  if [[ -n "$env_exports" && $# -gt 0 ]]; then
    # Wrap command with env exports
    limactl shell --workdir "$workdir" "$vm_name" bash -c "${env_exports}; exec \"\$@\"" -- "$@"
  elif [[ -n "$env_exports" ]]; then
    # Interactive shell: write env to a temp file, source it then exec zsh
    limactl shell --workdir "$workdir" "$vm_name" bash -c "${env_exports}; exec zsh -l"
  elif [[ $# -gt 0 ]]; then
    limactl shell --workdir "$workdir" "$vm_name" "$@"
  else
    limactl shell --workdir "$workdir" "$vm_name" zsh -l
  fi
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
    echo "Error: Base VM template not found." >&2
    echo "" >&2
    echo "Run the one-time setup first:" >&2
    echo "  devm setup" >&2
    echo "" >&2
    echo "This creates a base VM with system packages, Docker, Chromium, and dev tools." >&2
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
    echo "Error: No folders configured for '$project' in $DEVM_CONFIG." >&2
    echo "" >&2
    echo "Add folders to the [$project] section in $DEVM_CONFIG, or re-create:" >&2
    echo "  devm create $project ~/path/to/folder" >&2
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

    local mounts_json port_forwards_json
    mounts_json=$(_devm_build_mounts "$project")
    port_forwards_json=$(_devm_build_port_forwards "$project")

    local edit_args=()
    edit_args+=(--set ".mounts = ${mounts_json}")
    edit_args+=(--set ".portForwards = ${port_forwards_json}")
    # Security: block host env forwarding and SSH agent to prevent data leaking
    edit_args+=(--set '.propagateCurrentEnv = false')
    edit_args+=(--set '.ssh.forwardAgent = false')
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

        local mounts_json port_forwards_json
        mounts_json=$(_devm_build_mounts "$project")
        port_forwards_json=$(_devm_build_port_forwards "$project")
        local edit_args=(--set ".mounts = ${mounts_json}" --set ".portForwards = ${port_forwards_json}" --set '.propagateCurrentEnv = false' --set '.ssh.forwardAgent = false' --memory "$memory" --cpus "$cpus")
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

  # Security: apply per-mount protections
  while IFS= read -r raw_line; do
    [[ -z "$raw_line" ]] && continue
    local mode folder vm_folder
    mode=$(_devm_config_folder_mode "$raw_line")
    folder="${raw_line%:rw}"
    folder="${folder%:ro}"
    vm_folder="$(_devm_vm_path "$folder")"

    # Protect writable mounts against symlink escape (nosymfollow, Linux 5.10+)
    if [[ "$mode" == "rw" ]] || { [[ "$mode" == "auto" ]] && [[ -d "$folder/.git" ]]; }; then
      limactl shell "$vm_name" sudo mount -o remount,nosymfollow "$vm_folder" 2>/dev/null || true
    fi

    # Bind-mount .git as read-only for writable git folders
    if [[ "$mode" != "ro" ]] && [[ -d "$folder/.git" ]]; then
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
    provision)
      _devm_provision "$@"
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
      echo "Error: Unknown command '$cmd'." >&2
      echo "" >&2
      echo "Available commands: setup, create, shell, run, provision, stop, rm, destroy-all, list, status" >&2
      echo "" >&2
      echo "Run 'devm help' for full usage." >&2
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
  provision [name]                Update dev tools in a running VM
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
    ports=3000,8080
    env.ANTHROPIC_API_KEY
    env.DB_URL=postgres://localhost/mydb
    mount=~/code/myapp

    [fullstack]
    cpus=4
    memory=8
    disk=20
    ports=3000,5432,8080
    env.OPENAI_API_KEY
    mount=~/code/frontend
    mount=~/code/backend
    mount=~/shared/libs:rw
    mount=~/reference/docs

  Settings:
    cpus=N              Number of CPUs
    memory=N            Memory in GiB
    disk=N              Disk in GiB
    ports=P1,P2,...     Ports to forward from VM to host (localhost only)

  Environment variables (env.*):
    env.VAR             Forward VAR from host environment
    env.VAR=value       Set VAR to a hardcoded value
    env.VAR=            Set VAR to empty string

  Mounts (mount=):
    mount=/path         Smart default (git repos writable, others read-only)
    mount=/path:rw      Force writable
    mount=/path:ro      Force read-only

  Paths in the VM are under /devm/<absolute-host-path>, e.g.:
    ~/code/myapp → /devm/Users/you/code/myapp

  Edit ~/.devmconfig directly to customize or backup your configuration.

Security:
  - Host environment is NOT forwarded (use env= to whitelist specific vars)
  - Only explicitly listed ports are forwarded (auto-forwarding disabled)
  - Symlinks inside mounts cannot escape to the host filesystem
  - Writable mounts use nosymfollow to block symlink traversal
  - SSH agent forwarding is disabled (VM cannot access host credentials)
  - .git directories are bind-mounted read-only in writable git repos
  - Non-git folders are read-only by default

Examples:
  devm setup                                    # Create base VM
  devm create myapp ~/code/myapp --cpus 2 --ports 3000  # Define a VM
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

  # Run the base setup script inside the VM (OS packages, docker, chromium)
  echo "Installing system packages inside VM..."
  echo "$DEVM_BASE_SETUP" | limactl shell "$DEVM_TEMPLATE" bash -l || { echo "Error: Base setup failed." >&2; return 1; }

  # Run provisioning (user-space tools: claude, mise, opencode, codex)
  echo "Provisioning dev tools..."
  echo "$DEVM_PROVISION_SCRIPT" | limactl shell "$DEVM_TEMPLATE" bash -l || { echo "Error: Provisioning failed." >&2; return 1; }

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
  local name="" cpus="" memory="" disk="" ports="" env_vars=""
  local folders=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --cpus)   cpus="$2"; shift 2 ;;
      --cpus=*) cpus="${1#*=}"; shift ;;
      --memory|--ram) memory="$2"; shift 2 ;;
      --memory=*|--ram=*) memory="${1#*=}"; shift ;;
      --disk)   disk="$2"; shift 2 ;;
      --disk=*) disk="${1#*=}"; shift ;;
      --ports)  ports="$2"; shift 2 ;;
      --ports=*) ports="${1#*=}"; shift ;;
      --env)    env_vars="$2"; shift 2 ;;
      --env=*)  env_vars="${1#*=}"; shift ;;
      --help|-h)
        echo "Usage: devm create <name> [folder...] [options]"
        echo ""
        echo "Add or update a VM definition in ~/.devmconfig."
        echo "Folders can use :rw or :ro suffix to override mount mode."
        echo ""
        echo "Options:"
        echo "  --cpus N       Number of CPUs (default: 1)"
        echo "  --memory GB    Memory in GiB (default: 2)"
        echo "  --disk GB      Disk in GiB (default: 10)"
        echo "  --ports LIST   Comma-separated ports to forward (e.g. 3000,8080)"
        echo "  --env LIST     Comma-separated host env vars to pass to the VM"
        echo "                 (e.g. ANTHROPIC_API_KEY,OPENAI_API_KEY)"
        echo ""
        echo "Examples:"
        echo "  devm create myapp ~/code/myapp"
        echo "  devm create myapp ~/code/myapp --cpus 4 --memory 8"
        echo "  devm create myapp ~/code/myapp --ports 3000 --env ANTHROPIC_API_KEY"
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
    echo "Usage: devm create <name> [folder...] [options]" >&2
    echo "" >&2
    echo "Run 'devm create --help' for full usage." >&2
    return 1
  fi

  local write_args=()
  [[ -n "$cpus" ]]     && write_args+=(--cpus "$cpus")
  [[ -n "$memory" ]]   && write_args+=(--memory "$memory")
  [[ -n "$disk" ]]     && write_args+=(--disk "$disk")
  [[ -n "$ports" ]]    && write_args+=(--ports "$ports")
  [[ -n "$env_vars" ]] && write_args+=(--env "$env_vars")

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
  local cfg_ports
  cfg_ports=$(_devm_config_get "$name" ports 2>/dev/null || echo "none")
  echo "Resources: cpus=$(_devm_config_get "$name" cpus), memory=$(_devm_config_get "$name" memory) GiB, disk=$(_devm_config_get "$name" disk) GiB"
  echo "Ports: $cfg_ports"

  # Show env vars from the section we just wrote
  local env_lines=""
  local in_section=0
  while IFS= read -r line; do
    if [[ "$line" =~ ^\[(.+)\]$ ]]; then
      [[ "${BASH_REMATCH[1]}" == "$name" ]] && in_section=1 || in_section=0
      continue
    fi
    [[ $in_section -eq 1 ]] && [[ "$line" =~ ^env\.[a-zA-Z_] ]] && env_lines+="$line"$'\n'
  done < "$DEVM_CONFIG"
  if [[ -n "$env_lines" ]]; then
    echo "Env vars:"
    echo -n "$env_lines" | while IFS= read -r el; do
      local var_part="${el#env.}"
      if [[ "$var_part" == *=* ]]; then
        local vn="${var_part%%=*}"
        local vv="${var_part#*=}"
        if [[ -n "$vv" ]]; then
          echo "  $vn = (hardcoded)"
        else
          echo "  $vn = (empty)"
        fi
      else
        echo "  $var_part = (from host)"
      fi
    done
  fi
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
    _devm_error_no_vm "shell" "$project_arg"
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
  _devm_shell_exec "$vm_name" "$DEVM_PROJECT" "$DEVM_WORKDIR"
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
    echo "Error: No command specified." >&2
    echo "" >&2
    echo "Usage: devm run [name] <command> [args]" >&2
    echo "" >&2
    echo "Run any command inside the VM. Examples:" >&2
    echo "  devm run myapp npm install" >&2
    echo "  devm run myapp claude --dangerously-skip-permissions" >&2
    echo "  devm run myapp make build" >&2
    echo "" >&2
    echo "For an interactive shell, use: devm shell [name]" >&2
    return 1
  fi

  DEVM_PROJECT="" DEVM_WORKDIR=""
  if ! _devm_resolve_project "$project_arg"; then
    _devm_error_no_vm "run" "$project_arg"
    return 1
  fi

  local vm_name
  vm_name=$(_devm_vm_name "$DEVM_PROJECT")

  _devm_ensure_running "$vm_name" "$DEVM_PROJECT" "${vm_opts[@]}" || return 1

  DEVM_LAST_PROJECT="$DEVM_PROJECT"
  _devm_shell_exec "$vm_name" "$DEVM_PROJECT" "$DEVM_WORKDIR" "${cmd_args[@]}"
}

_devm_resolve_project_arg() {
  local arg="$1"
  if [[ -n "$arg" ]] && _devm_config_has_project "$arg"; then
    echo "$arg"
    return 0
  fi
  _devm_find_project_for_dir "$(pwd)"
}

# Print a helpful error when no VM can be resolved
# Usage: _devm_error_no_vm <command> [attempted_name]
_devm_error_no_vm() {
  local cmd="$1"
  local attempted="${2:-}"
  if [[ -n "$attempted" ]]; then
    echo "Error: Unknown VM name '$attempted'." >&2
  else
    echo "Error: Cannot determine which VM to use." >&2
    echo "  Current directory ($(pwd)) does not match any VM in $DEVM_CONFIG." >&2
  fi
  echo "" >&2
  echo "Either specify a VM name or cd into a configured folder:" >&2
  echo "  devm $cmd <name>" >&2
  echo "" >&2
  local projects
  projects=$(_devm_config_projects 2>/dev/null)
  if [[ -n "$projects" ]]; then
    echo "Available VMs:" >&2
    echo "$projects" | while read -r p; do
      echo "  - $p" >&2
    done
  else
    echo "No VMs configured yet. Create one first:" >&2
    echo "  devm create <name> <folder>" >&2
  fi
}

_devm_provision() {
  local project_arg=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help|-h)
        echo "Usage: devm provision [name]"
        echo ""
        echo "Install/update dev tools (claude, mise, opencode, codex) inside a running VM."
        echo ""
        echo "Examples:"
        echo "  devm provision myapp"
        echo "  devm provision           # auto-detect from current directory"
        return 0
        ;;
      *)
        [[ -z "$project_arg" ]] && _devm_config_has_project "$1" && project_arg="$1"
        shift
        ;;
    esac
  done

  local project
  project=$(_devm_resolve_project_arg "$project_arg")
  if [[ -z "$project" ]]; then
    _devm_error_no_vm "provision" "$project_arg"
    return 1
  fi

  local vm_name
  vm_name=$(_devm_vm_name "$project")

  if ! _devm_running "$vm_name"; then
    echo "Error: VM '$vm_name' is not running." >&2
    echo "" >&2
    echo "Start it first, then provision:" >&2
    echo "  devm shell $project" >&2
    echo "  devm provision $project" >&2
    return 1
  fi

  echo "Updating dev tools in '$vm_name'..."
  echo "$DEVM_PROVISION_SCRIPT" | limactl shell "$vm_name" bash -l || {
    echo "Error: Provisioning failed." >&2
    return 1
  }
  echo "Done. Tools updated in '$vm_name'."
}

_devm_stop() {
  local project
  project=$(_devm_resolve_project_arg "$1")
  if [[ -z "$project" ]]; then
    _devm_error_no_vm "stop" "$1"
    return 1
  fi

  local vm_name
  vm_name=$(_devm_vm_name "$project")

  if ! _devm_exists "$vm_name"; then
    echo "Error: No VM exists for '$project'." >&2
    echo "" >&2
    echo "The VM may not have been started yet. Use 'devm shell $project' to create and start it." >&2
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
    _devm_error_no_vm "rm" "$1"
    return 1
  fi

  local vm_name
  vm_name=$(_devm_vm_name "$project")

  if ! _devm_exists "$vm_name"; then
    echo "Error: No VM exists for '$project'." >&2
    echo "" >&2
    echo "Nothing to destroy. The config entry in $DEVM_CONFIG is unchanged." >&2
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
