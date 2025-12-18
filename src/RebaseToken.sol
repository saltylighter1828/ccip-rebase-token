// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;
// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

import {
    ERC20
} from "../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {
    Ownable
} from "../lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {
    AccessControl
} from "../lib/openzeppelin-contracts/contracts/access/AccessControl.sol";

/**
 * @title RebaseToken
 * @author Antony Cheng
 * @notice This is a cross-chain rebase token that incentivises users to deposit into a vault and gain interest in rewards.
 * @notice The interest rate in the smart contract can only decrease
 * @notice Each user will have their own interest rate that is the global interest rate at the time of depsoiting.
 */

contract RebaseToken is ERC20, Ownable, AccessControl {
    error RebaseToken__InterestRateCanOnlyDecrease(
        uint256 currentInterestRate,
        uint256 newInterestRate
    );
    uint256 private constant PRECISION_FACTOR = 1e18;
    bytes32 private constant MINT_AND_BURN_ROLE =
        keccak256("MINT_AND_BURN_ROLE");
    uint256 private s_interestRate = (5e10); // need to refactor to fix truncation, this interest is actually interest per unit time (eg per second)
    mapping(address => uint256) private s_userInterestRate;
    mapping(address => uint256) private s_userLastUpdatedTimestamp;

    event InterestRateSet(uint256 newInterestRate);

    constructor() ERC20("Rebase Token", "RBT") Ownable(msg.sender) {}

    function grantMintAndBurnRole(address _account) external onlyOwner {
        _grantRole(MINT_AND_BURN_ROLE, _account); //one problem is that the owner could accidentally grant the role to themselves and then have too much power.
    }

    /**
     * @notice Sets the interest rate for the rebase token
     * @param _newInterestRate The new interest rate to be set
     * @dev The interest rate can only decrease
     */
    function setInterestRate(uint256 _newInterestRate) external onlyOwner {
        //Set the interest rate
        if (_newInterestRate >= s_interestRate) {
            revert RebaseToken__InterestRateCanOnlyDecrease(
                s_interestRate,
                _newInterestRate
            );
        }
        s_interestRate = _newInterestRate;
        emit InterestRateSet(_newInterestRate);
    }

    /**
     * @notice Gets the principle balance of the user (the amount of tokens that have been minted to the user), not including any interest that has accrued since the last time user interacted with the protocol.
     * @param _user The user to get the principle balance for
     * @return The principle balance of the user
     */
    function principleBalanceOf(address _user) external view returns (uint256) {
        return super.balanceOf(_user);
    }

    /**
     * @notice Mint new tokens to the user when they deposit into the vault
     * @param _to The user to mint the tokens to
     * @param _amount The amount of tokens to mint
     */
    function mint(
        address _to,
        uint256 _amount,
        uint256 _userInterestRate
    ) external onlyRole(MINT_AND_BURN_ROLE) {
        _mintAccruedInterest(_to); // Mint accrued interest before minting new tokens because the interest rate may have changed, if they want to mint more tokens.
        s_userInterestRate[_to] = _userInterestRate;
        _mint(_to, _amount); // don't need to use super because we are not overriding the _mint function, we are just calling the internal _mint function from ERC20
    }

    /**
     * @notice Burn the user tokens when they withdraw from the vault
     * @param _from The user to burn the tokens from
     * @param _amount The amount of tokens to burn
     */
    function burn(
        address _from,
        uint256 _amount
    ) external onlyRole(MINT_AND_BURN_ROLE) {
        _mintAccruedInterest(_from);
        _burn(_from, _amount);
    }

    /**
     * calculate the balance for the user including any interest that has accumulated since the last update
     * (principle balance) + some interest that has accrued
     * @param _user The user to calculate the balance for
     * @return The balance of the user including the interest that has accumulated since the last update
     */

    function balanceOf(address _user) public view override returns (uint256) {
        uint256 principal = super.balanceOf(_user);
        if (principal == 0) {
            return 0;
        }
        return
            (principal *
                _calculateUserAccumulatedInterestSinceLastUpdate(_user)) /
            PRECISION_FACTOR;
    } // there might be a bug where if the user burns a small amount of tokens, the user might end up with more tokens due to linear growth calculation rounding errors.

    /**
     * @notice Transfer tokens from one user to another
     * @param _recipient The recipient of the tokens
     * @param _amount The amount of tokens to transfer
     * @return bool success
     * @dev This function overrides the ERC20 transfer function to mint accrued interest before transferring tokens
     */
    function transfer(
        address _recipient,
        uint256 _amount
    ) public override returns (bool) {
        _mintAccruedInterest(msg.sender);
        _mintAccruedInterest(_recipient);
        if (_amount == type(uint256).max) {
            _amount = balanceOf(msg.sender);
        }
        if (balanceOf(_recipient) == 0) {
            s_userInterestRate[_recipient] = s_userInterestRate[msg.sender]; // just incase msg.sender is transferring all their tokens to their wallet
        } //There is a known design flaw. If wallet 1 with small amount of tokens with higher interest. Then wallet 2 with smaller interest with large amount sends to wallet 1. The user would still get the higher interest. But this is vice versa.
        return super.transfer(_recipient, _amount);
    }

    /**
     * @notice Transfer tokens from one user to another on behalf of the sender
     * @param _sender The sender of the tokens
     * @param _recipient The recipient of the tokens
     * @param _amount The amount of tokens to transfer
     * @return bool success
     * @dev This function overrides the ERC20 transferFrom function to mint accrued interest before transferring tokens
     */
    function transferFrom(
        address _sender,
        address _recipient,
        uint256 _amount
    ) public override returns (bool) {
        _mintAccruedInterest(_sender);
        _mintAccruedInterest(_recipient);
        if (_amount == type(uint256).max) {
            _amount = balanceOf(_sender);
        }
        if (balanceOf(_recipient) == 0) {
            s_userInterestRate[_recipient] = s_userInterestRate[_sender];
        }
        return super.transferFrom(_sender, _recipient, _amount);
    }

    /**
     * @notice Calculates the accumulated interest for a user since their last update
     * @param _user The user to calculate the interest for
     * @return linearInterest The accumulated interest for the user since their last update
     * @dev This function calculates the linear interest based on the time elapsed since the last update and the user's interest rate
     */
    function _calculateUserAccumulatedInterestSinceLastUpdate(
        address _user
    ) internal view returns (uint256 linearInterest) {
        // we need to calculate the time difference between now and the last updated timestamp
        // this is going to be linear growth with time
        //1. calculate the time since the last update
        //2. calculate the amount of linear growth
        //***principal amount(1+ (user interest rate * timpe elapsed  ))
        // deposit: 10 tokens
        // interest rate 0.5 tokens per second
        // time elapsed is 2 seconds
        //10 + (10 * 0.5 * 2) = 20 tokens
        uint256 timeElapsed = block.timestamp -
            s_userLastUpdatedTimestamp[_user];
        linearInterest = (PRECISION_FACTOR +
            (s_userInterestRate[_user] * timeElapsed));
    }
    /**
     * @notice Mints the accrued interest to the user since the last time they intereacted with the protocol
     * @param _user The user to mint the interest to
     * @dev This function calculates the accrued interest since the last update and mints the tokens to the user
     */
    function _mintAccruedInterest(address _user) internal {
        // 1. find their current balance of rebase token that have been minted to user -> principal balance
        uint256 previousPrincipleBalance = super.balanceOf(_user);
        // 2. calculate their current balance including any interest -> balanceOf
        uint256 currentBalance = balanceOf(_user);
        // calculate the number of tokens that need to be minted to the user. 2-1 = number of tokens to mint
        uint256 balanceIncrease = currentBalance - previousPrincipleBalance;
        // set the users last updated timestamp
        s_userLastUpdatedTimestamp[_user] = block.timestamp; //EFFECTS
        // call _mint (internal mint) to min the tokens to user - do this at the end to avoid reentrancy issues
        _mint(_user, balanceIncrease); //INTERACTIONS - there is already an event emitted in the _mint function
    }

    /**
     * @notice Gets the global interest rate that is currently set for the contract. Any future deposits will use this interest rate.
     * @return The global interest rate for the contract
     */
    function getInterestRate() external view returns (uint256) {
        return s_interestRate;
    }

    /**
     * @notice Gets the user interest rate for a specific user
     * @param _user The user to get the interest rate for
     * @dev The interest rate is stored for the user.
     */
    function getUserInterestRate(
        address _user
    ) external view returns (uint256) {
        return s_userInterestRate[_user];
    }
}
