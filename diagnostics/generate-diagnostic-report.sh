#!/usr/bin/env bash
# generate-diagnostic-report.sh - Generate comprehensive diagnostic report
# Creates a full diagnostic report with all cluster information
#
# Usage: ./generate-diagnostic-report.sh [OPTIONS]
#
# Options:
#   -o, --output       Output file for the report
#   -f, --format       Output format (text, html, markdown)
#   -v, --verbose      Enable verbose output
#   -h, --help         Show this help message

set -euo pipefail

# Get script directory and source common libraries
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common-functions.sh
source "${SCRIPT_DIR}/../lib/common-functions.sh"

# Default configuration
OUTPUT_FILE="${OUTPUT_FILE:-}"
FORMAT="${FORMAT:-text}"

#######################################
# Show help message
#######################################
show_help() {
    cat << EOF
Usage: $(basename "$0") [OPTIONS]

Generate a comprehensive diagnostic report for the Kubernetes cluster.

Options:
  -o, --output FILE   Output file for the report (default: stdout)
  -f, --format FMT    Output format: text, html, markdown (default: text)
  -v, --verbose       Enable verbose output
  -h, --help          Show this help message

Examples:
  $(basename "$0")                          # Output to stdout
  $(basename "$0") -o report.txt            # Save to file
  $(basename "$0") -f markdown -o report.md # Markdown format
  $(basename "$0") -f html -o report.html   # HTML format

The report includes:
  - Cluster overview
  - Node status
  - Workload summary
  - Resource utilization
  - Recent events
  - Potential issues
EOF
}

#######################################
# Parse command line arguments
#######################################
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -o|--output)
                OUTPUT_FILE="${2:?Output file required}"
                shift 2
                ;;
            -f|--format)
                FORMAT="${2:?Format required}"
                shift 2
                ;;
            -v|--verbose)
                export LOG_LEVEL="DEBUG"
                shift
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 2
                ;;
        esac
    done
    
    # Validate format
    case "$FORMAT" in
        text|html|markdown) ;;
        *)
            log_error "Invalid format: $FORMAT. Use: text, html, markdown"
            exit 2
            ;;
    esac
}

#######################################
# Format header based on output format
#######################################
format_header() {
    local title="$1"
    local level="${2:-1}"
    
    case "$FORMAT" in
        html)
            echo "<h${level}>$title</h${level}>"
            ;;
        markdown)
            local prefix
            printf -v prefix '%*s' "$level" ''
            prefix="${prefix// /#}"
            echo "$prefix $title"
            echo ""
            ;;
        *)
            local line
            printf -v line '%*s' "${#title}" ''
            line="${line// /=}"
            echo "$title"
            echo "$line"
            echo ""
            ;;
    esac
}

#######################################
# Format code block
#######################################
format_code() {
    local content="$1"
    
    case "$FORMAT" in
        html)
            echo "<pre>$content</pre>"
            ;;
        markdown)
            echo '```'
            echo "$content"
            echo '```'
            echo ""
            ;;
        *)
            echo "$content"
            echo ""
            ;;
    esac
}

#######################################
# Format list item
#######################################
format_list_item() {
    local item="$1"
    
    case "$FORMAT" in
        html)
            echo "<li>$item</li>"
            ;;
        markdown)
            echo "- $item"
            ;;
        *)
            echo "  • $item"
            ;;
    esac
}

