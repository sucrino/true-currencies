// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.6.10;

import {TrueCoinReceiver} from "./TrueCoinReceiver.sol";
import {TrueRewards} from "../truereward/TrueRewards.sol";
import {CompliantDepositTokenWithHook} from "./CompliantDepositTokenWithHook.sol";

/**
 * @title TrueRewardBackedToken
 * @dev TrueRewardBackedToken is TrueCurrency backed by debt
 *
 * -- Overview --
 * Enabling TrueRewards deposits TrueCurrency into a financial opportunity
 * Financial opportunities provide awards over time
 * Awards are reflected in the wallet balance updated block-by-block
 *
 * -- rewardToken vs yToken --
 * rewardToken represents an amount of ASSURED TrueCurrency owed to the rewardToken holder
 * yToken represents an amount of NON-ASSURED TrueCurrency owed to a yToken holder
 * For this contract, we only handle rewardToken (Assured Opportunities)
 *
 * -- Calculating rewardToken --
 * TrueCurrency Value = rewardToken * financial opportunity tokenValue()
 *
 * -- rewardToken Assumptions --
 * We assume tokenValue never decreases for assured financial opportunities
 * rewardToken is not transferable in that the token itself is never transferred
 * Rather, we override our transfer functions to account for user balances
 *
 * -- Reserve --
 * This contract uses a reserve holding of TrueCurrency and rewardToken to save on gas costs
 * because calling the financial opportunity deposit() and redeem() every time
 * can be expensive
 * See RewardTokenWithReserve.sol
 *
 * -- Future Upgrades to Financial Opportunity --
 * Currently, we only have a single financial opportunity
 * We plan on upgrading this contract to support a multiple financial opportunity,
 * so some of the code is built to support this
 *
 */
