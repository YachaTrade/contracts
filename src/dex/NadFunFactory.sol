// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {INadFunFactory} from "./interfaces/INadFunFactory.sol";
import {NadFunPair} from "./NadFunPair.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";

contract NadFunFactory is INadFunFactory {
    address public feeTo;
    address public protocolManager;
    address public feeCollector;
    address public implementation;

    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;

    error IdenticalAddresses();
    error ZeroAddress();
    error PairExists();
    error Forbidden();

    constructor(address _protocolManager, address _feeCollector, address _implementation) {
        protocolManager = _protocolManager;
        feeCollector = _feeCollector;
        implementation = _implementation;
    }

    function allPairsLength() external view returns (uint256) {
        return allPairs.length;
    }

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        if (tokenA == tokenB) revert IdenticalAddresses();
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        if (token0 == address(0)) revert ZeroAddress();
        if (getPair[token0][token1] != address(0)) revert PairExists();

        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        pair = Clones.cloneDeterministic(implementation, salt);

        NadFunPair(pair).initialize(address(this), token0, token1, feeCollector);

        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair;
        allPairs.push(pair);

        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    function setImplementation(address _implementation) external {
        if (msg.sender != protocolManager) revert Forbidden();
        if (_implementation == address(0)) revert ZeroAddress();
        address oldImplementation = implementation;
        implementation = _implementation;
        emit ImplementationUpdate(oldImplementation, _implementation);
    }

    function setFeeTo(address _feeTo) external {
        if (msg.sender != protocolManager) revert Forbidden();
        address oldFeeTo = feeTo;
        feeTo = _feeTo;
        emit FeeToUpdate(oldFeeTo, _feeTo);
    }
}
