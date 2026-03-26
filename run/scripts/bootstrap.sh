#!/usr/bin/env bash
set -euo pipefail

# Every stage captures stderr to LOG_DIR for crash diagnostics.
# Logs are uploaded as an artifact (always, even on failure) via action.yml.

VERSIONS_FILE="${GITHUB_ACTION_PATH:-$(dirname "$(dirname "$0")")}/versions.json"
BIN_DIR="${HOME}/.indieprise/bin"
LOG_DIR="/tmp/indieprise-bootstrap-logs"
mkdir -p "$BIN_DIR" "$LOG_DIR"

MIGRATAUR_VERSION=$(jq -r '.migrataur.version' "$VERSIONS_FILE")
MIGRATAUR_REPO=$(jq -r '.migrataur.repo' "$VERSIONS_FILE")
MIGRATAUR_BINARY=$(jq -r '.migrataur.binary' "$VERSIONS_FILE")

PREXPLAINER_VERSION=$(jq -r '.prexplainer.version' "$VERSIONS_FILE")
PREXPLAINER_REPO=$(jq -r '.prexplainer.repo' "$VERSIONS_FILE")
PREXPLAINER_BINARY=$(jq -r '.prexplainer.binary' "$VERSIONS_FILE")

# ── Detect LLM provider ──────────────────────────────────────────────────────
# Cloud API keys take priority over Ollama. If any cloud key is set, skip
# Ollama entirely — no install, no model pull, no SSH keys needed.
LLM_PROVIDER=""
LLM_MODEL=""

if [ -n "${MIGRATAUR_ANTHROPIC_KEY:-}" ]; then
  LLM_PROVIDER="anthropic"
  LLM_MODEL="${MIGRATAUR_LLM_MODEL:-claude-haiku-4-5-20251001}"
  export ANTHROPIC_API_KEY="$MIGRATAUR_ANTHROPIC_KEY"
elif [ -n "${MIGRATAUR_OPENAI_KEY:-}" ]; then
  LLM_PROVIDER="openai"
  LLM_MODEL="${MIGRATAUR_LLM_MODEL:-gpt-4.1-mini}"
  export OPENAI_API_KEY="$MIGRATAUR_OPENAI_KEY"
elif [ -n "${MIGRATAUR_GEMINI_KEY:-}" ]; then
  LLM_PROVIDER="google"
  LLM_MODEL="${MIGRATAUR_LLM_MODEL:-gemini-2.5-flash}"
  export GEMINI_API_KEY="$MIGRATAUR_GEMINI_KEY"
elif [ -n "${MIGRATAUR_OPENROUTER_KEY:-}" ]; then
  LLM_PROVIDER="openrouter"
  LLM_MODEL="${MIGRATAUR_LLM_MODEL:-anthropic/claude-haiku-4-5-20251001}"
  export OPENROUTER_API_KEY="$MIGRATAUR_OPENROUTER_KEY"
else
  LLM_PROVIDER="ollama"
  LLM_MODEL="${MIGRATAUR_LLM_MODEL:-kimi-k2.5:cloud}"
fi

echo "LLM provider: $LLM_PROVIDER (model: $LLM_MODEL)"

# ── Download binaries ─────────────────────────────────────────────────────────
echo "::group::Download Indieprise binaries"

if [ -x "$BIN_DIR/migrataur" ]; then
  echo "migrataur already cached at $BIN_DIR/migrataur — skipping download"
else
  echo "Downloading migrataur ${MIGRATAUR_VERSION} from ${MIGRATAUR_REPO}..."
  gh release download "$MIGRATAUR_VERSION" \
    --repo "$MIGRATAUR_REPO" \
    --pattern "$MIGRATAUR_BINARY" \
    --output "$BIN_DIR/migrataur"
  chmod +x "$BIN_DIR/migrataur"
  echo "migrataur downloaded successfully"

  # Download and extract extensions
  echo "Downloading migrataur extensions..."
  gh release download "$MIGRATAUR_VERSION" \
    --repo "$MIGRATAUR_REPO" \
    --pattern "migrataur-extensions.tar.gz" \
    --output "/tmp/migrataur-extensions.tar.gz"
  mkdir -p "$BIN_DIR/extensions"
  tar -xzf /tmp/migrataur-extensions.tar.gz -C "$BIN_DIR/extensions"
  rm /tmp/migrataur-extensions.tar.gz
  echo "Extensions extracted to $BIN_DIR/extensions"
