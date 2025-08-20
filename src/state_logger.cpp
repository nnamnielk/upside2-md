#include "state_logger.h"
#include <stdexcept>

std::shared_ptr<H5Logger> default_logger;

void H5Logger::write_graph(DerivEngine* engine, const std::string& filename) {
    if (!engine) {
        throw std::runtime_error("No engine provided for graph dump");
    }
    engine->write_graphviz(filename);
}
