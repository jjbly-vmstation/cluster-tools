#!/usr/bin/env bash
# quick-deploy.sh - Quick deployment tool for VMStation
# Streamlined deployment of applications and configurations
#
# Usage: ./quick-deploy.sh [OPTIONS] <target>
#
# Options:
#   -e, --env          Environment (dev, staging, prod)
#   -n, --dry-run      Show what would be done without making changes
#   -f, --force        Skip confirmation prompts
#   -v, --verbose      Enable verbose output
#   -h, --help         Show this help message

set -euo pipefail

# Get script directory and source common libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common-functions.sh
source "${SCRIPT_DIR}/../lib/common-functions.sh"

# Default configuration
ENVIRONMENT="${ENVIRONMENT:-dev}"
DRY_RUN="${DRY_RUN:-false}"
FORCE="${FORCE:-false}"
TARGET=""

# Deployment targets
declare -A DEPLOY_TARGETS=(
    ["monitoring"]="Deploy monitoring stack (Prometheus, Grafana, Loki)"
    ["logging"]="Deploy logging stack (Loki, Promtail)"
    ["ingress"]="Deploy ingress controller"
    ["storage"]="Deploy storage class and CSI drivers"
    ["all"]="Deploy all components"
)

#######################################
# Show help message
#######################################
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS] <target>

Quick deployment of VMStation components.

Targets:
$(for target in "${!DEPLOY_TARGETS[@]}"; do
    printf "  %-15s %s\n" "$target" "${DEPLOY_TARGETS[$target]}"
done)

Options:
  -e, --env ENV      Environment: dev, staging, prod (default: dev)
  -n, --dry-run      Show what would be done without making changes
  -f, --force        Skip confirmation prompts
  -v, --verbose      Enable verbose output
  -h, --help         Show this help message

Examples:
  $(basename "$0") monitoring           # Deploy monitoring to dev
  $(basename "$0") -e prod monitoring   # Deploy monitoring to prod
  $(basename "$0") --dry-run all        # Preview full deployment

Environment Variables:
  ENVIRONMENT        Default environment
  KUBECONFIG         Path to kubeconfig file
  HELM_NAMESPACE     Default Helm namespace
EOF
}

#######################################
# Parse command line arguments
#######################################
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -e|--env)
                ENVIRONMENT="${2:?Environment required}"
                shift 2
                ;;
            -n|--dry-run)
                DRY_RUN="true"
                shift
                ;;
            -f|--force)
                FORCE="true"
                shift
                ;;
            -v|--verbose)
                export LOG_LEVEL="DEBUG"
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            -*)
                log_error "Unknown option: $1"
                show_help
                exit 2
                ;;
            *)
                if [[ -z "$TARGET" ]]; then
                    TARGET="$1"
                else
                    log_error "Unexpected argument: $1"
                    show_help
                    exit 2
                fi
                shift
                ;;
        esac
    done
    
    if [[ -z "$TARGET" ]]; then
        log_error "Deployment target required"
        show_help
        exit 2
    fi
    
    # Validate target
    if [[ -z "${DEPLOY_TARGETS[$TARGET]:-}" ]]; then
        log_error "Unknown target: $TARGET"
        log_info "Valid targets: ${!DEPLOY_TARGETS[*]}"
        exit 2
    fi
    
    # Validate environment
    case "$ENVIRONMENT" in
        dev|staging|prod) ;;
        *)
            log_error "Invalid environment: $ENVIRONMENT"
            log_info "Valid environments: dev, staging, prod"
            exit 2
            ;;
    esac
}

#######################################
# Pre-deployment checks
#######################################
pre_deploy_checks() {
    log_subsection "Pre-Deployment Checks"
    
    # Check required tools
    require_command kubectl
    require_command helm
    
    # Check cluster connectivity
    if ! kubectl_ready; then
        log_error "Cannot connect to Kubernetes cluster"
        exit 2
    fi
    log_success "Cluster connection verified"
    
    # Get cluster info
    local context
    context=$(kubectl config current-context 2>/dev/null || echo "unknown")
    log_kv "Context" "$context"
    log_kv "Environment" "$ENVIRONMENT"
    log_kv "Target" "$TARGET"
    
    # Production safety check
    if [[ "$ENVIRONMENT" == "prod" ]] && [[ "$FORCE" != "true" ]]; then
        log_warn "Deploying to PRODUCTION environment"
        if ! confirm "Are you sure you want to continue?"; then
            log_info "Deployment cancelled"
            exit 0
        fi
    fi
}

#######################################
# Deploy monitoring stack
#######################################
deploy_monitoring() {
    log_subsection "Deploying Monitoring Stack"
    
    local namespace="monitoring"
    
    # Create namespace if needed
    run_cmd kubectl create namespace "$namespace" --dry-run=client -o yaml | \
        run_cmd kubectl apply -f -
    
    # Add Helm repositories
    log_info "Adding Helm repositories..."
    run_cmd helm repo add prometheus-community https://prometheus-community.github.io/helm-charts || true
    run_cmd helm repo add grafana https://grafana.github.io/helm-charts || true
    run_cmd helm repo update
    
    # Deploy Prometheus
    log_info "Deploying Prometheus..."
    local helm_args=(
        "upgrade" "--install"
        "prometheus" "prometheus-community/prometheus"
        "--namespace" "$namespace"
        "--set" "server.persistentVolume.enabled=false"
    )
    
    if [[ "$DRY_RUN" == "true" ]]; then
        helm_args+=("--dry-run")
    fi
    
    run_cmd helm "${helm_args[@]}"
    
    # Deploy Grafana
    log_info "Deploying Grafana..."
    helm_args=(
        "upgrade" "--install"
        "grafana" "grafana/grafana"
        "--namespace" "$namespace"
        "--set" "persistence.enabled=false"
        "--set" "adminPassword=admin"
    )
    
    if [[ "$DRY_RUN" == "true" ]]; then
        helm_args+=("--dry-run")
    fi
    
    run_cmd helm "${helm_args[@]}"
    
    log_success "Monitoring stack deployment initiated"
}