abstract contract TrueRewardBackedToken is CompliantDepositTokenWithHook {
    /* variables in Proxy Storage:
    mapping(address => FinancialOpportunity) finOps;
    mapping(address => mapping(address => uint256)) finOpBalances;
    mapping(address => uint256) finOpSupply;
    uint256 maxRewardProportion = 1000;
    */

    // registry attribute for whitelist
    // 0x6973547275655265776172647357686974656c69737465640000000000000000
    bytes32 constant IS_TRUEREWARDS_WHITELISTED = "isTrueRewardsWhitelisted";

    // trueRewards token address
    address public trueRewards;

    mapping(address => bool) isTrueRewardsEnabled;

    /// @dev Emitted when true reward was enabled for _account with balance _amount for Financial Opportunity _finOp
    event TrueRewardEnabled(address indexed _account, uint256 _amount);
    /// @dev Emitted when true reward was disabled for _account with balance _amount for Financial Opportunity _finOp
    event TrueRewardDisabled(address indexed _account, uint256 _amount);

    /** @dev return true if TrueReward is enabled for a given address */
    function trueRewardEnabled(address _address) public view returns (bool) {
        return isTrueRewardsEnabled[_address];
    }

    /**
     * @dev Get total supply of all TrueCurrency
     * Equal to deposit backed TrueCurrency plus debt backed TrueCurrency
     * @return total supply in trueCurrency
     */
    function totalSupply() public virtual override view returns (uint256) {
        // supply of deposits + debt
        return totalSupply_.add(TrueRewards(trueRewards).totalSupply());
    }

    /**
     * @dev Get balance of TrueCurrency including rewards for an address
     *
     * @param _who address of account to get balanceOf for
     * @return balance total balance of address including rewards
     */
    function balanceOf(address _who) public virtual override view returns (uint256) {
        // if trueReward enabled, return token value of reward balance
        // otherwise call token balanceOf
        if (trueRewardEnabled(_who)) {
            return TrueRewards(trueRewards).getBalance(_who);
        }
        return super.balanceOf(_who);
    }

    /**
     * @dev Enable TrueReward and deposit user balance into opportunity.
     * Currently supports a single financial opportunity
     */
    function enableTrueReward() external {
        // require TrueReward is not enabled
        require(registry.hasAttribute(msg.sender, IS_TRUEREWARDS_WHITELISTED), "must be whitelisted to enable TrueRewards");
        require(!trueRewardEnabled(msg.sender), "TrueReward already enabled");

        // get sender balance
        uint256 balance = _getBalance(msg.sender);

        if (balance != 0) {
            // deposit entire user token balance
            makeDeposit(msg.sender, balance);
        }

        isTrueRewardsEnabled[msg.sender] = true;

        // emit enable event
        emit TrueRewardEnabled(msg.sender, balance);
    }

    /**
     * @dev Disable TrueReward and withdraw user balance from opportunity.
     */
    function disableTrueReward() external {
        // require TrueReward is enabled
        require(trueRewardEnabled(msg.sender), "TrueReward already disabled");

        uint256 balance = balanceOf(msg.sender);

        if (balance > 0) {
            // redeem entire user reward token balance
            TrueRewards(trueRewards).redeemAll(msg.sender);
        }

        isTrueRewardsEnabled[msg.sender] = false;

        // emit disable event
        emit TrueRewardDisabled(msg.sender, balance);
    }

    /**
     * @dev mint function for TrueRewardBackedToken
     * Mints TrueCurrency backed by debt
     * When we add multiple opportunities, this needs to work for multiple interfaces
     */
    function mint(address _to, uint256 _value) public virtual override onlyOwner {
        // check if to address is enabled
        bool toEnabled = trueRewardEnabled(_to);

        // if to enabled, mint to this contract and deposit into finOp
        if (toEnabled) {
            // mint to trueRewards contract
            super.mint(trueRewards, _value);
            // deposit minted amount to opportunities
            TrueRewards(trueRewards).deposit(msg.sender, _value);
        } else {
            // otherwise call normal mint process
            super.mint(_to, _value);
        }
    }

    /**
     * @dev set a new trueRewards address
     * @param _trueRewards new address to set
     */
    function setTrueRewardsAddress(address _trueRewards) external onlyOwner {
        require(_trueRewards != address(0), "attempt to set address to 0");
        require(_trueRewards != trueRewards, "attempt to change address to the same one");
        trueRewards = _trueRewards;
    }

    /**
     * @dev Transfer helper function for TrueRewardBackedToken
     *
     * Uses trueRewardEnabled flag to check whether accounts have opted in
     * If are have opted out, call parent transferFrom, otherwise:
     * 1. If sender opted in, redeem reward tokens for true currency
     * 2. Call transferFrom, using deposit balance for transfer
     * 3. If receiver enabled, deposit true currency into
     */
    function _transferAllArgs(
        address _from,
        address _to,
        uint256 _value
    ) internal virtual override returns (address) {
        // get enabled flags and opportunity address
        bool fromEnabled = trueRewardEnabled(_from);
        bool toEnabled = trueRewardEnabled(_to);

        // if both disabled or either is opportunity, transfer normally
        if ((!fromEnabled && !toEnabled) || _from == trueRewards || _to == trueRewards) {
            require(super.balanceOf(_from) >= _value, "not enough balance");
            return super._transferAllArgs(_from, _to, _value);
        }

        // check balance for from address
        require(balanceOf(_from) >= _value, "not enough balance");

        // if from enabled, check balance, calculate reward amount, and redeem
        if (fromEnabled) {
            TrueRewards(trueRewards).redeem(_from, _value);
        }

        // transfer tokens
        address finalTo = super._transferAllArgs(_from, _to, _value);

        // if receiver enabled, deposit tokens into opportunity
        if (trueRewardEnabled(finalTo)) {
            makeDeposit(finalTo, _value);
        }

        return finalTo;
    }

    /**
     * @dev TransferFrom helper function for TrueRewardBackedToken
     *
     * Uses trueRewardEnabled flag to check whether accounts have opted in
     * If are have opted out, call parent transferFrom, otherwise:
     * 1. If sender opted in, redeem reward tokens for true currency
     * 2. Call transferFrom, using deposit balance for transfer
     * 3. If receiver enabled, deposit true currency into
     */
    function _transferFromAllArgs(
        address _from,
        address _to,
        uint256 _value,
        address _spender
    ) internal virtual override returns (address) {
        // get enabled flags and opportunity address
        bool fromEnabled = trueRewardEnabled(_from);
        bool toEnabled = trueRewardEnabled(_to);

        // if both disabled or either is trueRewards, transfer normally
        if ((!fromEnabled && !toEnabled) || _from == trueRewards || _to == trueRewards) {
            require(super.balanceOf(_from) >= _value, "not enough balance");
            return super._transferFromAllArgs(_from, _to, _value, _spender);
        }

        // check balance for from address
        require(balanceOf(_from) >= _value, "not enough balance");

        // if from enabled, check balance, calculate reward amount, and redeem
        if (fromEnabled) {
            TrueRewards(trueRewards).redeem(_from, _value);
        }

        // transfer tokens
        address finalTo = super._transferFromAllArgs(_from, _to, _value, _spender);

        // if receiver enabled, deposit tokens into opportunity
        if (trueRewardEnabled(finalTo)) {
            makeDeposit(finalTo, _value);
        }

        return finalTo;
    }

    function makeDeposit(address account, uint256 amount) internal {
        super._transferAllArgs(account, trueRewards, amount);
        TrueRewards(trueRewards).deposit(account, amount);
    }
}
