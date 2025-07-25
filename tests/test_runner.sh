#!/usr/bin/env bash

if [ -z "$UPSIDE_HOME" ]; then
    echo "Error: UPSIDE_HOME is not set."
    exit 1
fi

PYTHON=python3
SCRIPT="$UPSIDE_HOME/tests/validate_method.py"

#interaction_graph.h
echo "$PYTHON" "$SCRIPT" --method=change_cache_buffer --json="$UPSIDE_HOME/tests/records/line_182_capture.json" --args=args.new_buffer 
"$PYTHON" "$SCRIPT" --method=change_cache_buffer --json="$UPSIDE_HOME/tests/records/line_182_capture.json" --args=args.new_buffer 
echo "$PYTHON" "$SCRIPT" --method=test_ensure_cache_valid --json="${UPSIDE_HOME}/tests/records/line_62_capture.json" --args dereferenced_args.this_type "this_members['this->.n_elem1']" "this_members['this->.n_elem2']" "this_members['this->.cache_valid']" "this_members['this->.cache_buffer']" "this_members['this->.cache_cutoff']" "this_members['this->.cache_n_edge']" args.cutoff args.pos1_stride args.pos2_stride custom_commands.pos_array_1 custom_commands.pos_array_2 "dereferenced_args['*id1']" "dereferenced_args['*id2']"
"$PYTHON" "$SCRIPT" --method=test_ensure_cache_valid --json="${UPSIDE_HOME}/tests/records/line_62_capture.json" --args dereferenced_args.this_type "this_members['this->.n_elem1']" "this_members['this->.n_elem2']" "this_members['this->.cache_valid']" "this_members['this->.cache_buffer']" "this_members['this->.cache_cutoff']" "this_members['this->.cache_n_edge']" args.cutoff args.pos1_stride args.pos2_stride custom_commands.pos_array_1 custom_commands.pos_array_2 "dereferenced_args['*id1']" "dereferenced_args['*id2']"

#hbond.cpp - HBondCoverageInteraction::cutoff function
echo "$PYTHON" "$SCRIPT" --method=test_hbond_coverage_cutoff --json="$UPSIDE_HOME/tests/records/line_266_capture.json" --args args.id1 custom_commands.n_knot_value custom_commands.inv_dx_value
"$PYTHON" "$SCRIPT" --method=test_hbond_coverage_cutoff --json="$UPSIDE_HOME/tests/records/line_266_capture.json" --args args.id1 custom_commands.n_knot_value custom_commands.inv_dx_value
