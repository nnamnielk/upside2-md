#!/bin/bash

# Batch processing script to run input_capture.py for all nodes in nodes.list.txt
# Author: Generated for upside2-md project
# Usage: ./batch_capture.sh

# Don't exit on individual command failures - we want to continue processing
# set -e

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INPUT_CAPTURE_SCRIPT="$SCRIPT_DIR/input_capture.py"
NODES_LIST_FILE="${1:-$SCRIPT_DIR/../tmp/nodes.list.txt}"  # Allow override with command line argument
LABEL_SUFFIX="${BATCH_CAPTURE_LABEL_SUFFIX:-_chig}"  # Descriptive suffix for labels, configurable via environment variable
RESULTS_DIR="$UPSIDE_HOME/tests/tmp"
RESULTS_FILE="$RESULTS_DIR/batch_capture_results.txt"
LOG_FILE="$RESULTS_DIR/batch_capture.log"
OPTIONAL_NODES_FILE="$RESULTS_DIR/chig_optional_nodes.list.txt"

# Arrays to track results
declare -a successful_captures=()
declare -a failed_captures=()
declare -a skipped_captures=()
declare -a new_optional_nodes=()

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== Batch Input Capture Script ===${NC}"
echo "Processing nodes from: $NODES_LIST_FILE"
echo "Using input capture script: $INPUT_CAPTURE_SCRIPT"
echo "Results directory: $RESULTS_DIR"
echo ""

# Check prerequisites
if [[ ! -f "$INPUT_CAPTURE_SCRIPT" ]]; then
    echo -e "${RED}Error: Input capture script not found: $INPUT_CAPTURE_SCRIPT${NC}"
    exit 1
fi

if [[ ! -f "$NODES_LIST_FILE" ]]; then
    echo -e "${RED}Error: Nodes list file not found: $NODES_LIST_FILE${NC}"
    exit 1
fi

if [[ -z "$UPSIDE_HOME" ]]; then
    echo -e "${RED}Error: UPSIDE_HOME environment variable not set${NC}"
    exit 1
fi

# Ensure results directory exists
mkdir -p "$RESULTS_DIR"

# Initialize log file
echo "Batch Input Capture Log" > "$LOG_FILE"
echo "======================" >> "$LOG_FILE"
echo "Started: $(date)" >> "$LOG_FILE"
echo "Processing nodes from: $NODES_LIST_FILE" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"

# Function to log messages to both console and file
log_message() {
    local message="$1"
    echo -e "$message"
    # Remove color codes for log file
    echo -e "$message" | sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE"
}

# Function to check if node should be skipped
should_skip_node() {
    local class_name="$1"
    
    # Check if optional nodes file exists
    if [[ ! -f "$OPTIONAL_NODES_FILE" ]]; then
        return 1  # Don't skip if file doesn't exist
    fi
    
    # Check if this class name appears in the optional nodes file
    if grep -q "^${class_name} :" "$OPTIONAL_NODES_FILE"; then
        return 0  # Skip this node
    fi
    
    return 1  # Don't skip
}

# Function to add node to optional list if it times out
add_to_optional_nodes() {
    local original_line="$1"
    local class_name="$2"
    
    # Don't add if already in the file
    if should_skip_node "$class_name"; then
        return
    fi
    
    # Add the original line to the optional nodes file
    echo "" >> "$OPTIONAL_NODES_FILE"
    echo "# Added due to timeout: $(date)" >> "$OPTIONAL_NODES_FILE"
    echo "$original_line" >> "$OPTIONAL_NODES_FILE"
    
    new_optional_nodes+=("$class_name")
    log_message "${YELLOW}  → Added $class_name to optional nodes (timeout detected)${NC}"
}

# Function to parse a node line and extract components
parse_node_line() {
    local line="$1"
    
    # Extract class name (everything before first colon, trimmed)
    class_name=$(echo "$line" | cut -d: -f1 | xargs)
    
    # Extract full file path (between "in " and " at line")
    full_path=$(echo "$line" | sed 's/.*in \([^ ]*\) at line.*/\1/')
    
    # Convert absolute path to relative path (remove everything before and including "cuda/")
    file_path=$(echo "$full_path" | sed 's|.*/cuda/||')
    
    # Extract line number (after "at line ")
    line_number=$(echo "$line" | sed 's/.*at line \([0-9]*\)/\1/')
    
    # Validate extraction
    if [[ -z "$class_name" || -z "$file_path" || -z "$line_number" ]]; then
        echo -e "${RED}Error parsing line: $line${NC}"
        return 1
    fi
    
    echo "$class_name|$file_path|$line_number"
}

