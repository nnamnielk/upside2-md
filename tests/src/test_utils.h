#pragma once

#include <string>
#include <vector>
#include <fstream>
#include <iostream>
#include <memory>
#include <cmath>
#include <sstream>
#include <iomanip>
#include <regex>
#include <algorithm>

// Forward declarations to avoid circular dependencies
// The actual includes will be in the test file
struct VecArrayStorage;
template<typename T, int Dim> class DeviceBuffer;

// We'll use a simple JSON-like structure instead of nlohmann for the header
using json = std::map<std::string, std::string>;

/**
 * Test utilities for CoordNode and PotentialNode validation
 * 
 * Handles both CoordNode and PotentialNode testing since both have compute_value().
 * Accounts for compute_value() being an IMPURE method (modifies internal state).
 */

namespace TestUtils {
    
    // Load JSON data from file
    inline json load_json(const std::string& path) {
        std::ifstream file(path);
        if (!file.is_open()) {
            throw std::runtime_error("Cannot open JSON file: " + path);
        }
        json data;
        file >> data;
        return data;
    }
    
    // Save JSON data to file  
    inline void save_json(const std::string& path, const json& data) {
        std::ofstream file(path);
        if (!file.is_open()) {
            throw std::runtime_error("Cannot write JSON file: " + path);
        }
        file << std::setw(2) << data << std::endl;
    }
    
    // Parse array data from GDB output format (handles various GDB formatting)
    inline std::vector<float> parse_gdb_array(const std::string& gdb_output) {
        std::vector<float> result;
        std::string cleaned = gdb_output;
        
        // Remove GDB formatting characters
        std::vector<char> chars_to_remove = {'{', '}', '(', ')', '[', ']'};
        for (char c : chars_to_remove) {
            cleaned.erase(std::remove(cleaned.begin(), cleaned.end(), c), cleaned.end());
        }
        
        std::stringstream ss(cleaned);
        std::string item;
        while (std::getline(ss, item, ',')) {
            // Trim whitespace
            item.erase(0, item.find_first_not_of(" \t"));
            item.erase(item.find_last_not_of(" \t") + 1);
            
            try {
                if (!item.empty()) {
                    float value = std::stof(item);
                    result.push_back(value);
                }
            } catch (const std::exception&) {
                // Skip non-numeric values
                continue;
            }
        }
        
        return result;
    }
    
    // Extract integer from GDB output (handles "n_elem = 42" or just "42")
    inline int extract_int_from_gdb(const std::string& gdb_output) {
        std::regex number_regex(R"(\d+)");
        std::smatch match;
        if (std::regex_search(gdb_output, match, number_regex)) {
            return std::stoi(match[0]);
        }
        throw std::runtime_error("No integer found in: " + gdb_output);
    }
    
    // Validate numerical equivalence with tolerance
    inline bool validate_arrays_equal(const std::vector<float>& expected, 
                                    const std::vector<float>& actual, 
                                    double tolerance = 1e-6) {
        if (expected.size() != actual.size()) {
            std::cout << "Size mismatch: expected " << expected.size() 
                      << " but got " << actual.size() << std::endl;
            return false;
        }
        
        for (size_t i = 0; i < expected.size(); ++i) {
            if (!std::isfinite(expected[i]) || !std::isfinite(actual[i])) {
                if (std::isfinite(expected[i]) != std::isfinite(actual[i])) {
                    std::cout << "Finite mismatch at index " << i 
                              << ": expected " << expected[i] 
                              << " but got " << actual[i] << std::endl;
                    return false;
                }
                continue;  // Both non-finite, consider equal
            }
            
            double diff = std::abs(expected[i] - actual[i]);
            double max_val = std::max(std::abs(expected[i]), std::abs(actual[i]));
            
            if (max_val > tolerance) {
                if (diff / max_val > tolerance) {
                    std::cout << "Tolerance exceeded at index " << i 
                              << ": expected " << expected[i] 
                              << " but got " << actual[i] 
                              << " (relative error: " << (diff/max_val) << ")" << std::endl;
                    return false;
                }
            } else if (diff > tolerance) {
                std::cout << "Absolute tolerance exceeded at index " << i 
                          << ": expected " << expected[i] 
                          << " but got " << actual[i] 
                          << " (absolute error: " << diff << ")" << std::endl;
                return false;
            }
        }
        return true;
    }
    
