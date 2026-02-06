#!/bin/bash
# hive worker deploy - Deploy and setup a worker on a cloud provider
# Currently supports: Hetzner (dedicated servers via Robot API)

set -e

HIVE_DIR="${HIVE_DIR:-/etc/hive}"
HIVE_TOOLS="${HIVE_TOOLS:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DEPLOYMENTS_DIR="$HIVE_DIR/deployments"
CONFIG_FILE="$HIVE_DIR/config.json"

# Hardcoded fallback defaults (overridden by config.json if present)
HETZNER_DEFAULT_PRODUCT="AX41-NVMe"
HETZNER_DEFAULT_LOCATION="FSN1"
HETZNER_DEFAULT_DIST="Ubuntu 24.04 LTS base"
HETZNER_API="https://robot-ws.your-server.de"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# Load cloud defaults from config.json if available
load_cloud_defaults() {
    if [ -f "$CONFIG_FILE" ]; then
        local VAL
        VAL=$(jq -r '.clouds.hetzner.default_product // empty' "$CONFIG_FILE" 2>/dev/null)
        [ -n "$VAL" ] && HETZNER_DEFAULT_PRODUCT="$VAL"
        VAL=$(jq -r '.clouds.hetzner.default_location // empty' "$CONFIG_FILE" 2>/dev/null)
        [ -n "$VAL" ] && HETZNER_DEFAULT_LOCATION="$VAL"
    fi
}

ensure_deployments_dir() {
    mkdir -p "$DEPLOYMENTS_DIR"
}

# ===========================================================================
#  Hetzner Robot API
# ===========================================================================

hetzner_prompt_credentials() {
    echo -e "${CYAN}Hetzner Robot API credentials${NC}"
    echo "Find these at https://robot.hetzner.com → Settings → Webservice"
    echo ""
    read -p "Username: " HETZNER_USER
    read -sp "Password: " HETZNER_PASS
    echo ""

    if [ -z "$HETZNER_USER" ] || [ -z "$HETZNER_PASS" ]; then
        echo -e "${RED}[ERROR]${NC} Both username and password are required"
        exit 1
    fi
}

hetzner_api() {
    local METHOD="$1"
    local ENDPOINT="$2"
    shift 2

    curl -s -u "$HETZNER_USER:$HETZNER_PASS" \
        -X "$METHOD" \
        "${HETZNER_API}${ENDPOINT}" \
        -H "Accept: application/json" \
        "$@"
}

hetzner_check_auth() {
    echo -n "Verifying credentials... "
    local RESPONSE
    RESPONSE=$(hetzner_api GET /server 2>&1)

    if echo "$RESPONSE" | jq -e '.error' >/dev/null 2>&1; then
        local ERROR_MSG
        ERROR_MSG=$(echo "$RESPONSE" | jq -r '.error.message // "Unknown error"')
        echo ""
        echo -e "${RED}[ERROR]${NC} Authentication failed: $ERROR_MSG"
        exit 1
    fi

    echo -e "${GREEN}OK${NC}"
}

hetzner_ensure_ssh_key() {
    local KEY_PATH="$1"
    local KEY_DATA
    KEY_DATA=$(cat "$KEY_PATH")

    # Compute MD5 fingerprint (Hetzner Robot uses colon-separated MD5)
    local KEY_FINGERPRINT
    KEY_FINGERPRINT=$(ssh-keygen -lf "$KEY_PATH" -E md5 2>/dev/null \
        | awk '{print $2}' | sed 's/MD5://')

    # Check if key already registered
    local EXISTING_KEYS
    EXISTING_KEYS=$(hetzner_api GET /key)

    if echo "$EXISTING_KEYS" | jq -e \
        --arg fp "$KEY_FINGERPRINT" \
        '.[] | select(.key.fingerprint == $fp)' >/dev/null 2>&1; then
        echo -e "${YELLOW}[SKIP]${NC} SSH key already registered in Hetzner Robot"
        echo "$KEY_FINGERPRINT"
        return 0
    fi

    # Upload the key
    local KEY_NAME="hive-$(hostname)-$(date +%s)"
    local RESPONSE
    RESPONSE=$(hetzner_api POST /key \
        -d "name=$KEY_NAME" \
        --data-urlencode "data=$KEY_DATA")

    if echo "$RESPONSE" | jq -e '.error' >/dev/null 2>&1; then
        local ERROR_MSG
        ERROR_MSG=$(echo "$RESPONSE" | jq -r '.error.message // "Unknown error"')
        echo -e "${RED}[ERROR]${NC} Failed to upload SSH key: $ERROR_MSG"
        exit 1
    fi

    KEY_FINGERPRINT=$(echo "$RESPONSE" | jq -r '.key.fingerprint')
    echo -e "${GREEN}[OK]${NC} SSH key uploaded (fingerprint: $KEY_FINGERPRINT)"
    echo "$KEY_FINGERPRINT"
}

