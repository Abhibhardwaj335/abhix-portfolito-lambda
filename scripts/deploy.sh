#!/bin/bash
# =============================================================================
# abhix-portfolio-lambda — Deploy Script
# Usage:
#   bash scripts/deploy.sh          # deploy to dev stage
#   bash scripts/deploy.sh prod     # deploy to prod stage
# =============================================================================

set -e

STAGE="${1:-dev}"
REGION="ap-south-1"
SERVICE="abhix-portfolio-lambda"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LAMBDA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PORTFOLIO_DIR="$(cd "$LAMBDA_DIR/../abhix-portfolio" && pwd)"

# ── Colours ───────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
BLUE='\033[0;34m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log()      { echo -e "${GREEN}[DEPLOY]${NC} $1"; }
info()     { echo -e "${BLUE}[INFO]${NC}   $1"; }
warn()     { echo -e "${YELLOW}[WARN]${NC}   $1"; }
error()    { echo -e "${RED}[ERROR]${NC}  $1"; }
section()  { echo -e "\n${CYAN}━━━ $1 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

section "abhix-portfolio-lambda Deploy"
info "Service : $SERVICE"
info "Stage   : $STAGE"
info "Region  : $REGION"
echo ""

# ── Step 1: Pre-flight checks ─────────────────────────────────────────────────
section "Step 1: Pre-flight checks"

cd "$LAMBDA_DIR"

[ ! -f "serverless.yml" ] && { error "serverless.yml not found. Run from lambda root or via scripts/deploy.sh"; exit 1; }
[ ! -f "package.json"   ] && { error "package.json not found."; exit 1; }

command -v node &>/dev/null || { error "Node.js is not installed."; exit 1; }
command -v npm  &>/dev/null || { error "npm is not installed."; exit 1; }
command -v aws  &>/dev/null || { error "AWS CLI is not installed. Install: https://aws.amazon.com/cli/"; exit 1; }

aws sts get-caller-identity &>/dev/null || {
  error "AWS credentials not configured. Run: aws configure"
  exit 1
}

AWS_ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
info "Node    : $(node -v)"
info "npm     : $(npm -v)"
info "AWS Acct: $AWS_ACCOUNT"
log "✓ Pre-flight passed"

# ── Step 2: Load .env ─────────────────────────────────────────────────────────
section "Step 2: Environment"

if [ ! -f ".env" ]; then
  if [ -f ".env.example" ]; then
    warn ".env not found — copying from .env.example"
    warn "Edit .env with real EMAIL_APP_PASSWORD before deploying!"
    cp .env.example .env
  else
    error ".env not found. Create it from .env.example"
    exit 1
  fi
fi

set -a; source .env; set +a

# Validate critical vars
MISSING=()
[ -z "$EMAIL_USER"         ] && MISSING+=("EMAIL_USER")
[ -z "$EMAIL_APP_PASSWORD" ] && MISSING+=("EMAIL_APP_PASSWORD")
[ -z "$OWNER_EMAIL"        ] && MISSING+=("OWNER_EMAIL")

if [ ${#MISSING[@]} -gt 0 ]; then
  error "Missing required .env vars: ${MISSING[*]}"
  error "Edit .env and fill in the values, then re-run."
  exit 1
fi

# Override ALLOWED_ORIGIN based on stage if not explicitly set
if [ -z "$ALLOWED_ORIGIN" ]; then
  if [ "$STAGE" = "prod" ]; then
    export ALLOWED_ORIGIN="https://www.abhix.in"
  else
    export ALLOWED_ORIGIN="http://localhost:5173"
  fi
fi

info "EMAIL_USER     : $EMAIL_USER"
info "OWNER_EMAIL    : $OWNER_EMAIL"
info "ALLOWED_ORIGIN : $ALLOWED_ORIGIN"
log "✓ Environment loaded"

# ── Step 3: Install dependencies ──────────────────────────────────────────────
section "Step 3: Dependencies"

if [ ! -d "node_modules" ]; then
  info "Running npm install..."
  npm install
else
  info "node_modules present — skipping install"
fi

# Ensure serverless is available (local or global)
if ! npx --no -- serverless --version &>/dev/null 2>&1; then
  warn "Serverless not found — installing locally..."
  npm install --save-dev serverless
fi

log "✓ Dependencies ready"

# ── Step 4: TypeScript build ──────────────────────────────────────────────────
section "Step 4: TypeScript Build"

info "Cleaning dist/..."
rm -rf dist

info "Compiling TypeScript..."
npm run build || { error "TypeScript build failed."; exit 1; }

[ ! -f "dist/handler.js" ] && { error "dist/handler.js missing after build!"; exit 1; }
log "✓ Build successful"

# ── Step 5: Serverless deploy (create or update) ──────────────────────────────
section "Step 5: Serverless Deploy → API Gateway + Lambda"

info "Running: serverless deploy --stage $STAGE --region $REGION"
echo ""

npx serverless deploy \
  --stage   "$STAGE"  \
  --region  "$REGION" \
  --verbose \
  || { error "Serverless deploy failed."; exit 1; }

log "✓ Deploy complete"

# ── Step 6: Get API endpoint ───────────────────────────────────────────────────
section "Step 6: Retrieve API Endpoint"

API_ENDPOINT=""

# Try serverless info first
SLS_INFO=$(npx serverless info --stage "$STAGE" --region "$REGION" 2>/dev/null || true)
API_ENDPOINT=$(echo "$SLS_INFO" | grep -E "(ServiceEndpoint|endpoint):" | head -1 | awk '{print $2}' | tr -d '[:space:]')

# Fallback: CloudFormation stack output
if [ -z "$API_ENDPOINT" ]; then
  STACK_NAME="${SERVICE}-${STAGE}"
  info "Querying CloudFormation stack: $STACK_NAME..."
  API_ENDPOINT=$(aws cloudformation describe-stacks \
    --region "$REGION" \
    --stack-name "$STACK_NAME" \
    --query "Stacks[0].Outputs[?OutputKey=='ServiceEndpoint'].OutputValue" \
    --output text 2>/dev/null || echo "")
fi

if [ -z "$API_ENDPOINT" ]; then
  warn "Could not auto-detect API endpoint."
  warn "Check the Serverless output above for 'ServiceEndpoint', then:"
  warn "  Set VITE_ABHI_PORTFOLIO_API_URL in abhix-portfolio/.env.local manually"
else
  CONTACT_URL="${API_ENDPOINT}/contact"
  info "API Endpoint : $API_ENDPOINT"
  info "Contact URL  : $CONTACT_URL"

  # ── Step 7: Inject URL into portfolio frontend ─────────────────────────────
  section "Step 7: Update Portfolio Frontend .env"

  ENV_LOCAL="$PORTFOLIO_DIR/.env.local"

  if [ -f "$ENV_LOCAL" ]; then
    if grep -q "VITE_ABHI_PORTFOLIO_API_URL" "$ENV_LOCAL"; then
      # Update existing entry (macOS + Linux compatible)
      sed -i '' "s|VITE_ABHI_PORTFOLIO_API_URL=.*|VITE_ABHI_PORTFOLIO_API_URL=${CONTACT_URL}|g" "$ENV_LOCAL" 2>/dev/null \
        || sed -i "s|VITE_ABHI_PORTFOLIO_API_URL=.*|VITE_ABHI_PORTFOLIO_API_URL=${CONTACT_URL}|g" "$ENV_LOCAL"
      info "✓ Updated VITE_ABHI_PORTFOLIO_API_URL in $ENV_LOCAL"
    else
      echo "VITE_ABHI_PORTFOLIO_API_URL=${CONTACT_URL}" >> "$ENV_LOCAL"
      info "✓ Appended VITE_ABHI_PORTFOLIO_API_URL to $ENV_LOCAL"
    fi
  else
    echo "VITE_ABHI_PORTFOLIO_API_URL=${CONTACT_URL}" > "$ENV_LOCAL"
    info "✓ Created $ENV_LOCAL with VITE_ABHI_PORTFOLIO_API_URL"
  fi

  log "✓ Frontend env updated"
fi

# ── Step 8: Smoke test ────────────────────────────────────────────────────────
if [ -n "$API_ENDPOINT" ]; then
  section "Step 8: Smoke Test"
  info "Sending OPTIONS preflight to $CONTACT_URL..."

  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X OPTIONS "${CONTACT_URL}" \
    -H "Origin: $ALLOWED_ORIGIN" \
    -H "Access-Control-Request-Method: POST" \
    2>/dev/null || echo "000")

  if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "204" ]; then
    log "✓ CORS preflight passed (HTTP $HTTP_CODE)"
  else
    warn "CORS preflight returned HTTP $HTTP_CODE"
    warn "Lambda may need a cold start — wait 10s and re-test manually."
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
section "✅  Deploy Complete"
echo ""
log "  Service   : $SERVICE"
log "  Stage     : $STAGE"
log "  Region    : $REGION"
log "  Contact   : ${CONTACT_URL:-<check output above>}"
echo ""
info "Useful commands:"
info "  View logs  : cd abhix-portfolio-lambda && npm run logs"
info "  Redeploy   : bash scripts/deploy.sh $STAGE"
info "  Prod deploy: bash scripts/deploy.sh prod"
info "  Local dev  : npm run offline  (runs on http://localhost:4000)"
echo ""
info "Next: rebuild and redeploy the portfolio frontend"
info "  cd .. && npm run build && <your frontend deploy command>"
echo ""
