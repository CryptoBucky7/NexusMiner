#include "gpu/worker_prime.hpp"
#include "config/config.hpp"
#include "stats/stats_collector.hpp"
#include "prime/prime.hpp"
#include "prime/sieve.hpp"
#include "prime/prime_tests.hpp"
#include "block.hpp"
#include <asio.hpp>
#include <primesieve.hpp>
#include <sstream> 
#include <boost/random.hpp>

namespace nexusminer
{
namespace gpu
{
Worker_prime::Worker_prime(std::shared_ptr<asio::io_context> io_context, config::Worker_config& config)
	: m_io_context{ std::move(io_context) }
	, m_logger{ spdlog::get("logger") }
	, m_config{ config }
	, m_prime_helper{std::make_unique<Prime>()}
	, m_segmented_sieve{std::make_unique<Sieve>()}
	, m_stop{ true }
	, m_log_leader{ "GPU Worker " + m_config.m_id + ": " }
	, m_primes{ 0 }
	, m_chains{ 0 }
	, m_difficulty{ 0 }
	, m_pool_nbits{ 0 }
{
	
	auto& worker_config_gpu = std::get<config::Worker_config_gpu>(m_config.m_worker_mode);
	PrimeTests prime_test(worker_config_gpu.m_device);
	prime_test.fermat_performance_test();
	prime_test.sieve_performance_test();
	m_segmented_sieve->generate_sieving_primes();
	m_segmented_sieve->reset_stats();

}

Worker_prime::~Worker_prime() noexcept
{
	//make sure the run thread exits the loop
	m_stop = true;
	if (m_run_thread.joinable())
		m_run_thread.join();
}

void Worker_prime::set_block(LLP::CBlock block, std::uint32_t nbits, Worker::Block_found_handler result)
{
	//stop the existing mining loop if it is running
	m_stop = true;
	if (m_run_thread.joinable())
	{
		m_run_thread.join();
	}

	{
		std::scoped_lock<std::mutex> lck(m_mtx);
		m_found_nonce_callback = result;
		m_block = Block_data{ block };
		if (nbits != 0)	// take nBits provided from pool
		{
			m_pool_nbits = nbits;
		}

		m_difficulty = m_pool_nbits != 0 ? m_pool_nbits : m_block.nBits;
		bool excludeNonce = true;  //prime block hash excludes the nonce
		std::vector<unsigned char> headerB = m_block.GetHeaderBytes(excludeNonce);
		//calculate the block hash
		NexusSkein skein;
		skein.setMessage(headerB);
		skein.calculateHash();
		NexusSkein::stateType hash = skein.getHash();

		//keccak
		NexusKeccak keccak(hash);
		keccak.calculateHash();
		NexusKeccak::k_1024 keccakFullHash_i = keccak.getHashResult();
		keccakFullHash_i.isBigInt = true;
		uint1k keccakFullHash("0x" + keccakFullHash_i.toHexString(true));
		m_base_hash = keccakFullHash;
		//Now we have the hash of the block header.  We use this to feed the miner. 

		//set the starting nonce for each worker to something different that won't overlap with the others
		m_starting_nonce = static_cast<uint64_t>(m_config.m_internal_id) << 48;
		m_nonce = m_starting_nonce;

		//set the sieve start range
		uint1k startprime = m_base_hash + m_nonce;
		m_segmented_sieve->set_sieve_start(startprime);
		//update the starting nonce to reflect the actual sieve start used
		m_nonce = static_cast<uint64_t>(m_segmented_sieve->get_sieve_start() - m_base_hash);
		//m_logger->debug("starting nonce: {}", m_nonce);
		//clear out any old chains from the last block
		m_segmented_sieve->clear_chains();
	}
	//restart the mining loop
	m_stop = false;
	m_run_thread = std::thread(&Worker_prime::run, this);
}

void Worker_prime::run()
{
	m_segmented_sieve->calculate_starting_multiples();
	uint32_t segment_size = m_segmented_sieve->get_segment_size();
	uint32_t segment_batch_size = m_segmented_sieve->get_segment_batch_size();
	uint32_t sieve_batch_range = segment_batch_size * segment_size;
	uint64_t find_chains_ms = 0;
	uint64_t sieving_ms = 0;
	uint64_t test_chains_ms = 0;
	uint64_t elapsed_ms = 0;
	//uint64_t high = 0;
	uint64_t low = 0;
	uint64_t range_searched_this_cycle = 0;
	bool batch_sieve_mode = true;
	auto& worker_config_gpu = std::get<config::Worker_config_gpu>(m_config.m_worker_mode);
	m_segmented_sieve->gpu_sieve_init(worker_config_gpu.m_device);


	auto start = std::chrono::steady_clock::now();
	auto interval_start = std::chrono::steady_clock::now();
	while (!m_stop)
	{
		//m_segmented_sieve->reset_sieve();
		// current segment = [low, high]
		//high = low + segment_size - 1;
		//uint64_t sieve_size = (high - low) / 30 + 1;
		m_range_searched += sieve_batch_range;
		range_searched_this_cycle += sieve_batch_range;

		auto sieve_start = std::chrono::steady_clock::now();
		//m_segmented_sieve->sieve_segment();
		//m_segmented_sieve->sieve_batch_cpu(low);
		m_segmented_sieve->sieve_batch(low);
		auto sieve_stop = std::chrono::steady_clock::now();
		auto sieve_elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(sieve_stop - sieve_start);
		sieving_ms += sieve_elapsed.count();
		auto find_chains_start = std::chrono::steady_clock::now();
		//m_segmented_sieve->find_chains_cpu(low, batch_sieve_mode);
		m_segmented_sieve->find_chains();
		auto find_chains_stop = std::chrono::steady_clock::now();
		auto find_chains_elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(find_chains_stop - find_chains_start);
		find_chains_ms += find_chains_elapsed.count();
		if (m_segmented_sieve->get_current_chain_list_length() >= m_segmented_sieve->get_fermat_test_batch_size())
		{
			//m_logger->debug("Batch primality testing {} candidates.", m_segmented_sieve->get_current_chain_list_length());
			auto test_chains_start = std::chrono::steady_clock::now();
			m_segmented_sieve->primality_batch_test(worker_config_gpu.m_device);
			auto test_chains_stop = std::chrono::steady_clock::now();
			auto test_chains_elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(test_chains_stop - test_chains_start);
			test_chains_ms += test_chains_elapsed.count();
			m_segmented_sieve->clean_chains();
		}

		//check difficulty of any chains that passed through the filter
		for (auto x : m_segmented_sieve->m_long_chain_starts)
		{
			m_block.nNonce = m_nonce + x;
			uint1k chain_start = m_base_hash + m_block.nNonce;
			m_logger->info("Actual difficulty {} required {}", getDifficulty(chain_start), getNetworkDifficulty());
			if (difficulty_check(chain_start))
			{
				//we found a valid chain.  submit it. 
				{
					if (m_found_nonce_callback)
					{
						m_io_context->post([self = shared_from_this()]()
						{
							self->m_found_nonce_callback(self->m_config.m_internal_id, std::make_unique<Block_data>(self->m_block));
						});
					}
					else
					{
						m_logger->debug(m_log_leader + "Miner callback function not set.");
					}
				}
			}
		}
		m_segmented_sieve->m_long_chain_starts = {};
		low += sieve_batch_range;

		//debug
		auto end = std::chrono::steady_clock::now();
		auto interval_elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(end - interval_start); 
		bool print_debug = true;
		if (print_debug && interval_elapsed.count() > 10000)
		{
			std::cout << "--debug--" << std::endl;
			auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(end - start);
			elapsed_ms = elapsed.count();
			double chains_per_mm = 1.0e6 * m_segmented_sieve->m_chain_count / m_range_searched;
			double chains_per_sec = 1.0e3 * m_segmented_sieve->m_chain_count / elapsed_ms;
			double fermat_positive_rate = 1.0 * m_segmented_sieve->m_fermat_prime_count / m_segmented_sieve->m_fermat_test_count;
			double fermat_tests_per_chain = 1.0 * m_segmented_sieve->m_fermat_test_count / m_segmented_sieve->m_chain_count;
			std::cout << std::fixed << std::setprecision(2) << m_range_searched /1.0e9 << " billion integers searched." <<
				" Found " << m_segmented_sieve->m_chain_count << " chain candidates. (" << chains_per_mm << " chains per million integers)" << std::endl;
			std::cout << "Avg chain length: " << std::fixed << std::setprecision(2) << 1.0 * m_segmented_sieve->m_chain_candidate_total_length / m_segmented_sieve->m_chain_count
				<< " Max chain: " << m_segmented_sieve->m_chain_candidate_max_length << std::endl;
			std::cout << "Fermat Tests: " << m_segmented_sieve->m_fermat_test_count << " Fermat Primes: " << m_segmented_sieve->m_fermat_prime_count <<
				" Fermat Positive Rate: " << std::fixed << std::setprecision(3) <<
				100.0 * fermat_positive_rate << "% Fermat tests per million integers sieved: " <<
				1.0e6 * m_segmented_sieve->m_fermat_test_count / m_range_searched << std::endl;

			std::cout << "Search rate: " << std::fixed << std::setprecision(1) << range_searched_this_cycle / (elapsed.count() * 1.0e3) << " million integers per second." << std::endl;
			double predicted_8chain_positivity_rate = std::pow(fermat_positive_rate, 8);
			//std::cout << "Predicted chains tested to find one Fermat 8-chains: " << 1 / predicted_8chain_positivity_rate << std::endl;
			//double predicted_days_between_8chains = 1.0 / (predicted_8chain_positivity_rate * chains_per_sec * 3600 * 24);
			//std::cout << "Predicted days between 8 chains per core: " << std::fixed << std::setprecision(2) << predicted_days_between_8chains << std::endl;
			std::cout << "Elapsed time: " << std::fixed << std::setprecision(2) << elapsed_ms / 1000.0 << "s. Sieving: " <<
				100.0 * sieving_ms / elapsed_ms << "% Chain filtering: " << 100.0 * find_chains_ms / elapsed_ms
				<< "% Fermat testing: " << 100.0 * test_chains_ms / elapsed_ms << "% Other: " <<
				100.0 * (elapsed_ms - (sieving_ms + find_chains_ms + test_chains_ms)) / elapsed_ms << "%" << std::endl;
			interval_start = std::chrono::steady_clock::now();
			std::cout << std::endl;
		}
	}
	m_segmented_sieve->gpu_sieve_free();
}

double Worker_prime::getDifficulty(uint1k p)
{
	std::vector<unsigned int> offsets_to_test;
	LLC::CBigNum prime_to_test = boost_uint1024_t_to_CBignum(p);
	double difficulty = m_prime_helper->GetPrimeDifficulty(prime_to_test, 1, offsets_to_test);
	return difficulty;
}

double Worker_prime::getNetworkDifficulty()
{
	return m_difficulty / 10000000.0;
}

bool Worker_prime::difficulty_check(uint1k p)
{
	return getDifficulty(p) >= getNetworkDifficulty();
}


LLC::CBigNum Worker_prime::boost_uint1024_t_to_CBignum(uint1k p)
{
	std::stringstream ss;
	ss << std::hex << p;
	std::string p_hex_str = ss.str();
	LLC::CBigNum p_CBignum;
	p_CBignum.SetHex(p_hex_str);
	return p_CBignum;
}

void Worker_prime::update_statistics(stats::Collector& stats_collector)
{
	auto prime_stats = std::get<stats::Prime>(stats_collector.get_worker_stats(m_config.m_internal_id));
	prime_stats.m_primes = m_segmented_sieve->m_fermat_prime_count;
	prime_stats.m_chains = m_segmented_sieve->m_chain_count;
	prime_stats.m_difficulty = m_difficulty;
	prime_stats.m_chain_histogram = m_segmented_sieve->m_chain_histogram;
	prime_stats.m_range_searched = m_range_searched;

	stats_collector.update_worker_stats(m_config.m_internal_id, prime_stats);

	m_primes = 0;
	m_chains = 0;
}



}
}