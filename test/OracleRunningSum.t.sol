// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BaseTest} from "./Base.t.sol";
import {AlbPriceOracle} from "../src/oracle/AlbPriceOracle.sol";

contract OracleRunningSumRegression is BaseTest {
    uint256 constant SAMPLES = 20;

    function _manualSum() internal view returns (uint256 s) {
        for (uint256 i; i < SAMPLES; ++i) s += oracle.buffer(i);
    }

    function _check() internal view {
        assertEq(oracle.bufferSum(), _manualSum(), "bufferSum drifted from the buffer");
        uint256 c = oracle.count();
        for (uint256 i = c; i < SAMPLES; ++i) assertEq(oracle.buffer(i), 0, "tail slot not zero");
        if (c == SAMPLES && oracle.distinctDays() == SAMPLES) {
            assertEq(oracle.sma20(), _manualSum() / SAMPLES, "sma20 != manual average");
        }
    }

    function testFuzz_runningSumIsExact(uint256 seed) public {
        uint256 t = block.timestamp;
        for (uint256 step; step < 80; ++step) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));

            uint256 gapHours = (r % 7 == 0) ? 24 * (1 + (r >> 8) % 45) : 1 + (r >> 8) % 30;
            t += gapHours * 1 hours;
            vm.warp(t);

            uint256 p = twap.consult();
            uint256 bps = 6_000 + (r >> 64) % 8_001;
            p = (p * bps) / 10_000;
            if (p < 1e4) p = 1e4;
            twap.setPrice(p);
            oracle.poke();
            _check();
        }
    }

    function test_runningSumSurvivesRepeatedPurges() public {
        _warmOracle();
        _check();
        assertEq(oracle.count(), SAMPLES);
        _skip(5 days); twap.touch(); oracle.poke();
        _check();
        assertEq(oracle.count(), 1, "long gap starts a fresh window");
        _skip(60 days); twap.touch(); oracle.poke();
        _check();
        _warmOracle();
        _check();
        assertEq(oracle.sma20(), 1e8);
    }
}
