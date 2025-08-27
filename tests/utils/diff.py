#!/usr/bin/env python3

import h5py
import numpy as np
import sys
import argparse

def compare_hdf5_node(file1_path, file2_path, node_name, frame_offset=1, threshold=1e-6):
    """
    Compare a specific node in two HDF5 files and display values with differences.
    
    Args:
        file1_path: Path to first HDF5 file
        file2_path: Path to second HDF5 file
        node_name: Name of the node under output/ to compare
        frame_offset: Number of frames to skip before comparison (default=1)
        threshold: Threshold for highlighting divergent values (default=1e-6)
    """
    
    # ANSI color codes
    RED = '\033[91m'
    RESET = '\033[0m'
    
    with h5py.File(file1_path, 'r') as f1, h5py.File(file2_path, 'r') as f2:
        
        # Check if both files have output groups and the specified node
        if 'output' not in f1 or 'output' not in f2:
            print("Error: Both files must have 'output' group")
            return
            
        if node_name not in f1['output'] or node_name not in f2['output']:
            print(f"Error: Node '{node_name}' not found in one or both files")
            print(f"Available nodes in file1: {list(f1['output'].keys())}")
            print(f"Available nodes in file2: {list(f2['output'].keys())}")
            return
            
        data1 = f1['output'][node_name][:]
        data2 = f2['output'][node_name][:]
        
        print(f"Comparing node: {node_name}")
        print(f"Shape file1: {data1.shape}")
        print(f"Shape file2: {data2.shape}")
        print(f"Frame offset: {frame_offset}")
        print(f"Threshold for highlighting: {threshold}")
        
        # Check if shapes match
        if data1.shape != data2.shape:
            print(f"Error: Shapes don't match: {data1.shape} vs {data2.shape}")
            return
            
        # Skip if not numeric data
        if not np.issubdtype(data1.dtype, np.number) or not np.issubdtype(data2.dtype, np.number):
            print("Error: Data is not numeric")
            return
            
        # Skip if not enough frames for offset
        if len(data1.shape) == 0 or (len(data1.shape) > 0 and data1.shape[0] <= frame_offset):
            print(f"Error: Not enough frames for offset {frame_offset}")
            return
            
        # Get data after frame offset
        if len(data1.shape) == 1:
            subset1 = data1[frame_offset:]
            subset2 = data2[frame_offset:]
        else:
            subset1 = data1[frame_offset:]
            subset2 = data2[frame_offset:]
        
        if subset1.size == 0:
            print("No data to compare after applying frame offset")
            return
            
        # Calculate differences
        diff_data = subset2 - subset1
        abs_diff = np.abs(diff_data)
        
        max_diff = np.max(abs_diff)
        mean_diff = np.mean(abs_diff)
        
        print(f"\nResults:")
        print(f"Maximum absolute difference: {max_diff}")
        print(f"Mean absolute difference: {mean_diff}")
        print(f"Total elements compared: {diff_data.size}")
        
        print(f"\nValue comparison (format: value1±diff, where diff = value2 - value1):")
        print("Divergent values (|diff| > threshold) are highlighted in red\n")
        
        # Display values preserving original structure (limit frames for readability)
        max_frames_to_show = min(10, subset1.shape[0])  # Show up to 10 frames
        
        if len(subset1.shape) > 1 and len(subset1[0].shape) == 1:
            # 2D case like (frames, angles) - show as simple table
            # Display each frame as a row with frame number followed by all values
            for frame_idx in range(max_frames_to_show):
                frame_data1 = subset1[frame_idx]
                frame_diff = diff_data[frame_idx]
                frame_abs_diff = abs_diff[frame_idx]
                
                # Start with frame number
                row = f"{frame_idx + frame_offset:2d}: "
                
                # Determine precision based on threshold
                if threshold >= 1e-3:
                    diff_precision = 3
                elif threshold >= 1e-6:
                    diff_precision = 6
                else:
                    diff_precision = 9
                
                # Add all values for this frame
                for col_idx in range(len(frame_data1)):
                    val1 = frame_data1[col_idx]
                    diff = frame_diff[col_idx]
                    abs_d = frame_abs_diff[col_idx]
                    
                    if abs_d > threshold:
                        if diff >= 0:
                            cell_output = f"{RED}{val1:.2f}+{diff:.{diff_precision}f}{RESET}"
                        else:
                            cell_output = f"{RED}{val1:.2f}{diff:.{diff_precision}f}{RESET}"
                    else:
                        if diff >= 0:
                            cell_output = f"{val1:.2f}+{diff:.{diff_precision}f}"
                        else:
                            cell_output = f"{val1:.2f}{diff:.{diff_precision}f}"
                    
                    row += f"{cell_output:>15} "
                
                print(row)
            
        else:
            # Handle other cases (1D or higher dimensional)
            for frame_idx in range(max_frames_to_show):
                print(f"Frame {frame_idx + frame_offset}:")
                
                if len(subset1.shape) == 1:
                    # 1D case
                    val1 = subset1[frame_idx]
                    val2 = subset2[frame_idx]
                    diff = diff_data[frame_idx]
                    abs_d = abs_diff[frame_idx]
                    
                    if abs_d > threshold:
                        if diff >= 0:
                            output = f"{RED}{val1:.6f} +{diff:.6f}{RESET}"
                        else:
                            output = f"{RED}{val1:.6f} {diff:.6f}{RESET}"
                    else:
                        if diff >= 0:
                            output = f"{val1:.6f} +{diff:.6f}"
                        else:
                            output = f"{val1:.6f} {diff:.6f}"
                    print(f"  {output}")
                    
                else:
                    # Multi-dimensional case - flatten and show
                    frame_data1 = subset1[frame_idx]
                    frame_diff = diff_data[frame_idx]
                    frame_abs_diff = abs_diff[frame_idx]
                    
                    flat_frame1 = frame_data1.flatten()
                    flat_frame_diff = frame_diff.flatten()
                    flat_frame_abs_diff = frame_abs_diff.flatten()
                    
                    for i in range(min(50, len(flat_frame1))):  # Show first 50 values
                        val1 = flat_frame1[i]
                        diff = flat_frame_diff[i]
                        abs_d = flat_frame_abs_diff[i]
                        
                        if abs_d > threshold:
                            if diff >= 0:
                                output = f"{RED}{val1:.6f} +{diff:.6f}{RESET}"
                            else:
                                output = f"{RED}{val1:.6f} {diff:.6f}{RESET}"
                        else:
                            if diff >= 0:
                                output = f"{val1:.6f} +{diff:.6f}"
                            else:
                                output = f"{val1:.6f} {diff:.6f}"
                        
                        print(f"  [{i:2d}]: {output}")
                
                print()  # Empty line between frames
        
        if subset1.shape[0] > max_frames_to_show:
            print(f"... (showing first {max_frames_to_show} of {subset1.shape[0]} frames)")
        
        # Summary of divergent values
        flat_abs_diff = abs_diff.flatten()
        divergent_count = np.sum(flat_abs_diff > threshold)
        print(f"\nSummary: {divergent_count}/{flat_abs_diff.size} values diverge (threshold: {threshold})")

def main():
    parser = argparse.ArgumentParser(description='Compare a specific node in two HDF5 files')
    parser.add_argument('file1', help='Path to first HDF5 file')
    parser.add_argument('file2', help='Path to second HDF5 file')
    parser.add_argument('node', help='Name of the node under output/ to compare')
    parser.add_argument('--frame-offset', type=int, default=1, help='Frame offset for comparison (default: 1)')
    parser.add_argument('--threshold', type=float, default=1e-6, help='Threshold for highlighting divergent values (default: 1e-6)')
    
    args = parser.parse_args()
    
    try:
        compare_hdf5_node(args.file1, args.file2, args.node, args.frame_offset, args.threshold)
    except FileNotFoundError as e:
        print(f"Error: {e}")
        sys.exit(1)
    except Exception as e:
        print(f"Unexpected error: {e}")
        sys.exit(1)

if __name__ == '__main__':
    main()