// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface INadFunFactory {
    event PairCreated(address indexed token0, address indexed token1, address pair, uint256 pairCount);
    event FeeToUpdate(address indexed oldFeeTo, address indexed newFeeTo);
    event ImplementationUpdate(address indexed oldImplementation, address indexed newImplementation);

    function feeTo() external view returns (address);
    function protocolManager() external view returns (address);
    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function allPairs(uint256 index) external view returns (address pair);
    function allPairsLength() external view returns (uint256);
    function createPair(address tokenA, address tokenB) external returns (address pair);
    function setFeeTo(address) external;
    function feeCollector() external view returns (address);
    function implementation() external view returns (address);
    function setImplementation(address) external;
}
