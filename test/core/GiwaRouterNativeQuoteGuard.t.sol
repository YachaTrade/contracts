// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {SetUp} from "../SetUp.t.sol";
import {IBondingCurve} from "../../src/interfaces/IBondingCurve.sol";
import {IGiwaRouter} from "../../src/interfaces/IGiwaRouter.sol";
import {ITokenRegistry} from "../../src/interfaces/ITokenRegistry.sol";
import {GiwaRouter} from "../../src/router/GiwaRouter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockWMON} from "../mocks/MockWMON.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract GiwaRouterNativeQuoteGuardTest is SetUp {
    MockERC20 internal usdc;
    address internal foreignQuoteToken;

    function setUp() public override {
        super.setUp();

        usdc = new MockERC20("USD Coin", "USDC", 6);
        wmon = new MockWMON();

        vm.startPrank(admin);
        protocolManager.addQuoteToken(address(usdc), 15_000e6, 1_000_000_000 ether, 800_000_000 ether, 0, 0, 0, 0, 0);
        bondingCurve.grantRole(bondingCurve.ROUTER_ROLE(), address(this));

        GiwaRouter routerImpl = new GiwaRouter();
        giwaRouter = GiwaRouter(
            payable(address(
                    new ERC1967Proxy(
                        address(routerImpl),
                        abi.encodeCall(
                            GiwaRouter.initialize,
                            (
                                address(protocolManager),
                                address(bondingCurve),
                                address(tokenRegistry),
                                address(wmon),
                                address(v3SwapAdapter),
                                address(quoterV2)
                            )
                        )
                    )
                ))
        );
        vm.stopPrank();

        usdc.mint(address(this), 100e6);
        usdc.transfer(address(bondingCurve), 100e6);
        (foreignQuoteToken,) = bondingCurve.create(_usdcCurveParams());
    }

    function test_buyWithNative_revertsForForeignQuoteToken() public {
        vm.deal(user1, 1 ether);

        vm.prank(user1);
        vm.expectRevert(IGiwaRouter.InvalidNativeQuoteToken.selector);
        giwaRouter.buyWithNative{value: 1 ether}(
            IGiwaRouter.BuyWithNativeParams({
                amountOutMin: 0, token: foreignQuoteToken, to: user1, deadline: block.timestamp + 1
            })
        );
    }

    function test_exactOutBuyWithNative_revertsForForeignQuoteToken() public {
        vm.deal(user1, 1 ether);

        vm.prank(user1);
        vm.expectRevert(IGiwaRouter.InvalidNativeQuoteToken.selector);
        giwaRouter.exactOutBuyWithNative{value: 1 ether}(
            IGiwaRouter.ExactOutBuyWithNativeParams({
                amountOut: 1 ether, token: foreignQuoteToken, to: user1, deadline: block.timestamp + 1
            })
        );
    }

    function test_sellToNative_revertsForForeignQuoteTokenBeforeTransfer() public {
        vm.prank(user1);
        vm.expectRevert(IGiwaRouter.InvalidNativeQuoteToken.selector);
        giwaRouter.sellToNative(
            IGiwaRouter.SellToNativeParams({
                amountIn: 1 ether, amountOutMin: 0, token: foreignQuoteToken, to: user1, deadline: block.timestamp + 1
            })
        );
    }

    function test_sellToNativeWithPermit_revertsForForeignQuoteTokenBeforePermit() public {
        vm.prank(user1);
        vm.expectRevert(IGiwaRouter.InvalidNativeQuoteToken.selector);
        giwaRouter.sellToNativeWithPermit(
            IGiwaRouter.SellToNativeWithPermitParams({
                amountIn: 1 ether,
                amountOutMin: 0,
                amountAllowance: 1 ether,
                token: foreignQuoteToken,
                to: user1,
                deadline: block.timestamp + 1,
                v: 27,
                r: bytes32(0),
                s: bytes32(0)
            })
        );
    }

    function test_exactOutSellToNative_revertsForForeignQuoteTokenBeforeTransfer() public {
        vm.prank(user1);
        vm.expectRevert(IGiwaRouter.InvalidNativeQuoteToken.selector);
        giwaRouter.exactOutSellToNative(
            IGiwaRouter.ExactOutSellToNativeParams({
                amountInMax: 1 ether, amountOut: 1, token: foreignQuoteToken, to: user1, deadline: block.timestamp + 1
            })
        );
    }

    function _usdcCurveParams() internal view returns (IBondingCurve.CreateTokenParams memory params) {
        IBondingCurve.VaultAllocation[] memory vaults = new IBondingCurve.VaultAllocation[](1);
        vaults[0] = IBondingCurve.VaultAllocation({
            vault: address(creatorFeeVault), bps: 10_000, setupData: abi.encode(feeReceiver)
        });

        params = IBondingCurve.CreateTokenParams({
            name: "ForeignQuote",
            symbol: "FQ",
            tokenURI: "",
            quoteToken: address(usdc),
            creatorFeeRate: 100,
            vaults: vaults,
            salt: keccak256("foreign-quote-native-buy-guard"),
            dexType: ITokenRegistry.DexType.UniswapV2,
            creator: creator,
            buyQuoteAmount: 0
        });
    }
}
