#!/bin/bash

# regression.sh - Run regression tests on Upside2 examples
# Usage: ./regression.sh [--example=01,03,05] [--help]

set -e

# Default values
RUN_ALL=true
SELECTED_EXAMPLES=""
CONDA_ENV="upside2-env"
EXAMPLE_DIR="../../example"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="regression_results.log"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --example=*)
            SELECTED_EXAMPLES="${1#*=}"
            RUN_ALL=false
            shift
            ;;
        --help)
            echo "Usage: $0 [--example=01,03,05] [--help]"
            echo ""
            echo "Options:"
            echo "  --example=X,Y,Z   Run only specified examples (e.g., 01,03,05)"
            echo "  --help           Show this help message"
            echo ""
            echo "Examples:"
            echo "  $0                Run all examples"
            echo "  $0 --example=01   Run only example 01"
            echo "  $0 --example=01,03,07   Run examples 01, 03, and 07"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Function to print colored output
print_status() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

# Function to check if conda environment exists
check_conda_env() {
    if ! conda env list | grep -q "^${CONDA_ENV} "; then
        print_status $RED "ERROR: Conda environment '${CONDA_ENV}' not found!"
        print_status $YELLOW "Please create the environment or check the name."
        exit 1
    fi
}

# Function to find the main Python script in an example directory
find_main_script() {
    local example_path=$1
    
    # Common script names to look for, in order of preference
    local script_candidates=(
        "0.run.py"
        "run.py" 
        "0.normal.run.py"
    )
    
    for script in "${script_candidates[@]}"; do
        if [[ -f "${example_path}/${script}" ]]; then
            echo "$script"
            return 0
        fi
    done
    
    # If no common script found, look for any .py file with "run" in the name
    local run_script=$(find "$example_path" -maxdepth 1 -name "*run*.py" | head -n 1)
    if [[ -n "$run_script" ]]; then
        basename "$run_script"
        return 0
    fi
    
    return 1
}

# Function to run a single example
run_example() {
    local example_num=$1
    local example_name=""
    local example_path=""
    local script_name=""
    
    # Find the example directory
    for dir in "$SCRIPT_DIR/$EXAMPLE_DIR"/*; do
        if [[ -d "$dir" && "$(basename "$dir")" =~ ^${example_num}\. ]]; then
            example_name=$(basename "$dir")
            example_path="$dir"
            break
        fi
    done
    
    if [[ -z "$example_path" ]]; then
        print_status $RED "ERROR: Example ${example_num} not found!"
        return 1
    fi
    
    print_status $BLUE "Running example: $example_name"
    
    # Find the main script to run
    if ! script_name=$(find_main_script "$example_path"); then
        print_status $RED "ERROR: No runnable Python script found in $example_name"
        return 1
    fi
    
    print_status $YELLOW "  Found script: $script_name"
    
    # Change to example directory and run the script
    cd "$example_path"
    
    # Activate conda environment and run the script
    local cmd="conda activate ${CONDA_ENV} && python ${script_name}"
    print_status $YELLOW "  Executing: $cmd"
    
    # Run with timeout and capture output
    if timeout 600 bash -c "source $(conda info --base)/etc/profile.d/conda.sh && conda activate ${CONDA_ENV} && python ${script_name}" 2>&1 | tee -a "${SCRIPT_DIR}/${LOG_FILE}"; then
        print_status $GREEN "  SUCCESS: $example_name completed"
        return 0
    else
        local exit_code=${PIPESTATUS[0]}
        if [[ $exit_code -eq 124 ]]; then
            print_status $RED "  TIMEOUT: $example_name exceeded 10 minutes"
        else
            print_status $RED "  FAILED: $example_name (exit code: $exit_code)"
        fi
        return 1
    fi
}

# Main execution
main() {
    print_status $BLUE "Upside2 Regression Testing Script"
    print_status $BLUE "================================="
    
    # Check if conda environment exists
    check_conda_env
    
    # Initialize log file
    echo "Regression test started at $(date)" > "${SCRIPT_DIR}/${LOG_FILE}"
    
    # Get list of examples to run
    local examples_to_run=()
    
    if [[ "$RUN_ALL" == true ]]; then
        # Get all example directories
        for dir in "$SCRIPT_DIR/$EXAMPLE_DIR"/*; do
            if [[ -d "$dir" ]]; then
                local example_num=$(basename "$dir" | cut -d'.' -f1)
                if [[ "$example_num" =~ ^[0-9]+$ ]]; then
                    examples_to_run+=("$example_num")
                fi
            fi
        done
        print_status $YELLOW "Running ALL examples: ${examples_to_run[*]}"
    else
        # Parse selected examples
        IFS=',' read -ra examples_to_run <<< "$SELECTED_EXAMPLES"
        print_status $YELLOW "Running SELECTED examples: ${examples_to_run[*]}"
    fi
    
    # Run examples
    local total_examples=${#examples_to_run[@]}
    local successful_runs=0
    local failed_runs=0
    
    for example in "${examples_to_run[@]}"; do
        # Pad example number with leading zero if needed
        local padded_example=$(printf "%02d" "$example")
        
        if run_example "$padded_example"; then
            ((successful_runs++))
        else
            ((failed_runs++))
        fi
        
        # Return to script directory
        cd "$SCRIPT_DIR"
        echo "" # Add spacing between examples
    done
    
    # Print summary
    print_status $BLUE "Regression Test Summary"
    print_status $BLUE "======================"
    print_status $GREEN "Successful runs: $successful_runs/$total_examples"
    print_status $RED "Failed runs: $failed_runs/$total_examples"
    
    if [[ $failed_runs -eq 0 ]]; then
        print_status $GREEN "All tests PASSED!"
        exit 0
    else
        print_status $RED "Some tests FAILED!"
        print_status $YELLOW "Check $LOG_FILE for detailed output"
        exit 1
    fi
}

# Run main function
main "$@"