hetzner_order_server() {
    local PRODUCT="$1"
    local LOCATION="$2"
    local DIST="$3"
    local KEY_FINGERPRINT="$4"

    echo -e "${BLUE}Ordering $PRODUCT at $LOCATION...${NC}"

    local RESPONSE
    RESPONSE=$(hetzner_api POST /order/server/transaction \
        -d "product_id=$PRODUCT" \
        --data-urlencode "authorized_key[]=$KEY_FINGERPRINT" \
        --data-urlencode "dist=$DIST" \
        -d "arch=64" \
        -d "lang=en" \
        -d "location=$LOCATION")

    if echo "$RESPONSE" | jq -e '.error' >/dev/null 2>&1; then
        local ERROR_CODE ERROR_MSG
        ERROR_CODE=$(echo "$RESPONSE" | jq -r '.error.code // "unknown"')
        ERROR_MSG=$(echo "$RESPONSE" | jq -r '.error.message // "Unknown error"')
        echo -e "${RED}[ERROR]${NC} Order failed ($ERROR_CODE): $ERROR_MSG"

        if [ "$ERROR_CODE" = "SERVER_NOT_AVAILABLE" ]; then
            echo ""
            echo "The product '$PRODUCT' is not currently available at '$LOCATION'."
            echo "Try a different location with --location or check:"
            echo "  https://www.hetzner.com/dedicated-rootserver"
        fi
        exit 1
    fi

    # Extract transaction ID — this is the stable handle for polling.
    # server_number and server_ip start as null and get populated when ready.
    local TXN_ID SERVER_NUMBER SERVER_IP
    TXN_ID=$(echo "$RESPONSE" | jq -r '.transaction.id // empty')
    SERVER_NUMBER=$(echo "$RESPONSE" | jq -r '.transaction.server_number // empty')
    SERVER_IP=$(echo "$RESPONSE" | jq -r '.transaction.server_ip // empty')

    if [ -z "$TXN_ID" ]; then
        echo -e "${YELLOW}[WARN]${NC} Could not extract transaction ID from response."
        echo "Raw response:"
        echo "$RESPONSE" | jq . 2>/dev/null || echo "$RESPONSE"
        echo ""
        echo "The order may have been placed. Check https://robot.hetzner.com"
        exit 1
    fi

    echo -e "${GREEN}[OK]${NC} Order placed (transaction: $TXN_ID)"
    [ -n "$SERVER_NUMBER" ] && [ "$SERVER_NUMBER" != "null" ] && echo "  Server number: $SERVER_NUMBER"
    [ -n "$SERVER_IP" ] && [ "$SERVER_IP" != "null" ] && echo "  IP: $SERVER_IP"

    # Return transaction_id, server_number, server_ip
    echo "RESULT $TXN_ID $SERVER_NUMBER $SERVER_IP"
}

hetzner_get_transaction() {
    local TXN_ID="$1"
    hetzner_api GET "/order/server/transaction/$TXN_ID"
}

hetzner_parse_transaction() {
    local TXN_DATA="$1"
    local FIELD="$2"
    echo "$TXN_DATA" | jq -r ".transaction.$FIELD // empty"
}

# ===========================================================================
#  Deployment state management
# ===========================================================================