#######################################
# Deploy logging stack
#######################################
deploy_logging() {
    log_subsection "Deploying Logging Stack"
    
    local namespace="logging"
    
    # Create namespace if needed
    run_cmd kubectl create namespace "$namespace" --dry-run=client -o yaml | \
        run_cmd kubectl apply -f -
    
    # Add Helm repository
    log_info "Adding Grafana Helm repository..."
    run_cmd helm repo add grafana https://grafana.github.io/helm-charts || true
    run_cmd helm repo update
    
    # Deploy Loki
    log_info "Deploying Loki..."
    local helm_args=(
        "upgrade" "--install"
        "loki" "grafana/loki-stack"
        "--namespace" "$namespace"
        "--set" "promtail.enabled=true"
        "--set" "grafana.enabled=false"
    )
    
    if [[ "$DRY_RUN" == "true" ]]; then
        helm_args+=("--dry-run")
    fi
    
    run_cmd helm "${helm_args[@]}"
    
    log_success "Logging stack deployment initiated"
}

#######################################
# Deploy ingress controller
#######################################
deploy_ingress() {
    log_subsection "Deploying Ingress Controller"
    
    local namespace="ingress-nginx"
    
    # Create namespace if needed
    run_cmd kubectl create namespace "$namespace" --dry-run=client -o yaml | \
        run_cmd kubectl apply -f -
    
    # Add Helm repository
    log_info "Adding ingress-nginx Helm repository..."
    run_cmd helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx || true
    run_cmd helm repo update
    
    # Deploy ingress-nginx
    log_info "Deploying ingress-nginx..."
    local helm_args=(
        "upgrade" "--install"
        "ingress-nginx" "ingress-nginx/ingress-nginx"
        "--namespace" "$namespace"
    )
    
    if [[ "$DRY_RUN" == "true" ]]; then
        helm_args+=("--dry-run")
    fi
    
    run_cmd helm "${helm_args[@]}"
    
    log_success "Ingress controller deployment initiated"
}

#######################################
# Deploy storage components
#######################################
deploy_storage() {
    log_subsection "Deploying Storage Components"
    
    log_info "Setting up storage class..."
    
    # Create a simple local-path storage class
    local storage_class='
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: local-path
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: rancher.io/local-path
volumeBindingMode: WaitForFirstConsumer
'
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Would create local-path storage class"
    else
        echo "$storage_class" | run_cmd kubectl apply -f -
    fi
    
    log_success "Storage components deployment initiated"
}

#######################################
# Deploy all components
#######################################
deploy_all() {
    deploy_monitoring
    deploy_logging
    deploy_ingress
    deploy_storage
}

#######################################
# Post-deployment verification
#######################################
post_deploy_verify() {
    log_subsection "Post-Deployment Verification"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[DRY-RUN] Skipping verification"
        return 0
    fi
    
    log_info "Waiting for deployments to stabilize..."
    sleep 10
    
    # Check deployments
    case "$TARGET" in
        monitoring)
            kubectl get pods -n monitoring --no-headers 2>/dev/null || true
            ;;
        logging)
            kubectl get pods -n logging --no-headers 2>/dev/null || true
            ;;
        ingress)
            kubectl get pods -n ingress-nginx --no-headers 2>/dev/null || true
            ;;
        storage)
            kubectl get sc 2>/dev/null || true
            ;;
        all)
            log_info "Monitoring pods:"
            kubectl get pods -n monitoring --no-headers 2>/dev/null || true
            log_info "Logging pods:"
            kubectl get pods -n logging --no-headers 2>/dev/null || true
            log_info "Ingress pods:"
            kubectl get pods -n ingress-nginx --no-headers 2>/dev/null || true
            ;;
    esac
}

#######################################
# Main function
#######################################
main() {
    parse_args "$@"
    
    log_section "Quick Deploy"
    log_kv "Target" "$TARGET"
    log_kv "Environment" "$ENVIRONMENT"
    log_kv "Mode" "$([[ "$DRY_RUN" == "true" ]] && echo "Dry-Run" || echo "Live")"
    
    # Pre-deployment checks
    pre_deploy_checks
    
    # Deploy based on target
    case "$TARGET" in
        monitoring)
            deploy_monitoring
            ;;
        logging)
            deploy_logging
            ;;
        ingress)
            deploy_ingress
            ;;
        storage)
            deploy_storage
            ;;
        all)
            deploy_all
            ;;
    esac
    
    # Post-deployment
    post_deploy_verify
    
    log_section "Deployment Complete"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "This was a dry-run. No changes were made."
    else
        log_success "Deployment of '$TARGET' to '$ENVIRONMENT' completed successfully"
    fi
}

main "$@"
