#ifndef NEXUSMINER_WORKER_HPP
#define NEXUSMINER_WORKER_HPP

#include <memory>
#include <functional>
#include "uint1024.h"
#include "../LLP/block.hpp"
#include "statistics.hpp"
#include <asio.hpp>


namespace LLP { class CBlock; }
namespace asio { class io_context; }

namespace nexusminer {

class Block_data
{
public:

	uint512 merkle_root;
    uint1024 previous_hash;

	// result
	std::uint64_t nonce;
	std::uint32_t nonce_difficulty;
};

class Worker {
public:

	virtual ~Worker() = default;

    // A call to the BlockFoundHandler informs the user about a new found block.
    using Block_found_handler = std::function<void(std::shared_ptr<Block_data>&& block)>;

    // Sets a new block (nexus data type) for the miner worker. The miner worker must reset the current work.
    // When  the worker finds a new block, the BlockFoundHandler has to be called with the found BlockData
    virtual void set_block(const LLP::CBlock& block, Block_found_handler result) = 0;

    virtual void print_statistics() = 0;

private:
    std::shared_ptr<::asio::io_context> m_io_context;

};

}


#endif