save_deployment() {
    local NAME="$1"
    local CLOUD="$2"
    local STATUS="$3"
    local PRODUCT="$4"
    local LOCATION="$5"
    local SSH_KEY_PATH="$6"
    local TXN_ID="$7"
    local SERVER_NUMBER="${8:-}"
    local SERVER_IP="${9:-}"

    ensure_deployments_dir

    local DEPLOY_FILE="$DEPLOYMENTS_DIR/$NAME.json"

    jq -n \
        --arg name "$NAME" \
        --arg cloud "$CLOUD" \
        --arg status "$STATUS" \
        --arg product "$PRODUCT" \
        --arg location "$LOCATION" \
        --arg ssh_key_path "$SSH_KEY_PATH" \
        --arg transaction_id "$TXN_ID" \
        --arg server_number "$SERVER_NUMBER" \
        --arg server_ip "$SERVER_IP" \
        --arg ordered_at "$(date -Iseconds)" \
        '{
            name: $name,
            cloud: $cloud,
            status: $status,
            product: $product,
            location: $location,
            ssh_key_path: $ssh_key_path,
            transaction_id: $transaction_id,
            server_number: (if $server_number == "" then null else $server_number end),
            server_ip: (if $server_ip == "" then null else $server_ip end),
            ordered_at: $ordered_at
        }' > "$DEPLOY_FILE"
}

update_deployment() {
    local NAME="$1"
    local FIELD="$2"
    local VALUE="$3"

    local DEPLOY_FILE="$DEPLOYMENTS_DIR/$NAME.json"
    jq --arg field "$FIELD" --arg value "$VALUE" '.[$field] = $value' \
        "$DEPLOY_FILE" > "$DEPLOY_FILE.tmp"
    mv "$DEPLOY_FILE.tmp" "$DEPLOY_FILE"
}

load_deployment() {
    local NAME="$1"
    local DEPLOY_FILE="$DEPLOYMENTS_DIR/$NAME.json"

    if [ ! -f "$DEPLOY_FILE" ]; then
        echo -e "${RED}[ERROR]${NC} No deployment found for '$NAME'"
        echo "Start a new deployment with: hive worker deploy --at <cloud> --name $NAME"
        exit 1
    fi

    cat "$DEPLOY_FILE"
}

# ===========================================================================
#  Worker setup bridge
# ===========================================================================

wait_for_ssh() {
    local SERVER_IP="$1"
    local MAX_ATTEMPTS="${2:-30}"

    echo "Waiting for SSH to become available at root@$SERVER_IP..."
    for i in $(seq 1 "$MAX_ATTEMPTS"); do
        if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o BatchMode=yes \
            "root@$SERVER_IP" true 2>/dev/null; then
            echo -e "${GREEN}[OK]${NC} SSH is up"
            return 0
        fi
        printf "\r  Attempt %d/%d..." "$i" "$MAX_ATTEMPTS"
        sleep 10
    done

    echo ""
    return 1
}

start_worker_setup() {
    local NAME="$1"
    local SERVER_IP="$2"

    echo ""
    echo -e "${CYAN}Starting worker setup on $SERVER_IP...${NC}"
    echo ""

    update_deployment "$NAME" "status" "setup_started"

    # Chain into the existing worker setup flow
    bash "$HIVE_TOOLS/hive/worker.sh" setup "root@$SERVER_IP" --name "$NAME"

    update_deployment "$NAME" "status" "setup_complete"
}

# ===========================================================================
#  Deploy flows
# ===========================================================================

