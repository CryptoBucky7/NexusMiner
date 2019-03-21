/*__________________________________________________________________________________________

            (c) Hash(BEGIN(Satoshi[2010]), END(Sunny[2012])) == Videlicet[2014] ++

            (c) Copyright The Nexus Developers 2014 - 2019

            Distributed under the MIT software license, see the accompanying
            file COPYING or http://www.opensource.org/licenses/mit-license.php.

            "ad vocem populi" - To the Voice of the People

____________________________________________________________________________________________*/

#pragma once
#ifndef NEXUS_UTIL_PRIME_CONFIG_H
#define NEXUS_UTIL_PRIME_CONFIG_H

#include <cstdint>
#include <vector>
#include <CUDA/include/util.h>

extern uint64_t base_offset;
extern std::vector<uint32_t> offsetsTest;
extern std::vector<uint32_t> offsetsA;
extern std::vector<uint32_t> offsetsB;

extern uint32_t nSievePrimeLimit;
extern uint32_t nSievePrimesLog2[GPU_MAX];
extern uint32_t nSieveBitsLog2[GPU_MAX];
extern uint32_t nSieveIterationsLog2[GPU_MAX];
extern uint32_t  nTestLevels[GPU_MAX];

namespace prime
{
    void load_offsets();
    void load_config(uint8_t nThreadsGPU);
}

#endif
