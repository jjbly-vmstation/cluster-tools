#!/usr/bin/env bash
# deployment-helpers.sh - Helper functions for deployments
# Provides utility functions for deployment operations
#
# Usage: source deployment-helpers.sh

# Prevent multiple sourcing
[[ -n "${_DEPLOYMENT_HELPERS_LOADED:-}" ]] && return 0
readonly _DEPLOYMENT_HELPERS_LOADED=1

# Get script directory and source common libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common-functions.sh
source "${SCRIPT_DIR}/../lib/common-functions.sh"

#######################################
# Wait for deployment to be ready
# Arguments:
#   $1 - Deployment name
#   $2 - Namespace
#   $3 - Timeout in seconds (default: 300)
# Returns:
#   0 if ready, 1 if timeout
#######################################
wait_for_deployment() {
    local deployment="${1:?Deployment name required}"
    local namespace="${2:?Namespace required}"
    local timeout="${3:-300}"

    log_info "Waiting for deployment $deployment in $namespace..."

    if kubectl rollout status deployment/"$deployment" -n "$namespace" --timeout="${timeout}s" 2>/dev/null; then
        log_success "Deployment $deployment is ready"
        return 0
    else
        log_error "Deployment $deployment did not become ready within ${timeout}s"
        return 1
    fi
}

#######################################
# Wait for all pods in namespace to be ready
# Arguments:
#   $1 - Namespace
#   $2 - Timeout in seconds (default: 300)
# Returns:
#   0 if all ready, 1 if timeout
#######################################
wait_for_namespace_ready() {
    local namespace="${1:?Namespace required}"
    local timeout="${2:-300}"

    log_info "Waiting for all pods in namespace $namespace..."

    local start_time
    start_time=$(date +%s)

    while true; do
        local current_time
        current_time=$(date +%s)
        local elapsed=$((current_time - start_time))

        if [[ $elapsed -ge $timeout ]]; then
            log_error "Timeout waiting for pods in $namespace"
            return 1
        fi

        local not_ready
        not_ready=$(kubectl get pods -n "$namespace" --no-headers 2>/dev/null | \
            grep -v "Running\|Completed\|Succeeded" | wc -l)

        if [[ $not_ready -eq 0 ]]; then
            log_success "All pods in $namespace are ready"
            return 0
        fi

        log_debug "$not_ready pod(s) still not ready..."
        sleep 5
    done
}

#######################################
# Apply Kubernetes manifests with retries
# Arguments:
#   $1 - Path to manifest file or directory
#   $2 - Number of retries (default: 3)
# Returns:
#   0 on success, 1 on failure
#######################################
apply_with_retry() {
    local path="${1:?Path required}"
    local retries="${2:-3}"

    local attempt=1
    while [[ $attempt -le $retries ]]; do
        log_debug "Applying $path (attempt $attempt/$retries)"

        if kubectl apply -f "$path" 2>&1; then
            log_success "Applied $path"
            return 0
        fi

        if [[ $attempt -lt $retries ]]; then
            log_warn "Failed to apply, retrying in 5s..."
            sleep 5
        fi

        ((attempt++))
    done

    log_error "Failed to apply $path after $retries attempts"
    return 1
}

#######################################
# Create namespace if it doesn't exist
# Arguments:
#   $1 - Namespace name
#   $2 - Optional labels (key=value,key2=value2)
#######################################
ensure_namespace() {
    local namespace="${1:?Namespace required}"
    local labels="${2:-}"

    if kubectl get namespace "$namespace" >/dev/null 2>&1; then
        log_debug "Namespace $namespace already exists"
        return 0
    fi

    log_info "Creating namespace $namespace"

    if [[ -n "$labels" ]]; then
        # shellcheck disable=SC2086
        kubectl create namespace "$namespace" --dry-run=client -o yaml | \
            kubectl label --dry-run=client -o yaml -f - $labels | \
            kubectl apply -f -
    else
        kubectl create namespace "$namespace"
    fi

    log_success "Created namespace $namespace"
}

#######################################
# Check if Helm release exists
# Arguments:
#   $1 - Release name
#   $2 - Namespace
# Returns:
#   0 if exists, 1 otherwise
#######################################
helm_release_exists() {
    local release="${1:?Release name required}"
    local namespace="${2:?Namespace required}"

    helm status "$release" -n "$namespace" >/dev/null 2>&1
}

#######################################
# Get Helm release status
# Arguments:
#   $1 - Release name
#   $2 - Namespace
# Outputs:
#   Release status (deployed, failed, pending, etc.)
#######################################
get_helm_release_status() {
    local release="${1:?Release name required}"
    local namespace="${2:?Namespace required}"

    helm status "$release" -n "$namespace" -o json 2>/dev/null | \
        jq -r '.info.status' 2>/dev/null || echo "not-found"
}