deploy_new() {
    local CLOUD="$1"
    local NAME="$2"
    local SSH_KEY_PATH="$3"
    local PRODUCT="$4"
    local LOCATION="$5"

    case "$CLOUD" in
        hetzner)
            PRODUCT="${PRODUCT:-$HETZNER_DEFAULT_PRODUCT}"
            LOCATION="${LOCATION:-$HETZNER_DEFAULT_LOCATION}"
            local DIST="$HETZNER_DEFAULT_DIST"

            echo -e "${CYAN}"
            echo "========================================"
            echo "  Hive Worker Deploy: $NAME"
            echo "========================================"
            echo -e "${NC}"
            echo "  Cloud:     Hetzner (dedicated)"
            echo "  Product:   $PRODUCT"
            echo "  Location:  $LOCATION"
            echo "  OS:        $DIST"
            echo "  SSH Key:   $SSH_KEY_PATH"
            echo ""

            # Check for existing deployment
            if [ -f "$DEPLOYMENTS_DIR/$NAME.json" ]; then
                echo -e "${YELLOW}[WARN]${NC} A deployment for '$NAME' already exists."
                echo "Use 'hive worker deploy --continue $NAME' to resume it,"
                echo "or remove it first: rm $DEPLOYMENTS_DIR/$NAME.json"
                exit 1
            fi

            read -p "This will order a dedicated server. Continue? (y/N): " confirm
            if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
                echo "Cancelled."
                exit 0
            fi

            echo ""
            hetzner_prompt_credentials
            hetzner_check_auth

            echo ""
            echo -e "${BLUE}[1/4]${NC} Registering SSH key..."
            local KEY_FP_OUTPUT KEY_FINGERPRINT
            KEY_FP_OUTPUT=$(hetzner_ensure_ssh_key "$SSH_KEY_PATH")
            KEY_FINGERPRINT=$(echo "$KEY_FP_OUTPUT" | tail -1)

            echo -e "${BLUE}[2/4]${NC} Placing server order..."
            local ORDER_OUTPUT TXN_ID SERVER_NUMBER SERVER_IP
            ORDER_OUTPUT=$(hetzner_order_server "$PRODUCT" "$LOCATION" "$DIST" "$KEY_FINGERPRINT")
            # Parse the RESULT line: "RESULT <txn_id> <server_number> <server_ip>"
            local RESULT_LINE
            RESULT_LINE=$(echo "$ORDER_OUTPUT" | grep "^RESULT " | tail -1)
            TXN_ID=$(echo "$RESULT_LINE" | awk '{print $2}')
            SERVER_NUMBER=$(echo "$RESULT_LINE" | awk '{print $3}')
            SERVER_IP=$(echo "$RESULT_LINE" | awk '{print $4}')
            # Print non-RESULT lines (status messages)
            echo "$ORDER_OUTPUT" | grep -v "^RESULT "

            echo -e "${BLUE}[3/4]${NC} Saving deployment state..."
            save_deployment "$NAME" "hetzner" "provisioning" \
                "$PRODUCT" "$LOCATION" "$SSH_KEY_PATH" "$TXN_ID" "$SERVER_NUMBER" "$SERVER_IP"
            echo -e "${GREEN}[OK]${NC} Saved to $DEPLOYMENTS_DIR/$NAME.json"

            echo -e "${BLUE}[4/4]${NC} Waiting for server provisioning..."
            echo ""
            echo "Dedicated server provisioning typically takes 15-60 minutes."
            echo "Polling transaction status (Ctrl+C to stop — resume with --continue)..."
            echo ""

            # If we already have an IP from the order response, try SSH directly
            if [ -n "$SERVER_IP" ] && [ "$SERVER_IP" != "null" ] && [ "$SERVER_IP" != "" ]; then
                update_deployment "$NAME" "server_ip" "$SERVER_IP"
                update_deployment "$NAME" "status" "ready"

                if wait_for_ssh "$SERVER_IP" 30; then
                    start_worker_setup "$NAME" "$SERVER_IP"
                    return 0
                fi

                echo -e "${YELLOW}[INFO]${NC} SSH not reachable yet."
                echo "Continue later: hive worker deploy --continue $NAME"
                return 0
            fi

            # Poll the transaction endpoint (60 attempts × 60s = ~60 minutes)
            local MAX_ATTEMPTS=60
            local POLL_INTERVAL=60

            for ATTEMPT in $(seq 1 $MAX_ATTEMPTS); do
                local TXN_DATA
                TXN_DATA=$(hetzner_get_transaction "$TXN_ID" 2>/dev/null) || true

                local TXN_STATUS
                TXN_STATUS=$(hetzner_parse_transaction "$TXN_DATA" "status" 2>/dev/null) || true
                SERVER_IP=$(hetzner_parse_transaction "$TXN_DATA" "server_ip" 2>/dev/null) || true
                SERVER_NUMBER=$(hetzner_parse_transaction "$TXN_DATA" "server_number" 2>/dev/null) || true

                if [ "$TXN_STATUS" = "ready" ] && [ -n "$SERVER_IP" ] && [ "$SERVER_IP" != "null" ]; then
                    echo ""
                    echo -e "${GREEN}[OK]${NC} Server is ready! (IP: $SERVER_IP)"
                    update_deployment "$NAME" "server_ip" "$SERVER_IP"
                    [ -n "$SERVER_NUMBER" ] && [ "$SERVER_NUMBER" != "null" ] && \
                        update_deployment "$NAME" "server_number" "$SERVER_NUMBER"
                    update_deployment "$NAME" "status" "ready"

                    if wait_for_ssh "$SERVER_IP" 30; then
                        start_worker_setup "$NAME" "$SERVER_IP"
                        return 0
                    fi

                    echo -e "${YELLOW}[INFO]${NC} SSH not reachable yet."
                    echo "Continue later: hive worker deploy --continue $NAME"
                    return 0
                fi

                printf "\r  [%d/%d] Status: %-12s (next check in %ds)  " \
                    "$ATTEMPT" "$MAX_ATTEMPTS" "${TXN_STATUS:-pending}" "$POLL_INTERVAL"
                sleep "$POLL_INTERVAL"
            done

            echo ""
            echo -e "${YELLOW}[INFO]${NC} Still provisioning after $MAX_ATTEMPTS minutes."
            echo "Continue later: hive worker deploy --continue $NAME"
            ;;
        *)
            echo -e "${RED}[ERROR]${NC} Unsupported cloud provider: $CLOUD"
            echo "Supported providers: hetzner"
            exit 1
            ;;
    esac
}

