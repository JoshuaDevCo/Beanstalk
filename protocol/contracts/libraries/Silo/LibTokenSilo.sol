/**
 * SPDX-License-Identifier: MIT
 **/

pragma solidity =0.7.6;
pragma experimental ABIEncoderV2;

import {SafeMath} from "@openzeppelin/contracts/math/SafeMath.sol";
import "../LibAppStorage.sol";
import "../../C.sol";
import "./LibUnripeSilo.sol";
import "./LibLegacyTokenSilo.sol";
import "~/libraries/LibSafeMathSigned128.sol";
import "~/libraries/LibSafeMathSigned96.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/SafeCast.sol";
import "~/libraries/LibBytes.sol";
import "hardhat/console.sol";

/**
 * @title LibTokenSilo
 * @author Publius
 * @notice Contains functions for depositing, withdrawing and claiming
 * whitelisted Silo tokens.
 *
 * For functionality related to Stalk, and Roots, see {LibSilo}.
 */
library LibTokenSilo {
    using SafeMath for uint256;
    using SafeMath for uint128;
    using SafeMath for int128;
    using SafeMath for uint32;
    using LibSafeMathSigned128 for int128;
    using SafeCast for int128;
    using SafeCast for uint256;
    using LibSafeMathSigned96 for int96;

    //////////////////////// EVENTS ////////////////////////

    /**
     * @dev IMPORTANT: copy of {TokenSilo-AddDeposit}, check there for details.
     */
    event AddDeposit(
        address indexed account,
        address indexed token,
        int96 grownStalkPerBdv,
        uint256 amount,
        uint256 bdv
    );

    // added as the ERC1155 deposit upgrade
    event TransferSingle(
        address indexed operator, 
        address indexed sender, 
        address indexed recipient, 
        uint256 depositId, 
        uint256 amount
    );


    //////////////////////// ACCOUNTING: TOTALS ////////////////////////
    
    /**
     * @dev Increment the total amount of `token` deposited in the Silo.
     */
    // TODO: should we have an ERC721 + ERC1155 equlivant, or should we update silo balance mapping?
    function incrementTotalDeposited(address token, uint256 amount) internal {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.siloBalances[token].deposited = s.siloBalances[token].deposited.add(
            amount
        );
    }

    /**
     * @dev Decrement the total amount of `token` deposited in the Silo.
     */
    function decrementTotalDeposited(address token, uint256 amount) internal {
        AppStorage storage s = LibAppStorage.diamondStorage();
        s.siloBalances[token].deposited = s.siloBalances[token].deposited.sub(
            amount
        );
    }

    //////////////////////// ADD DEPOSIT ////////////////////////

    /**
     * @return stalk The amount of Stalk received for this Deposit.
     * 
     * @dev Calculate the current BDV for `amount` of `token`, then perform 
     * Deposit accounting.
     */
    /**
     * TODO: should this be generalized for any token standard (ERC20 + ERC721 + ERC1155), or
     * should we have separate functions for each?
     */ 
    function deposit(
        address account,
        address token,
        int96 grownStalkPerBdv,
        uint256 amount
    ) internal returns (uint256) {
        console.log('do a deposit, account: ', account);
        console.log('deposit token: ', token);
        console.log('deposit logging grown stalk per bdv:');
        console.logInt(grownStalkPerBdv);
        console.log('deposit amount: ', amount);
        uint256 bdv = beanDenominatedValue(token, amount);
        return depositWithBDV(account, token, grownStalkPerBdv, amount, bdv);
    }

    /**
     * @dev Once the BDV received for Depositing `amount` of `token` is known, 
     * add a Deposit for `account` and update the total amount Deposited.
     *
     * `s.ss[token].stalkIssuedPerBdv` stores the number of Stalk per BDV for `token`.
     *
     * FIXME(discuss): If we think of Deposits like 1155s, we might call the
     * combination of "incrementTotalDeposited" and "addDepositToAccount" as 
     * "minting a deposit".
     */
    function depositWithBDV(
        address account,
        address token,
        int96 grownStalkPerBdv,
        uint256 amount,
        uint256 bdv
    ) internal returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        require(bdv > 0, "Silo: No Beans under Token.");
        console.log('depositWithBDV grownStalkPerBdv: ', uint256(grownStalkPerBdv));
        console.logInt(grownStalkPerBdv);
        incrementTotalDeposited(token, amount); // Update Totals

        // Pack the Deposit data into a single bytes32
        bytes32 depositData = LibBytes.packAddressAndCumulativeStalkPerBDV(
            token,
            grownStalkPerBdv
        );
        addDepositToAccount(account, depositData, amount, bdv); // Add to Account

        return (
            bdv.mul(s.ss[token].stalkIssuedPerBdv) //formerly stalk
        );
    }

    /**
     * @dev Add `amount` of `token` to a user's Deposit in `cumulativeGrownStalkPerBdv`. Requires a
     * precalculated `bdv`.
     *
     * If a Deposit doesn't yet exist, one is created. Otherwise, the existing
     * Deposit is updated.
     * 
     * `amount` & `bdv` are cast uint256 -> uint128 to optimize storage cost,
     * since both values can be packed into one slot.
     * 
     * Unlike {removeDepositFromAccount}, this function DOES EMIT an 
     * {AddDeposit} event. See {removeDepositFromAccount} for more details.
     */
    function addDepositToAccount(
        address account,
        bytes32 depositId,
        uint256 amount,
        uint256 bdv
    ) internal {
        AppStorage storage s = LibAppStorage.diamondStorage();
        
        // create memory var to save gas (TODO: check if this is actually saving gas)
        Account.Deposit memory d = s.a[account].deposits[depositId];

        // add amount to the deposits... 
        d.amount = uint128(d.amount.add(amount.toUint128()));
        d.bdv = uint128(d.bdv.add(bdv.toUint128()));
        
        // set it 
        s.a[account].deposits[depositId] = d;
        
        // get token and GSPBDV of the depositData, for updating mow status and emitting event 
        (address token, int96 grownStalkPerBdv) = LibBytes.getAddressAndCumulativeStalkPerBDVFromBytes(depositId);

        // update the mow status (note: mow status is per token, not per depositId)
        s.a[account].mowStatuses[token].bdv = uint128(s.a[account].mowStatuses[token].bdv.add(bdv.toUint128()));
        //needs to update the mow status

        // "adding" a deposit is equivalent to "minting" an ERC1155 token. 
        emit TransferSingle(msg.sender, address(0), account, uint256(depositId), amount);
        emit AddDeposit(account, token, grownStalkPerBdv, amount, bdv);
    }

    //////////////////////// REMOVE DEPOSIT ////////////////////////

    /**
     * @dev Remove `amount` of `token` from a user's Deposit in `grownStalkPerBdv`.
     *
     * A "Crate" refers to the existing Deposit in storage at:
     *  `s.a[account].deposits[token][grownStalkPerBdv]`
     *
     * Partially removing a Deposit should scale its BDV proportionally. For ex.
     * removing 80% of the tokens from a Deposit should reduce its BDV by 80%.
     *
     * During an update, `amount` & `bdv` are cast uint256 -> uint128 to
     * optimize storage cost, since both values can be packed into one slot.
     *
     * This function DOES **NOT** EMIT a {RemoveDeposit} event. This
     * asymmetry occurs because {removeDepositFromAccount} is called in a loop
     * in places where multiple deposits are removed simultaneously, including
     * {TokenSilo-removeDepositsFromAccount} and {TokenSilo-_transferDeposits}.
     */
    function removeDepositFromAccount(
        address account,
        address token,
        int96 grownStalkPerBdv,
        uint256 amount
    ) internal returns (uint256 crateBDV) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        bytes32 depositId = LibBytes.packAddressAndCumulativeStalkPerBDV(token,grownStalkPerBdv);
        Account.Deposit memory d = s.a[account].deposits[depositId];
        
        uint256 crateAmount;
        (crateAmount, crateBDV) = (d.amount,d.bdv);

        // Partial remove
        if (amount < crateAmount) {
            uint256 removedBDV = amount.mul(crateBDV).div(crateAmount);
            uint256 updatedBDV = crateBDV.sub(removedBDV);
            uint256 updatedAmount = crateAmount.sub(amount);
                
            require(
                updatedBDV <= uint128(-1) && updatedAmount <= uint128(-1), //this code was here before, but maybe there's a better way to do this?
                "Silo: uint128 overflow."
            );

            s.a[account].deposits[depositId].amount = uint128(updatedAmount);
            s.a[account].deposits[depositId].bdv = uint128(updatedBDV);
            //remove from the mow status bdv amount, which keeps track of total token deposited per farmer
            s.a[account].mowStatuses[token].bdv = uint128(s.a[account].mowStatuses[token].bdv.sub(removedBDV));
            return removedBDV;
        }
        // Full remove
        if (crateAmount > 0) delete s.a[account].deposits[depositId];

        // Excess remove
        // This can only occur for Unripe Beans and Unripe LP Tokens, and is a
        // result of using Silo V1 storage slots to store Unripe BEAN/LP
        // Deposit information. See {AppStorage.sol:Account-State}.
        // This is now handled by LibLegacyTokenSilo.
        
        uint256 originalCrateBDV = crateBDV;

        if (amount > crateAmount) {
            uint256 seedsPerToken = LibLegacyTokenSilo.getSeedsPerToken(token);
            require(LibLegacyTokenSilo.isDepositSeason(seedsPerToken, grownStalkPerBdv), "Must line up with season");
            amount -= crateAmount;
            uint32 season = LibLegacyTokenSilo.grownStalkPerBdvToSeason(seedsPerToken, grownStalkPerBdv);
            crateBDV = crateBDV.add(LibLegacyTokenSilo.removeDepositFromAccount(account, token, season, amount));
        }

        uint256 updatedTotalBdv = uint256(s.a[account].mowStatuses[token].bdv).sub(originalCrateBDV); //this will `SafeMath: subtraction overflow` if amount > crateAmount, but I want it to be able to call through to the Legacy stuff below for excess remove
        s.a[account].mowStatuses[token].bdv = uint128(updatedTotalBdv);
    }

    //////////////////////// GETTERS ////////////////////////

    /**
     * @dev Calculate the BDV ("Bean Denominated Value") for `amount` of `token`.
     * 
     * Makes a call to a BDV function defined in the SiloSettings for this 
     * `token`. See {AppStorage.sol:Storage-SiloSettings} for more information.
     */
    function beanDenominatedValue(address token, uint256 amount)
        internal
        returns (uint256 bdv)
    {
        AppStorage storage s = LibAppStorage.diamondStorage();

        // BDV functions accept one argument: `uint256 amount`
        bytes memory callData = abi.encodeWithSelector(
            s.ss[token].selector,
            amount
        );

        (bool success, bytes memory data) = address(this).call(
            callData
        );

        if (!success) {
            if (data.length == 0) revert();
            assembly {
                revert(add(32, data), mload(data))
            }
        }

        assembly {
            bdv := mload(add(data, add(0x20, 0)))
        }
    }

    /**
     * @dev Locate the `amount` and `bdv` for a user's Deposit in storage.
     * 
     * Silo V2 Deposits are stored within each {Account} as a mapping of:
     *  `address token => uint32 season => { uint128 amount, uint128 bdv }`
     * 
     * Unripe BEAN and Unripe LP are handled independently so that data
     * stored in the legacy Silo V1 format and the new Silo V2 format can
     * be appropriately merged. See {LibUnripeSilo} for more information.
     *
     * FIXME(naming): rename to `getDeposit()`?
     */
    function tokenDeposit(
        address account,
        address token,
        int96 grownStalkPerBdv
    ) internal view returns (uint256 amount, uint256 bdv) {
        console.log('get tokenDeposit: ', account, token);
        console.log('tokenDeposit logging grown stalk per bdv:');
        console.logInt(grownStalkPerBdv);
        AppStorage storage s = LibAppStorage.diamondStorage();
        bytes32 depositId = LibBytes.packAddressAndCumulativeStalkPerBDV(token, grownStalkPerBdv);
        amount = s.a[account].deposits[depositId].amount;
        bdv = s.a[account].deposits[depositId].bdv;
        console.log('1 tokenDeposit amount: ', amount);
        console.log('1 tokenDeposit bdv: ', bdv);
        uint256 seedsPerToken = LibLegacyTokenSilo.getSeedsPerToken(token);
        
        if (LibLegacyTokenSilo.isDepositSeason(seedsPerToken, grownStalkPerBdv)) {
            console.log('yes grownStalkPerBdv deposit was a season');
            (uint legacyAmount, uint legacyBdv) =
                LibLegacyTokenSilo.tokenDeposit(account, address(token), LibLegacyTokenSilo.grownStalkPerBdvToSeason(seedsPerToken, grownStalkPerBdv));
            amount = amount.add(legacyAmount);
            bdv = bdv.add(legacyBdv);
            
        } else {
            console.log('not a deposit season');
        }
        console.log('2 tokenDeposit amount: ', amount);
        console.log('2 tokenDeposit bdv: ', bdv);
    }
    /**
     * @dev Get the number of Stalk per BDV per Season for a whitelisted token. Formerly just seeds.
     * Note this is stored as 1e6, i.e. 1_000_000 units of this is equal to 1 old seed.
     */
    function stalkEarnedPerSeason(address token) internal view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return uint256(s.ss[token].stalkEarnedPerSeason);
    }

    /**
     * @dev Get the number of Stalk per BDV for a whitelisted token. Formerly just stalk.
     */
    function stalkIssuedPerBdv(address token) internal view returns (uint256) {
        AppStorage storage s = LibAppStorage.diamondStorage();
        return uint256(s.ss[token].stalkIssuedPerBdv);
    }

    //this returns grown stalk with no decimals
    function cumulativeGrownStalkPerBdv(IERC20 token)
        internal
        view
        returns (int96 _cumulativeGrownStalkPerBdv)
    {
        AppStorage storage s = LibAppStorage.diamondStorage();
        // SiloSettings storage ss = s.ss[token]; //tried to use this, but I get `DeclarationError: Identifier not found or not unique.`
        console.log('cumulativeGrownStalkPerBdv s.ss[address(token)].lastCumulativeGrownStalkPerBdv: ', uint256(s.ss[address(token)].lastCumulativeGrownStalkPerBdv));
        console.log('cumulativeGrownStalkPerBdv s.season.current: ', s.season.current);
        console.log('cumulativeGrownStalkPerBdv s.ss[address(token)].lastUpdateSeason: ', s.ss[address(token)].lastUpdateSeason);
        console.log('cumulativeGrownStalkPerBdv s.ss[address(token)].stalkEarnedPerSeason: ', s.ss[address(token)].stalkEarnedPerSeason);

        //need to take into account the lastUpdateSeason for this token here


        //replace the - here with sub to disable support for when the current season is less than the silov3 epoch season
        _cumulativeGrownStalkPerBdv = s.ss[address(token)].lastCumulativeGrownStalkPerBdv +
            int96(int96(s.ss[address(token)].stalkEarnedPerSeason).mul(int96(s.season.current)-int96(s.ss[address(token)].lastUpdateSeason)).div(1e6)) //round here
        ;
        console.log('cumulativeGrownStalkPerBdv _cumulativeGrownStalkPerBdv: ', uint256(_cumulativeGrownStalkPerBdv));
    }

    function grownStalkForDeposit(
        address account,
        IERC20 token,
        int96 grownStalkPerBdv
    )
        internal
        view
        returns (uint grownStalk)
    {
        // cumulativeGrownStalkPerBdv(token) > depositGrownStalkPerBdv for all valid Deposits
        int96 _cumulativeGrownStalkPerBdv = cumulativeGrownStalkPerBdv(token);
        require(grownStalkPerBdv <= _cumulativeGrownStalkPerBdv, "Silo: Invalid Deposit");
        uint deltaGrownStalkPerBdv = uint(cumulativeGrownStalkPerBdv(token).sub(grownStalkPerBdv));
        (, uint bdv) = tokenDeposit(account, address(token), grownStalkPerBdv);
        console.log('grownStalkForDeposit bdv: ', bdv);
        grownStalk = deltaGrownStalkPerBdv.mul(bdv);
        console.log('grownStalkForDeposit grownStalk: ', grownStalk);
    }

    //this does not include stalk that has not been mowed
    //this function is used to convert, to see how much stalk would have been grown by a deposit at a 
    //given grown stalk index
    //TODOSEEDS this takes uint256 but grown stalk is always stored as int128, problem?
    function calculateStalkFromGrownStalkIndexAndBdv(IERC20 token, int128 grownStalkIndexOfDeposit, uint256 bdv)
        internal
        view
        returns (int128 grownStalk)
    {
        int128 latestCumulativeGrownStalkPerBdvForToken = cumulativeGrownStalkPerBdv(token);
        return latestCumulativeGrownStalkPerBdvForToken.sub(grownStalkIndexOfDeposit).mul(int128(bdv));
    }

    /// @dev is there a way to use grownStalk as the output?
    function calculateTotalGrownStalkandGrownStalk(IERC20 token, uint256 grownStalk, uint256 bdv)
        internal
        view 
        returns (uint256 _grownStalk, int96 cumulativeGrownStalk)
    {
        int96 latestCumulativeGrownStalkPerBdvForToken = cumulativeGrownStalkPerBdv(token);
        cumulativeGrownStalk = latestCumulativeGrownStalkPerBdvForToken-int96(grownStalk.div(bdv));
        // todo: talk to pizza about depositing at mid season
        // is it possible to skip the math calc here? 
        _grownStalk = uint256(latestCumulativeGrownStalkPerBdvForToken.sub(cumulativeGrownStalk).mul(int96(bdv)));
    }


    //takes in grownStalk total by a previous deposit, and a bdv, returns
    //what the grownStalkPerBdv index should be to have that same amount of grown stalk for the input token
    function grownStalkAndBdvToCumulativeGrownStalk(IERC20 token, uint256 grownStalk, uint256 bdv)
        internal
        view
        returns (int96 cumulativeGrownStalk)
    {
        //first get current latest grown stalk index
        int96 latestCumulativeGrownStalkPerBdvForToken = cumulativeGrownStalkPerBdv(token);
        console.log('grownStalkAndBdvToCumulativeGrownStalk latestCumulativeGrownStalkPerBdvForToken:');
        console.logInt(latestCumulativeGrownStalkPerBdvForToken);
        //then calculate how much stalk each individual bdv has grown
        int96 grownStalkPerBdv = int96(grownStalk.div(bdv));
        console.log('grownStalkAndBdvToCumulativeGrownStalk grownStalkPerBdv:');
        console.logInt(grownStalkPerBdv);
        //then subtract from the current latest index, so we get the index the deposit should have happened at
        //note that we want this to be able to "subtraction overflow" aka go below zero, because
        //there will be many cases where you'd want to convert and need to go far back enough in the
        //grown stalk index to need a negative index
        return latestCumulativeGrownStalkPerBdvForToken-grownStalkPerBdv;
    }
}