fi

# Set extension dir for migrataur to find Pi extension
echo "MIGRATAUR_EXTENSION_DIR=$BIN_DIR/extensions/pi-extension" >> "$GITHUB_ENV"

if [ "$PREXPLAINER_VERSION" != "null" ] && [ -n "$PREXPLAINER_VERSION" ]; then
  if [ -x "$BIN_DIR/prexplainer" ]; then
    echo "prexplainer already cached at $BIN_DIR/prexplainer — skipping download"
  else
    echo "Downloading prexplainer ${PREXPLAINER_VERSION} from ${PREXPLAINER_REPO}..."
    gh release download "$PREXPLAINER_VERSION" \
      --repo "$PREXPLAINER_REPO" \
      --pattern "$PREXPLAINER_BINARY" \
      --output "$BIN_DIR/prexplainer"
    chmod +x "$BIN_DIR/prexplainer"
    echo "prexplainer downloaded successfully"
  fi
else
  echo "prexplainer not configured — skipping (Phase B)"
fi

echo "::endgroup::"

# ── Ollama (only if provider=ollama) ──────────────────────────────────────────
if [ "$LLM_PROVIDER" = "ollama" ]; then
  echo "::group::Install Ollama"

  if command -v ollama &>/dev/null; then
    echo "Ollama already installed at $(command -v ollama) — skipping install"
  else
    echo "Installing Ollama..."
    curl -fsSL https://ollama.com/install.sh 2>"$LOG_DIR/ollama-install.stderr" | sh 2>>"$LOG_DIR/ollama-install.stderr"
    if ! command -v ollama &>/dev/null; then
      echo "::error::Ollama not on PATH after install"
      cat "$LOG_DIR/ollama-install.stderr"
      exit 1
    fi
    echo "Ollama installed"
  fi

  echo "::endgroup::"

  # Configure Ollama SSH keys (for cloud models)
  if [ -n "${INDIEPRISE_RUNTIME_KEY:-}" ]; then
    echo "::group::Configure Ollama SSH key"
    mkdir -p "${HOME}/.ollama"
    echo "$INDIEPRISE_RUNTIME_KEY" > "${HOME}/.ollama/id_ed25519"
    chmod 600 "${HOME}/.ollama/id_ed25519"
    echo "Ollama SSH key written"
    echo "::endgroup::"
  fi

  # Start Ollama server
  echo "::group::Start Ollama server"

  if ! curl -sf http://127.0.0.1:11434/api/tags &>/dev/null; then
    ollama serve >"$LOG_DIR/ollama-serve.stdout" 2>"$LOG_DIR/ollama-serve.stderr" &
    echo "Started ollama serve in background (PID $!)"
  fi

  echo "Waiting for Ollama to be ready..."
  OLLAMA_READY=false
  for i in $(seq 1 30); do
    if curl -sf http://127.0.0.1:11434/api/tags &>/dev/null; then
      OLLAMA_READY=true
      echo "Ollama is ready (attempt $i)"
      break
    fi
    sleep 1
  done
  if [ "$OLLAMA_READY" != "true" ]; then
    echo "::error::Ollama did not become ready within 30 seconds"
    cat "$LOG_DIR/ollama-serve.stderr" 2>/dev/null || echo "(no log)"
    systemctl status ollama 2>/dev/null || true
    exit 1
  fi

  echo "::endgroup::"

  # Pull model
  echo "::group::Pull Ollama model"
  echo "Pulling $LLM_MODEL..."
  ollama pull "$LLM_MODEL" 2>"$LOG_DIR/ollama-pull.stderr"
  if [ $? -ne 0 ]; then
    echo "::error::Failed to pull model $LLM_MODEL"
    cat "$LOG_DIR/ollama-pull.stderr"
    exit 1
  fi
  echo "Model pull complete"
  echo "::endgroup::"

else
  echo "::group::Cloud LLM provider ($LLM_PROVIDER)"
  echo "Skipping Ollama — using $LLM_PROVIDER with model $LLM_MODEL"
  echo "::endgroup::"
fi

# ── Install Pi ────────────────────────────────────────────────────────────────
echo "::group::Install Pi"

if command -v pi &>/dev/null; then
  echo "Pi already installed at $(command -v pi) — skipping"