deploy_continue() {
    local NAME="$1"

    local DEPLOY_DATA
    DEPLOY_DATA=$(load_deployment "$NAME")

    local CLOUD STATUS TXN_ID SERVER_NUMBER SERVER_IP SSH_KEY_PATH PRODUCT LOCATION
    CLOUD=$(echo "$DEPLOY_DATA" | jq -r '.cloud')
    STATUS=$(echo "$DEPLOY_DATA" | jq -r '.status')
    TXN_ID=$(echo "$DEPLOY_DATA" | jq -r '.transaction_id')
    SERVER_NUMBER=$(echo "$DEPLOY_DATA" | jq -r '.server_number // empty')
    SERVER_IP=$(echo "$DEPLOY_DATA" | jq -r '.server_ip // empty')
    SSH_KEY_PATH=$(echo "$DEPLOY_DATA" | jq -r '.ssh_key_path')
    PRODUCT=$(echo "$DEPLOY_DATA" | jq -r '.product')
    LOCATION=$(echo "$DEPLOY_DATA" | jq -r '.location')

    echo -e "${CYAN}"
    echo "========================================"
    echo "  Continue Deploy: $NAME"
    echo "========================================"
    echo -e "${NC}"
    echo "  Cloud:          $CLOUD"
    echo "  Product:        $PRODUCT"
    echo "  Location:       $LOCATION"
    echo "  Transaction:    $TXN_ID"
    echo "  Server IP:      ${SERVER_IP:-not yet assigned}"
    echo "  Status:         $STATUS"
    echo ""

    case "$STATUS" in
        setup_complete)
            echo -e "${GREEN}[OK]${NC} This deployment is already complete."
            echo "Worker '$NAME' should be registered. Check with: hive worker ls"
            return 0
            ;;
        setup_started)
            echo -e "${YELLOW}[INFO]${NC} Setup was previously started but may not have finished."
            echo "Will re-run worker setup."
            ;;
    esac

    case "$CLOUD" in
        hetzner)
            hetzner_prompt_credentials
            hetzner_check_auth

            # If we don't have an IP yet, poll the transaction
            if [ -z "$SERVER_IP" ] || [ "$SERVER_IP" = "null" ]; then
                echo ""
                echo "Checking transaction status..."
                local TXN_DATA
                TXN_DATA=$(hetzner_get_transaction "$TXN_ID")

                local TXN_STATUS
                TXN_STATUS=$(hetzner_parse_transaction "$TXN_DATA" "status")
                SERVER_IP=$(hetzner_parse_transaction "$TXN_DATA" "server_ip")
                SERVER_NUMBER=$(hetzner_parse_transaction "$TXN_DATA" "server_number")

                if [ -z "$SERVER_IP" ] || [ "$SERVER_IP" = "null" ]; then
                    echo -e "${YELLOW}[INFO]${NC} Server not ready yet (status: ${TXN_STATUS:-unknown})"
                    echo "Try again later: hive worker deploy --continue $NAME"
                    return 0
                fi

                echo -e "${GREEN}[OK]${NC} Server is ready! (IP: $SERVER_IP)"
                update_deployment "$NAME" "server_ip" "$SERVER_IP"
                [ -n "$SERVER_NUMBER" ] && [ "$SERVER_NUMBER" != "null" ] && \
                    update_deployment "$NAME" "server_number" "$SERVER_NUMBER"
                update_deployment "$NAME" "status" "ready"
            fi

            # Check SSH connectivity
            echo "Checking SSH connectivity..."
            if ! wait_for_ssh "$SERVER_IP" 6; then
                echo -e "${YELLOW}[WARN]${NC} SSH not reachable at root@$SERVER_IP"
                echo "The server may still be installing the OS."
                echo "Try again later: hive worker deploy --continue $NAME"
                return 0
            fi

            start_worker_setup "$NAME" "$SERVER_IP"
            ;;
        *)
            echo -e "${RED}[ERROR]${NC} Unknown cloud provider: $CLOUD"
            exit 1
            ;;
    esac
}