# Function to process a single node
process_node() {
    local class_name="$1"
    local file_path="$2"
    local line_number="$3"
    local node_counter="$4"
    local total_nodes="$5"
    local original_line="$6"
    
    log_message "${BLUE}[$node_counter/$total_nodes] Processing: $class_name${NC}"
    log_message "  Location: $file_path:$line_number"
    
    # Start timing
    local start_time=$(date +%s)
    log_message "  Started: $(date '+%H:%M:%S')"
    
    # Call the input capture script and capture output with 30 second timeout
    local temp_output="/tmp/capture_output_$$.txt"
    local exit_code=0
    
    timeout 30s python3 "$INPUT_CAPTURE_SCRIPT" \
        --file "$file_path" \
        --line "$line_number" \
        --label "${class_name}${LABEL_SUFFIX}" \
        --max-hits 100 > "$temp_output" 2>&1 || exit_code=$?
    
    # Calculate elapsed time
    local end_time=$(date +%s)
    local elapsed=$((end_time - start_time))
    local elapsed_formatted="${elapsed}s"
    
    # Log the output
    cat "$temp_output" >> "$LOG_FILE"
    
    # Check success/failure and detect timeouts
    if [[ $exit_code -eq 0 ]]; then
        successful_captures+=("$class_name")
        log_message "${GREEN}  ✓ SUCCESS: $class_name (${elapsed_formatted})${NC}"
    else
        local error_msg="Failed to capture data for $class_name at $file_path:$line_number (exit code: $exit_code)"
        failed_captures+=("$class_name: $error_msg")
        log_message "${RED}  FAILED: $class_name (${elapsed_formatted})${NC}"
        log_message "${RED}  Error: $error_msg${NC}"
        
        # Detect timeout (if process took close to 30s timeout)
        if [[ $elapsed -ge 28 ]]; then
            add_to_optional_nodes "$original_line" "$class_name"
        fi
    fi
    
    # Cleanup temp file
    rm -f "$temp_output"
    
    log_message ""
}

# Main processing loop
echo -e "${YELLOW}Starting batch processing...${NC}"
echo ""

# Count total nodes for progress tracking
total_nodes=$(wc -l < "$NODES_LIST_FILE")
node_counter=0

# Process each line in the nodes list
while IFS= read -r line; do
    # Skip empty lines and comments
    if [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]]; then
        continue
    fi
    
    ((node_counter++))
    
    # Parse the node line
    if node_info=$(parse_node_line "$line"); then
        IFS='|' read -r class_name file_path line_number <<< "$node_info"
        
        # Check if this node should be skipped
        if should_skip_node "$class_name"; then
            skipped_captures+=("$class_name")
            log_message "${YELLOW}[$node_counter/$total_nodes] SKIPPED: $class_name (in optional nodes list)${NC}"
            log_message ""
            continue
        fi
        
        # Convert class name to lowercase
        class_name_lower=$(echo "$class_name" | tr '[:upper:]' '[:lower:]')
        
        # Process the node
        process_node "$class_name_lower" "$file_path" "$line_number" "$node_counter" "$total_nodes" "$line"
    else
        failed_captures+=("PARSE_ERROR: Could not parse line: $line")
        log_message "${RED}[$node_counter/$total_nodes] PARSE ERROR: $line${NC}"
        log_message ""
    fi
    
done < "$NODES_LIST_FILE"

# Generate results summary
log_message "${BLUE}=== BATCH PROCESSING COMPLETE ===${NC}"
log_message ""

successful_count=${#successful_captures[@]}
failed_count=${#failed_captures[@]}
skipped_count=${#skipped_captures[@]}
total_processed=$((successful_count + failed_count))
total_nodes_in_file=$((total_processed + skipped_count))

log_message "Total nodes in file: $total_nodes_in_file"
log_message "Nodes processed: $total_processed"
log_message "${YELLOW}Nodes skipped: $skipped_count${NC}"
log_message "${GREEN}Successful captures: $successful_count${NC}"
log_message "${RED}Failed captures: $failed_count${NC}"
log_message ""

if [[ ${#new_optional_nodes[@]} -gt 0 ]]; then
    log_message "${YELLOW}New nodes added to optional list due to timeout:${NC}"
    for new_node in "${new_optional_nodes[@]}"; do
        log_message "${YELLOW}  → $new_node${NC}"
    done
    log_message ""
fi

# Add completion timestamp to log
echo "Completed: $(date)" >> "$LOG_FILE"
echo "" >> "$LOG_FILE"

# Create detailed results file
{
    echo "Batch Input Capture Results"
    echo "=========================="
    echo "Date: $(date)"
    echo "Total processed: $total_processed"
    echo "Successful: $successful_count"
    echo "Failed: $failed_count"
    echo ""
    
    if [[ $successful_count -gt 0 ]]; then
        echo "SUCCESSFUL CAPTURES ($successful_count):"
        echo "--------------------------------------"
        for success in "${successful_captures[@]}"; do
            echo "✓ $success"
        done
        echo ""
    fi
    
    if [[ $failed_count -gt 0 ]]; then
        echo "FAILED CAPTURES ($failed_count):"
        echo "-------------------------------"
        for failure in "${failed_captures[@]}"; do
            echo "✗ $failure"
        done
        echo ""
    fi
    
    echo "Generated files location: $RESULTS_DIR"
    echo "Individual capture files: {NodeName}_capture.json, {NodeName}_inputs.log"
    
} > "$RESULTS_FILE"

echo "Detailed results saved to: $RESULTS_FILE"

# Display summary of failures if any
if [[ $failed_count -gt 0 ]]; then
    echo ""
    echo -e "${RED}FAILED CAPTURES SUMMARY:${NC}"
    for failure in "${failed_captures[@]}"; do
        echo -e "${RED} $failure${NC}"
    done
    echo ""
    echo -e "${YELLOW}Check the results file for detailed error information.${NC}"
fi

# Display final status
if [[ $failed_count -eq 0 ]]; then
    echo -e "${GREEN} All captures completed successfully!${NC}"
    exit 0
else
    echo -e "${YELLOW} Completed with $failed_count failures. See results file for details.${NC}"
    exit 1
fi