#######################################
# Start HTML document
#######################################
html_start() {
    if [[ "$FORMAT" == "html" ]]; then
        cat << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>Cluster Diagnostic Report</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; }
        h1 { color: #333; }
        h2 { color: #555; border-bottom: 1px solid #ddd; padding-bottom: 10px; }
        pre { background: #f4f4f4; padding: 15px; border-radius: 5px; overflow-x: auto; }
        .warning { color: #856404; background: #fff3cd; padding: 10px; border-radius: 5px; }
        .error { color: #721c24; background: #f8d7da; padding: 10px; border-radius: 5px; }
        .success { color: #155724; background: #d4edda; padding: 10px; border-radius: 5px; }
        table { border-collapse: collapse; width: 100%; margin: 20px 0; }
        th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
        th { background: #f4f4f4; }
    </style>
</head>
<body>
EOF
    fi
}

#######################################
# End HTML document
#######################################
html_end() {
    if [[ "$FORMAT" == "html" ]]; then
        echo "</body></html>"
    fi
}

#######################################
# Generate cluster overview section
#######################################
generate_cluster_overview() {
    format_header "Cluster Overview" 2
    
    local context
    context=$(kubectl config current-context 2>/dev/null || echo "unknown")
    
    local version
    version=$(kubectl version --short 2>/dev/null | grep "Server" || kubectl version 2>/dev/null | grep "Server Version" | head -1 || echo "unknown")
    
    format_list_item "Context: $context"
    format_list_item "Server Version: $version"
    format_list_item "Report Generated: $(date -Iseconds)"
    echo ""
}

#######################################
# Generate node status section
#######################################
generate_node_status() {
    format_header "Node Status" 2
    
    local node_status
    node_status=$(kubectl get nodes -o wide 2>/dev/null || echo "Unable to retrieve node status")
    
    format_code "$node_status"
    
    # Node resource usage if available
    local node_resources
    node_resources=$(kubectl top nodes 2>/dev/null || echo "")
    
    if [[ -n "$node_resources" ]]; then
        format_header "Node Resource Usage" 3
        format_code "$node_resources"
    fi
}

#######################################
# Generate workload summary section
#######################################
generate_workload_summary() {
    format_header "Workload Summary" 2
    
    # Pod summary by namespace
    local pod_summary
    pod_summary=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | \
        awk '{ns[$1]++} END {for (n in ns) print n": "ns[n]" pods"}' | sort || echo "Unable to retrieve")
    
    format_header "Pods by Namespace" 3
    format_code "$pod_summary"
    
    # Deployment status
    local deployment_status
    deployment_status=$(kubectl get deployments --all-namespaces --no-headers 2>/dev/null | \
        awk '{
            split($3, a, "/");
            if (a[1] != a[2]) print $1"/"$2": "a[1]"/"a[2]" ready"
        }' || echo "")
    
    if [[ -n "$deployment_status" ]]; then
        format_header "Deployments Not Fully Ready" 3
        format_code "$deployment_status"
    fi
}

#######################################
# Generate resource utilization section
#######################################
generate_resource_utilization() {
    format_header "Resource Utilization" 2
    
    # Top consuming pods
    local top_pods
    top_pods=$(kubectl top pods --all-namespaces --sort-by=memory 2>/dev/null | head -11 || echo "Metrics not available")
    
    format_header "Top Memory Consuming Pods" 3
    format_code "$top_pods"
    
    # Resource quotas
    local quotas
    quotas=$(kubectl get resourcequotas --all-namespaces 2>/dev/null || echo "No resource quotas")
    
    format_header "Resource Quotas" 3
    format_code "$quotas"
}

#######################################
# Generate events section
#######################################
generate_events() {
    format_header "Recent Events" 2
    
    # Warning events
    local warnings
    warnings=$(kubectl get events --all-namespaces --field-selector type=Warning --sort-by='.lastTimestamp' 2>/dev/null | tail -20 || echo "No warning events")
    
    format_header "Warning Events (Last 20)" 3
    format_code "$warnings"
}

#######################################
# Generate issues section
#######################################
generate_issues() {
    format_header "Potential Issues" 2
    
    local issues_found=false
    
    # Not Ready nodes
    local not_ready_nodes
    not_ready_nodes=$(kubectl get nodes --no-headers 2>/dev/null | grep -v " Ready" || true)
    
    if [[ -n "$not_ready_nodes" ]]; then
        format_header "Nodes Not Ready" 3
        format_code "$not_ready_nodes"
        issues_found=true
    fi
    
    # Failed pods
    local failed_pods
    failed_pods=$(kubectl get pods --all-namespaces --field-selector='status.phase=Failed' --no-headers 2>/dev/null || true)
    
    if [[ -n "$failed_pods" ]]; then
        format_header "Failed Pods" 3
        format_code "$failed_pods"
        issues_found=true
    fi
    
    # Pending pods
    local pending_pods
    pending_pods=$(kubectl get pods --all-namespaces --field-selector='status.phase=Pending' --no-headers 2>/dev/null || true)
    
    if [[ -n "$pending_pods" ]]; then
        format_header "Pending Pods" 3
        format_code "$pending_pods"
        issues_found=true
    fi
    
    # CrashLoopBackOff pods
    local crashloop_pods
    crashloop_pods=$(kubectl get pods --all-namespaces --no-headers 2>/dev/null | grep "CrashLoopBackOff" || true)
    
    if [[ -n "$crashloop_pods" ]]; then
        format_header "CrashLoopBackOff Pods" 3
        format_code "$crashloop_pods"
        issues_found=true
    fi
    
    if [[ "$issues_found" == "false" ]]; then
        echo "No significant issues detected."
        echo ""
    fi
}

#######################################
# Generate the full report
#######################################
generate_report() {
    html_start
    
    format_header "Kubernetes Cluster Diagnostic Report" 1
    
    generate_cluster_overview
    generate_node_status
    generate_workload_summary
    generate_resource_utilization
    generate_events
    generate_issues
    
    html_end
}

#######################################
# Main function
#######################################
main() {
    parse_args "$@"
    
    # Check prerequisites
    require_command kubectl
    
    if ! kubectl_ready; then
        log_error "kubectl is not configured or cluster is not reachable"
        exit 2
    fi
    
    log_info "Generating diagnostic report..."
    
    if [[ -n "$OUTPUT_FILE" ]]; then
        generate_report > "$OUTPUT_FILE"
        log_success "Report saved to: $OUTPUT_FILE"
    else
        generate_report
    fi
}

main "$@"