#######################################
# Rollback Helm release
# Arguments:
#   $1 - Release name
#   $2 - Namespace
#   $3 - Revision (default: previous)
# Returns:
#   0 on success, 1 on failure
#######################################
rollback_helm_release() {
    local release="${1:?Release name required}"
    local namespace="${2:?Namespace required}"
    local revision="${3:-}"

    log_info "Rolling back Helm release $release in $namespace"

    if [[ -n "$revision" ]]; then
        helm rollback "$release" "$revision" -n "$namespace"
    else
        helm rollback "$release" -n "$namespace"
    fi
}

#######################################
# Get service URL
# Arguments:
#   $1 - Service name
#   $2 - Namespace
# Outputs:
#   Service URL
#######################################
get_service_url() {
    local service="${1:?Service name required}"
    local namespace="${2:?Namespace required}"

    local cluster_ip
    local port

    cluster_ip=$(kubectl get svc "$service" -n "$namespace" -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
    port=$(kubectl get svc "$service" -n "$namespace" -o jsonpath='{.spec.ports[0].port}' 2>/dev/null)

    if [[ -n "$cluster_ip" ]] && [[ -n "$port" ]]; then
        echo "http://${cluster_ip}:${port}"
    fi
}

#######################################
# Scale deployment
# Arguments:
#   $1 - Deployment name
#   $2 - Namespace
#   $3 - Replicas
#######################################
scale_deployment() {
    local deployment="${1:?Deployment name required}"
    local namespace="${2:?Namespace required}"
    local replicas="${3:?Replicas required}"

    log_info "Scaling $deployment to $replicas replicas"

    kubectl scale deployment "$deployment" -n "$namespace" --replicas="$replicas"

    log_success "Scaled $deployment to $replicas replicas"
}

#######################################
# Get deployment image
# Arguments:
#   $1 - Deployment name
#   $2 - Namespace
#   $3 - Container name (default: first container)
# Outputs:
#   Image name
#######################################
get_deployment_image() {
    local deployment="${1:?Deployment name required}"
    local namespace="${2:?Namespace required}"
    local container="${3:-}"

    if [[ -n "$container" ]]; then
        kubectl get deployment "$deployment" -n "$namespace" \
            -o jsonpath="{.spec.template.spec.containers[?(@.name=='$container')].image}" 2>/dev/null
    else
        kubectl get deployment "$deployment" -n "$namespace" \
            -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null
    fi
}

#######################################
# Update deployment image
# Arguments:
#   $1 - Deployment name
#   $2 - Namespace
#   $3 - Container name
#   $4 - New image
#######################################
update_deployment_image() {
    local deployment="${1:?Deployment name required}"
    local namespace="${2:?Namespace required}"
    local container="${3:?Container name required}"
    local image="${4:?Image required}"

    log_info "Updating $deployment container $container to $image"

    kubectl set image deployment/"$deployment" "$container=$image" -n "$namespace"

    log_success "Updated image for $deployment"
}

#######################################
# Check if resource exists
# Arguments:
#   $1 - Resource type
#   $2 - Resource name
#   $3 - Namespace (optional)
# Returns:
#   0 if exists, 1 otherwise
#######################################
resource_exists() {
    local resource_type="${1:?Resource type required}"
    local resource_name="${2:?Resource name required}"
    local namespace="${3:-}"

    if [[ -n "$namespace" ]]; then
        kubectl get "$resource_type" "$resource_name" -n "$namespace" >/dev/null 2>&1
    else
        kubectl get "$resource_type" "$resource_name" >/dev/null 2>&1
    fi
}

#######################################
# Get pod logs from a deployment
# Arguments:
#   $1 - Deployment name
#   $2 - Namespace
#   $3 - Tail lines (default: 100)
# Outputs:
#   Pod logs
#######################################
get_deployment_logs() {
    local deployment="${1:?Deployment name required}"
    local namespace="${2:?Namespace required}"
    local tail_lines="${3:-100}"

    kubectl logs -n "$namespace" -l "app=$deployment" --tail="$tail_lines" --all-containers 2>/dev/null || \
        kubectl logs -n "$namespace" deployment/"$deployment" --tail="$tail_lines" --all-containers 2>/dev/null
}

#######################################
# Port forward to a service
# Arguments:
#   $1 - Service name
#   $2 - Namespace
#   $3 - Local port
#   $4 - Remote port
# Note: This starts a background process
#######################################
port_forward_service() {
    local service="${1:?Service name required}"
    local namespace="${2:?Namespace required}"
    local local_port="${3:?Local port required}"
    local remote_port="${4:?Remote port required}"

    log_info "Port forwarding $local_port -> $service:$remote_port"

    kubectl port-forward -n "$namespace" "svc/$service" "${local_port}:${remote_port}" &

    local pid=$!
    log_info "Port forward started (PID: $pid)"
    echo "$pid"
}
