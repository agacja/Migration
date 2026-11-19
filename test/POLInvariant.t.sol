// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ActionPermissionSetup} from "./ActionPermissionSetup.sol";

import {Test} from "forge-std/Test.sol";
import {BaseTest} from "./Base.t.sol";
import {POLHolder} from "../src/pol/POLHolder.sol";
import {LoC} from "../src/loc/LoC.sol";
import {ILoC} from "../src/interfaces/ILoC.sol";
import {MockERC20, MockRouter} from "./Mocks.sol";

contract POLHarness is BaseTest {
    LoC public polLoC;
    MockERC20 public rwd;
    POLHolder.Action[] internal none;

    uint128 public constant RATE = 1 ether;

    function init() external {
        polLoC = _createLoC(address(pol), 100_000_000 ether, 10_000_000 ether, 50_000_000 ether, 0);
        pol.setLoC(ILoC(address(polLoC)));
        pol.setRates(RATE, 0);
        pol.setDrawLimits(10_000_000 ether, 50_000_000 ether, 100_000_000 ether);
        pol.setAllowedAsset(address(usdc), true);
        pol.setAllowedAsset(address(wsteth), true);
        pol.setAssetEntry(address(usdc), 5000, 100, POLHolder.RewardMode.OUTRIGHT);
        pol.setAssetEntry(address(wsteth), 5000, 100, POLHolder.RewardMode.COMPOUNDING);
        pol.setStable(address(usdc), true);
        ActionPermissionSetup.allowRouter(address(pol), address(router));

        rwd = new MockERC20("Reward", "RWD", 18);
        assetOracle.setPrice(address(rwd), 5e8);
        pol.setRewardToken(address(rwd), true);

        vm.prank(DAO);
        alb.addMinter(address(router));
        _warmOracle();

        pol.setRates(0, 0);
        vm.prank(KEEPER);
        pol.maintain(none, none);
        pol.setRates(RATE, 0);
    }

    function polC() external view returns (POLHolder) { return pol; }
    function routerC() external view returns (MockRouter) { return router; }
    function albC() external view returns (address) { return address(alb); }
    function usdcC() external view returns (address) { return address(usdc); }
    function wstethC() external view returns (address) { return address(wsteth); }
    function rwdC() external view returns (address) { return address(rwd); }
    function keeperC() external view returns (address) { return KEEPER; }
    function warp(uint256 s) external { _skip(s); twap.touch(); }
}

contract POLHandler is Test {
    POLHarness internal h;
    POLHolder internal pol;
    MockRouter internal router;
    address internal alb;
    address internal usdc;
    address internal wsteth;
    address internal rwd;
    address internal keeper;

    uint256 public callsAttempted;
    uint256 public callsSucceeded;

    constructor(POLHarness h_) {
        h = h_;
        pol = h.polC();
        router = h.routerC();
        alb = h.albC();
        usdc = h.usdcC();
        wsteth = h.wstethC();
        rwd = h.rwdC();
        keeper = h.keeperC();
    }

    function _swap(address tIn, uint256 aIn, address tOut, uint256 aOut)
        internal view returns (POLHolder.Action memory a)
    {
        a.target = address(router);
        a.data = abi.encodeCall(MockRouter.swap, (tIn, aIn, tOut, aOut));
        a.approveToken = tIn;
        a.approveSpender = address(router);
        a.approveAmount = aIn;
    }

    function maintainHonest(uint32 dt) public {
        uint256 elapsed = uint256(dt) % 7 days + 1;
        h.warp(elapsed);
        uint256 draw = uint256(h.RATE()) * elapsed;
        uint256 half = draw / 2;
        POLHolder.Action[] memory acts = new POLHolder.Action[](2);
        acts[0] = _swap(alb, half, usdc, half / 1e12);
        acts[1] = _swap(alb, draw - half, wsteth, half / 3000);
        POLHolder.Action[] memory none;
        callsAttempted++;
        vm.prank(keeper);
        try pol.maintain(none, acts) { callsSucceeded++; } catch {}
    }

    function maintainHostile(uint32 dt, uint8 mode, uint96 amt) public {
        uint256 elapsed = uint256(dt) % 7 days + 1;
        h.warp(elapsed);
        uint256 draw = uint256(h.RATE()) * elapsed;
        uint256 a = uint256(amt) % (draw + 1);

        POLHolder.Action[] memory acts = new POLHolder.Action[](1);
        uint8 m = mode % 4;
        if (m == 0) {
            acts[0].target = address(router);
            acts[0].data = abi.encodeCall(MockRouter.steal, (alb, a, address(0xBEEF)));
            acts[0].approveToken = alb;
            acts[0].approveSpender = address(router);
            acts[0].approveAmount = a;
        } else if (m == 1) {
            acts[0] = _swap(alb, a, usdc, 1);
        } else if (m == 2) {
            acts[0].target = address(router);
            acts[0].data = abi.encodeCall(MockRouter.claimRewards, (rwd, a));
        } else {
            acts[0].target = address(router);
            acts[0].data = abi.encodeCall(MockRouter.steal, (usdc, a, address(0xBEEF)));
            acts[0].approveToken = usdc;
            acts[0].approveSpender = address(router);
            acts[0].approveAmount = a;
        }
        POLHolder.Action[] memory none;
        callsAttempted++;
        vm.prank(keeper);
        try pol.maintain(none, acts) { callsSucceeded++; } catch {}
    }

    function maintainHarvest(uint32 dt, uint8 mode, uint96 amt) public {
        h.warp(uint256(dt) % 3 days + 1);
        uint256 a = uint256(amt) % 1000 ether + 1;
        POLHolder.Action[] memory acts = new POLHolder.Action[](mode % 2 == 0 ? 1 : 2);
        acts[0].target = address(router);
        acts[0].data = abi.encodeCall(MockRouter.claimRewards, (rwd, a));
        if (acts.length == 2) {
            acts[1].target = address(router);
            acts[1].data = abi.encodeCall(MockRouter.steal, (rwd, a, address(0xBEEF)));
            acts[1].approveToken = rwd;
            acts[1].approveSpender = address(router);
            acts[1].approveAmount = a;
        }
        POLHolder.Action[] memory none;
        callsAttempted++;
        vm.prank(keeper);
        try pol.maintain(acts, none) { callsSucceeded++; } catch {}
    }
}

contract POLInvariantTest is Test {
    POLHarness internal h;
    POLHandler internal handler;

    function setUp() public {
        h = new POLHarness();
        h.setUp();
        h.init();
        handler = new POLHandler(h);
        targetContract(address(handler));
    }

    function invariant_noResidualAllowances() public view {
        POLHolder pol = h.polC();
        address spender = address(h.routerC());
        address[4] memory toks = [h.albC(), h.usdcC(), h.wstethC(), h.rwdC()];
        for (uint256 i; i < toks.length; ++i) {
            assertEq(
                MockERC20(toks[i]).allowance(address(pol), spender),
                0,
                "residual allowance after operator action"
            );
        }
    }

    function invariant_drawnDebtNeverExceedsLifetimeDraws() public view {
        POLHolder pol = h.polC();
        assertLe(h.polLoC().drawnAmount(), pol.totalDrawn(), "debt exceeds what was ever drawn");
    }

    function invariant_totalDrawnUnderCap() public view {
        POLHolder pol = h.polC();
        assertLe(pol.totalDrawn(), pol.maxTotalDraw(), "lifetime draw cap breached");
    }
}
