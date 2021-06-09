#ifndef NEXUSMINER_STATS_COLLECTOR_HPP
#define NEXUSMINER_STATS_COLLECTOR_HPP

#include <memory>
#include <vector>
#include <variant>
#include <chrono>

namespace nexusminer {

class Config;

struct Stats_hash
{
    std::uint64_t m_hash_count{0};
    int m_best_leading_zeros{0};
    int m_met_difficulty_count{0};

    Stats_hash& operator+=(Stats_hash const& other)
    {
        m_hash_count += other.m_hash_count;
        m_best_leading_zeros += other.m_best_leading_zeros;
        m_met_difficulty_count += other.m_met_difficulty_count;

        return *this;
    }
};

struct Stats_prime
{
    Stats_prime& operator+=(Stats_prime const& other)
    {
        return *this;
    }
};

class Stats_collector {
public:

	Stats_collector(Config& config);

    void update_worker_stats(std::uint16_t internal_worker_id, Stats_hash const& stats);
    void update_worker_stats(std::uint16_t internal_worker_id, Stats_prime const& stats);

    void block_accpeted() { m_accepted_blocks++; }
    void block_rejected() { m_rejected_blocks++; }
    void connection_retry_attempt() { m_connection_retries++; }

private:

    Config& m_config;
    std::vector<std::variant<Stats_hash, Stats_prime>> m_workers;

    // global stats
    std::chrono::steady_clock::time_point m_start_time;
    std::uint32_t m_accepted_blocks;
    std::uint32_t m_rejected_blocks;
    std::uint32_t m_connection_retries;


};

}
#endif