    // Convert VecArrayStorage to vector (for output capture)
    inline std::vector<float> vecarray_to_vector(const VecArrayStorage& storage) {
        if (!storage.x) return {};
        size_t total_size = storage.n_elem * storage.row_width;
        std::vector<float> result(storage.x.get(), storage.x.get() + total_size);
        return result;
    }
    
    // Convert DeviceBuffer to vector (for output capture)
    template<typename T, int Dim>
    inline std::vector<float> devicebuffer_to_vector(const DeviceBuffer<T, Dim>& buffer) {
        const VecArrayStorage* storage = buffer.h_ptr();
        if (!storage) return {};
        return vecarray_to_vector(*storage);
    }
    
    // Test dataset structure for complete input+output test cases
    struct TestDataset {
        std::string node_type;
        std::string test_name;
        json metadata;
        json inputs;
        json expected_outputs;
        
        // Save complete dataset to file
        void save(const std::string& path) const {
            json dataset = {
                {"metadata", metadata},
                {"inputs", inputs},
                {"expected_outputs", expected_outputs}
            };
            save_json(path, dataset);
        }
        
        // Load complete dataset from file
        static TestDataset load(const std::string& path) {
            json data = load_json(path);
            TestDataset dataset;
            dataset.metadata = data["metadata"];
            dataset.inputs = data["inputs"];
            dataset.expected_outputs = data["expected_outputs"];
            if (data["metadata"].contains("node_type")) {
                dataset.node_type = data["metadata"]["node_type"];
            }
            if (data["metadata"].contains("test_name")) {
                dataset.test_name = data["metadata"]["test_name"];
            }
            return dataset;
        }
    };
    
    // Extract captured input data from JSON (handles both successful and failed captures)
    struct CapturedInput {
        bool valid = false;
        int n_elem = 0;
        int elem_width = 0;
        std::vector<float> input_data;
        json raw_capture;
        std::string error_message;
    };
    
    inline CapturedInput extract_input_from_capture(const json& capture_data) {
        CapturedInput result;
        
        if (capture_data.empty()) {
            result.error_message = "Empty capture data";
            return result;
        }
        
        try {
            // Store raw data
            result.raw_capture = capture_data[0];  // First hit
            
            // Extract dimensions from this_members (both CoordNode and PotentialNode have these)
            if (capture_data[0].contains("this_members")) {
                auto members = capture_data[0]["this_members"];
                
                // Try different field name variations
                std::vector<std::string> n_elem_fields = {"this->n_elem", "this.n_elem", "n_elem"};
                std::vector<std::string> width_fields = {"this->elem_width", "this.elem_width", "elem_width"};
                
                for (const auto& field : n_elem_fields) {
                    if (members.contains(field)) {
                        result.n_elem = extract_int_from_gdb(members[field].get<std::string>());
                        break;
                    }
                }
                
                for (const auto& field : width_fields) {
                    if (members.contains(field)) {
                        result.elem_width = extract_int_from_gdb(members[field].get<std::string>());
                        break;
                    }
                }
            }
            
            // Extract input array data if available
            if (capture_data[0].contains("custom_commands")) {
                auto commands = capture_data[0]["custom_commands"];
                
                // Look for various input data field names
                std::vector<std::string> data_fields = {"input_positions", "positions", "input_data", "data"};
                for (const auto& field : data_fields) {
                    if (commands.contains(field)) {
                        std::string data_str = commands[field].get<std::string>();
                        result.input_data = parse_gdb_array(data_str);
                        break;
                    }
                }
            }
            
            result.valid = (result.n_elem > 0 && result.elem_width > 0);
            if (!result.valid) {
                result.error_message = "Missing required dimensions (n_elem=" + 
                                     std::to_string(result.n_elem) + ", elem_width=" + 
                                     std::to_string(result.elem_width) + ")";
            }
            
        } catch (const std::exception& e) {
            result.error_message = "Parse error: " + std::string(e.what());
            result.valid = false;
        }
        
        return result;
    }
    
    // Print test result summary
    inline void print_test_summary(const std::string& test_name, 
                                 bool passed, 
                                 const std::string& details = "") {
        std::cout << "[" << (passed ? "PASS" : "FAIL") << "] " << test_name;
        if (!details.empty()) {
            std::cout << " - " << details;
        }
        std::cout << std::endl;
    }
    
    // Create directories if they don't exist
    inline void ensure_directory(const std::string& path) {
        std::string cmd = "mkdir -p " + path;
        std::system(cmd.c_str());
    }
}