# ===========================================================================
#  CLI entry point
# ===========================================================================

show_deploy_help() {
    cat <<EOF
Usage: hive worker deploy --at <cloud> --name <name> [options]
       hive worker deploy --continue <name>

Deploy a dedicated server and set it up as a hive worker.

Options:
  --at <cloud>        Cloud provider (currently: hetzner)
  --name <name>       Worker name (required)
  --ssh-key <path>    SSH public key path (default: auto-detect from ~/.ssh/)
  --product <type>    Server product (default: AX41-NVMe for Hetzner)
  --location <loc>    Datacenter location (default: FSN1 for Hetzner)
  --continue <name>   Resume a previous deployment

Hetzner (dedicated servers via Robot API):
  Credentials (username + password) are prompted each time.
  Default product: AX41-NVMe
  Default location: FSN1 (Falkenstein)
  Available locations: FSN1 (Falkenstein), NBG1 (Nuremberg), HEL1 (Helsinki)
  OS: Ubuntu 24.04 LTS

Deployment state is saved to $DEPLOYMENTS_DIR/<name>.json
EOF
}

main() {
    local CLOUD=""
    local NAME=""
    local SSH_KEY_PATH=""
    local PRODUCT=""
    local LOCATION=""
    local CONTINUE_NAME=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            --at) CLOUD="$2"; shift 2 ;;
            --name) NAME="$2"; shift 2 ;;
            --ssh-key) SSH_KEY_PATH="$2"; shift 2 ;;
            --product) PRODUCT="$2"; shift 2 ;;
            --location) LOCATION="$2"; shift 2 ;;
            --continue) CONTINUE_NAME="$2"; shift 2 ;;
            --help|-h) show_deploy_help; exit 0 ;;
            -*) echo -e "${RED}Unknown option: $1${NC}"; exit 1 ;;
            *) echo -e "${RED}Unexpected argument: $1${NC}"; exit 1 ;;
        esac
    done

    load_cloud_defaults

    # Continue mode
    if [ -n "$CONTINUE_NAME" ]; then
        deploy_continue "$CONTINUE_NAME"
        return 0
    fi

    # New deployment mode — validate required args
    if [ -z "$CLOUD" ]; then
        echo -e "${RED}[ERROR]${NC} --at <cloud> is required"
        echo "Usage: hive worker deploy --at <cloud> --name <name>"
        echo "Run 'hive worker deploy --help' for details"
        exit 1
    fi

    if [ -z "$NAME" ]; then
        echo -e "${RED}[ERROR]${NC} --name is required"
        echo "Usage: hive worker deploy --at $CLOUD --name <name>"
        exit 1
    fi

    # Auto-detect SSH key
    if [ -z "$SSH_KEY_PATH" ]; then
        for key in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub ~/.ssh/id_ecdsa.pub; do
            if [ -f "$key" ]; then
                SSH_KEY_PATH="$key"
                break
            fi
        done

        if [ -z "$SSH_KEY_PATH" ]; then
            echo -e "${RED}[ERROR]${NC} No SSH public key found in ~/.ssh/"
            echo "Provide one with --ssh-key <path> or generate with:"
            echo "  ssh-keygen -t ed25519"
            exit 1
        fi

        echo -e "${BLUE}[INFO]${NC} Using SSH key: $SSH_KEY_PATH"
    fi

    if [ ! -f "$SSH_KEY_PATH" ]; then
        echo -e "${RED}[ERROR]${NC} SSH key not found: $SSH_KEY_PATH"
        exit 1
    fi

    deploy_new "$CLOUD" "$NAME" "$SSH_KEY_PATH" "$PRODUCT" "$LOCATION"
}

main "$@"