else
  echo "Installing Pi via npm..."
  sudo npm install -g @mariozechner/pi-coding-agent 2>"$LOG_DIR/pi-install.stderr"
  if [ $? -ne 0 ]; then
    echo "::error::npm install -g @mariozechner/pi-coding-agent failed"
    cat "$LOG_DIR/pi-install.stderr"
    exit 1
  fi
  echo "Pi installed"
fi

PI_PATH=$(command -v pi 2>/dev/null || true)
if [ -z "$PI_PATH" ]; then
  echo "::error::pi CLI not found on PATH after install"
  echo "npm global bin: $(npm bin -g 2>/dev/null || echo 'unknown')"
  cat "$LOG_DIR/pi-install.stderr" 2>/dev/null || true
  exit 1
fi
echo "Pi at: $PI_PATH ($(pi --version 2>/dev/null || echo 'unknown version'))"

echo "::endgroup::"

# ── Configure Pi ──────────────────────────────────────────────────────────────
echo "::group::Configure Pi"

PI_CONFIG_DIR="${HOME}/.pi/agent"
mkdir -p "$PI_CONFIG_DIR"

if [ "$LLM_PROVIDER" = "ollama" ]; then
  # Ollama: write models.json with local provider
  cat > "$PI_CONFIG_DIR/models.json" <<'MODELSEOF'
{
  "providers": {
    "ollama": {
      "api": "openai-completions",
      "apiKey": "ollama",
      "baseUrl": "http://127.0.0.1:11434/v1",
      "models": [
        { "_launch": true, "id": "kimi-k2.5:cloud", "input": ["text", "image"], "reasoning": true },
        { "id": "qwen3:8b", "input": ["text"], "reasoning": false },
        { "id": "qwen3:30b-a3b", "input": ["text"], "reasoning": true },
        { "id": "gemma3:4b-cloud", "input": ["text"], "reasoning": false },
        { "id": "gemma3:27b-cloud", "input": ["text"], "reasoning": false },
        { "id": "deepseek-v3.1:671b-cloud", "input": ["text"], "reasoning": true },
        { "id": "qwen3-coder:480b-cloud", "input": ["text"], "reasoning": true },
        { "id": "gpt-oss:20b-cloud", "input": ["text"], "reasoning": false }
      ]
    }
  }
}
MODELSEOF

  if ! jq empty "$PI_CONFIG_DIR/models.json" 2>"$LOG_DIR/pi-config-validate.stderr"; then
    echo "::error::models.json is not valid JSON"
    cat "$LOG_DIR/pi-config-validate.stderr"
    exit 1
  fi
  echo "Pi models.json written (Ollama provider)"
fi

# Write settings.json with detected provider
cat > "$PI_CONFIG_DIR/settings.json" <<EOF
{
  "defaultModel": "$LLM_MODEL",
  "defaultProvider": "$LLM_PROVIDER"
}
EOF
echo "Pi settings.json written (provider=$LLM_PROVIDER, model=$LLM_MODEL)"

echo "::endgroup::"

# ── Health check ──────────────────────────────────────────────────────────────
echo "::group::Health check"

if [ "$LLM_PROVIDER" = "ollama" ]; then
  OLLAMA_V1_STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:11434/v1/models 2>/dev/null || echo "000")
  if [ "$OLLAMA_V1_STATUS" != "200" ]; then
    echo "::warning::Ollama /v1/models returned HTTP $OLLAMA_V1_STATUS"
  else
    echo "Ollama /v1/models OK"
  fi
else
  echo "Cloud provider $LLM_PROVIDER — API key present, no local health check needed"
fi

echo "::endgroup::"

# ── Export binary path ────────────────────────────────────────────────────────
echo "$BIN_DIR" >> "$GITHUB_PATH"

# ── Final verification ────────────────────────────────────────────────────────
echo "::group::Bootstrap verification"
"$BIN_DIR/migrataur" --version 2>"$LOG_DIR/migrataur-version.stderr" || {
  echo "::warning::migrataur --version failed"; cat "$LOG_DIR/migrataur-version.stderr"; }
if [ "$LLM_PROVIDER" = "ollama" ]; then
  echo "ollama: $(ollama --version 2>/dev/null || echo 'unknown')"
fi
echo "pi: $(pi --version 2>/dev/null || echo 'unknown')"
echo "provider: $LLM_PROVIDER | model: $LLM_MODEL"
echo "Log dir: $LOG_DIR"
ls -la "$LOG_DIR/"
echo "Bootstrap complete."
echo "::endgroup::"
