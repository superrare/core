// SPDX-License-Identifier: MIT
pragma solidity 0.8.18;

import {IERC1155} from "openzeppelin-contracts/token/ERC1155/IERC1155.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

import {IRareERC1155} from "../token/ERC1155/IRareERC1155.sol";
import {MarketConfigV2} from "../v2/utils/MarketConfigV2.sol";
import {IERC1155ApprovalManager} from "../v2/approver/ERC1155/IERC1155ApprovalManager.sol";
import {IRareERC1155MarketplaceTypes} from "./IRareERC1155MarketplaceTypes.sol";

/// @author SuperRare Labs Inc.
/// @title RareERC1155SettlementCheckoutUtils
/// @notice Externalized checkout helpers for RareERC1155Settlement.
library RareERC1155SettlementCheckoutUtils {
    function checkoutPaymentFailureData(
        MarketConfigV2.Config storage _config,
        address _currencyAddress,
        uint256 _amount,
        uint256 _remainingEth
    ) public view returns (bytes memory failureData) {
        if (_amount == 0) return "";
        if (_currencyAddress == address(0)) {
            if (_remainingEth >= _amount) return "";
            return abi.encodeWithSelector(
                IRareERC1155MarketplaceTypes.InsufficientCheckoutETH.selector, _amount, _remainingEth
            );
        }

        IERC20 erc20 = IERC20(_currencyAddress);
        try erc20.balanceOf(msg.sender) returns (uint256 balance) {
            if (balance < _amount) {
                return abi.encodeWithSelector(
                    IRareERC1155MarketplaceTypes.InsufficientCheckoutERC20Balance.selector,
                    _currencyAddress,
                    _amount,
                    balance
                );
            }
        } catch {
            return abi.encodeWithSelector(
                IRareERC1155MarketplaceTypes.InsufficientCheckoutERC20Balance.selector, _currencyAddress, _amount, 0
            );
        }

        try erc20.allowance(msg.sender, address(_config.erc20ApprovalManager)) returns (uint256 allowance) {
            if (allowance < _amount) {
                return abi.encodeWithSelector(
                    IRareERC1155MarketplaceTypes.InsufficientCheckoutERC20Allowance.selector,
                    _currencyAddress,
                    _amount,
                    allowance
                );
            }
        } catch {
            return abi.encodeWithSelector(
                IRareERC1155MarketplaceTypes.InsufficientCheckoutERC20Allowance.selector, _currencyAddress, _amount, 0
            );
        }

        return "";
    }

    function collectCheckoutErc20(MarketConfigV2.Config storage _config, address _currencyAddress, uint256 _amount)
        public
    {
        if (_amount == 0) return;

        IERC20 erc20 = IERC20(_currencyAddress);
        uint256 balanceBefore;
        try erc20.balanceOf(address(this)) returns (uint256 balance) {
            balanceBefore = balance;
        } catch (bytes memory revertData) {
            revert IRareERC1155MarketplaceTypes.CheckoutItemExecutionFailed(
                IRareERC1155MarketplaceTypes.CheckoutFailureStage.PAYMENT_COLLECTION, revertData
            );
        }

        try _config.erc20ApprovalManager.transferFrom(_currencyAddress, msg.sender, address(this), _amount) {}
        catch (bytes memory revertData) {
            revert IRareERC1155MarketplaceTypes.CheckoutItemExecutionFailed(
                IRareERC1155MarketplaceTypes.CheckoutFailureStage.PAYMENT_COLLECTION, revertData
            );
        }

        uint256 balanceAfter;
        try erc20.balanceOf(address(this)) returns (uint256 balance) {
            balanceAfter = balance;
        } catch (bytes memory revertData) {
            revert IRareERC1155MarketplaceTypes.CheckoutItemExecutionFailed(
                IRareERC1155MarketplaceTypes.CheckoutFailureStage.PAYMENT_COLLECTION, revertData
            );
        }

        uint256 receivedAmount = balanceAfter >= balanceBefore ? balanceAfter - balanceBefore : 0;
        if (receivedAmount != _amount) {
            revert IRareERC1155MarketplaceTypes.CheckoutItemExecutionFailed(
                IRareERC1155MarketplaceTypes.CheckoutFailureStage.PAYMENT_COLLECTION,
                abi.encodeWithSelector(
                    IRareERC1155MarketplaceTypes.ERC20FeeOnTransferUnsupported.selector,
                    _currencyAddress,
                    _amount,
                    receivedAmount
                )
            );
        }
    }

    function checkoutSafeTransferFrom(
        IERC1155ApprovalManager _erc1155ApprovalManager,
        address _contractAddress,
        address _seller,
        address _buyer,
        uint256 _tokenId,
        uint256 _amount
    ) public {
        IERC1155 erc1155 = IERC1155(_contractAddress);
        uint256 sellerBalanceBefore;
        try erc1155.balanceOf(_seller, _tokenId) returns (uint256 balance) {
            sellerBalanceBefore = balance;
        } catch (bytes memory revertData) {
            revert IRareERC1155MarketplaceTypes.CheckoutItemExecutionFailed(
                IRareERC1155MarketplaceTypes.CheckoutFailureStage.TRANSFER, revertData
            );
        }
        if (sellerBalanceBefore < _amount) {
            revert IRareERC1155MarketplaceTypes.CheckoutItemExecutionFailed(
                IRareERC1155MarketplaceTypes.CheckoutFailureStage.TRANSFER,
                abi.encodeWithSelector(
                    IRareERC1155MarketplaceTypes.InsufficientTokenBalance.selector,
                    _seller,
                    _contractAddress,
                    _tokenId,
                    _amount,
                    sellerBalanceBefore
                )
            );
        }

        uint256 buyerBalanceBefore;
        try erc1155.balanceOf(_buyer, _tokenId) returns (uint256 balance) {
            buyerBalanceBefore = balance;
        } catch (bytes memory revertData) {
            revert IRareERC1155MarketplaceTypes.CheckoutItemExecutionFailed(
                IRareERC1155MarketplaceTypes.CheckoutFailureStage.TRANSFER, revertData
            );
        }

        try _erc1155ApprovalManager.safeTransferFrom(_contractAddress, _seller, _buyer, _tokenId, _amount, "") {}
        catch (bytes memory revertData) {
            revert IRareERC1155MarketplaceTypes.CheckoutItemExecutionFailed(
                IRareERC1155MarketplaceTypes.CheckoutFailureStage.TRANSFER, revertData
            );
        }

        uint256 sellerBalanceAfter;
        try erc1155.balanceOf(_seller, _tokenId) returns (uint256 balance) {
            sellerBalanceAfter = balance;
        } catch (bytes memory revertData) {
            revert IRareERC1155MarketplaceTypes.CheckoutItemExecutionFailed(
                IRareERC1155MarketplaceTypes.CheckoutFailureStage.TRANSFER, revertData
            );
        }

        uint256 buyerBalanceAfter;
        try erc1155.balanceOf(_buyer, _tokenId) returns (uint256 balance) {
            buyerBalanceAfter = balance;
        } catch (bytes memory revertData) {
            revert IRareERC1155MarketplaceTypes.CheckoutItemExecutionFailed(
                IRareERC1155MarketplaceTypes.CheckoutFailureStage.TRANSFER, revertData
            );
        }

        if (sellerBalanceAfter != sellerBalanceBefore - _amount || buyerBalanceAfter != buyerBalanceBefore + _amount) {
            revert IRareERC1155MarketplaceTypes.CheckoutItemExecutionFailed(
                IRareERC1155MarketplaceTypes.CheckoutFailureStage.TRANSFER,
                abi.encodeWithSelector(
                    IRareERC1155MarketplaceTypes.InvalidERC1155Transfer.selector,
                    _contractAddress,
                    _tokenId,
                    _seller,
                    _buyer,
                    _amount
                )
            );
        }
    }

    function checkoutMintBatchToWithBalanceCheck(
        address _contractAddress,
        address _buyer,
        uint256[] memory _tokenIds,
        uint256[] memory _amounts
    ) public {
        IERC1155 erc1155 = IERC1155(_contractAddress);
        address[] memory balanceAccounts = _balanceAccounts(_buyer, _tokenIds.length);
        uint256[] memory balancesBeforeMint;

        try erc1155.balanceOfBatch(balanceAccounts, _tokenIds) returns (uint256[] memory balances) {
            balancesBeforeMint = balances;
        } catch (bytes memory revertData) {
            revert IRareERC1155MarketplaceTypes.CheckoutItemExecutionFailed(
                IRareERC1155MarketplaceTypes.CheckoutFailureStage.MINT, revertData
            );
        }

        try IRareERC1155(_contractAddress).mintBatchTo(_buyer, _tokenIds, _amounts) {}
        catch (bytes memory revertData) {
            revert IRareERC1155MarketplaceTypes.CheckoutItemExecutionFailed(
                IRareERC1155MarketplaceTypes.CheckoutFailureStage.MINT, revertData
            );
        }

        uint256[] memory balancesAfterMint;
        try erc1155.balanceOfBatch(balanceAccounts, _tokenIds) returns (uint256[] memory balances) {
            balancesAfterMint = balances;
        } catch (bytes memory revertData) {
            revert IRareERC1155MarketplaceTypes.CheckoutItemExecutionFailed(
                IRareERC1155MarketplaceTypes.CheckoutFailureStage.MINT, revertData
            );
        }

        for (uint256 i = 0; i < _tokenIds.length;) {
            if (balancesAfterMint[i] != balancesBeforeMint[i] + _amounts[i]) {
                revert IRareERC1155MarketplaceTypes.CheckoutItemExecutionFailed(
                    IRareERC1155MarketplaceTypes.CheckoutFailureStage.MINT,
                    abi.encodeWithSelector(
                        IRareERC1155MarketplaceTypes.InvalidERC1155Mint.selector,
                        _contractAddress,
                        _tokenIds[i],
                        _buyer,
                        _amounts[i]
                    )
                );
            }

            unchecked {
                ++i;
            }
        }
    }

    function _balanceAccounts(address _account, uint256 _length) private pure returns (address[] memory accounts) {
        accounts = new address[](_length);
        for (uint256 i = 0; i < _length;) {
            accounts[i] = _account;

            unchecked {
                ++i;
            }
        }
    }
}
