**THIS CHECKLIST IS NOT COMPLETE**. Use `--show-ignored-findings` to show all the results.
Summary
 - [arbitrary-send-erc20](#arbitrary-send-erc20) (2 results) (High)
 - [arbitrary-send-eth](#arbitrary-send-eth) (1 results) (High)
 - [incorrect-exp](#incorrect-exp) (1 results) (High)
 - [divide-before-multiply](#divide-before-multiply) (16 results) (Medium)
 - [incorrect-equality](#incorrect-equality) (14 results) (Medium)
 - [reentrancy-no-eth](#reentrancy-no-eth) (20 results) (Medium)
 - [unused-return](#unused-return) (3 results) (Medium)
 - [shadowing-local](#shadowing-local) (5 results) (Low)
 - [events-maths](#events-maths) (3 results) (Low)
 - [calls-loop](#calls-loop) (11 results) (Low)
 - [reentrancy-benign](#reentrancy-benign) (11 results) (Low)
 - [reentrancy-events](#reentrancy-events) (4 results) (Low)
 - [timestamp](#timestamp) (28 results) (Low)
 - [assembly](#assembly) (11 results) (Informational)
 - [pragma](#pragma) (1 results) (Informational)
 - [costly-loop](#costly-loop) (26 results) (Informational)
 - [dead-code](#dead-code) (1 results) (Informational)
 - [solc-version](#solc-version) (3 results) (Informational)
 - [low-level-calls](#low-level-calls) (10 results) (Informational)
 - [missing-inheritance](#missing-inheritance) (4 results) (Informational)
 - [naming-convention](#naming-convention) (29 results) (Informational)
 - [too-many-digits](#too-many-digits) (2 results) (Informational)
 - [unindexed-event-address](#unindexed-event-address) (10 results) (Informational)
 - [cache-array-length](#cache-array-length) (1 results) (Optimization)
## arbitrary-send-erc20
Impact: High
Confidence: High
 - [ ] ID-0
[RevvFiMarket.repayFull()](src/RevvFiMarket.sol#L603-L636) uses arbitrary from in transferFrom: [borrowToken.safeTransferFrom(borrower,address(this),totalDebt)](src/RevvFiMarket.sol#L608)

src/RevvFiMarket.sol#L603-L636


 - [ ] ID-1
[RevvFiMarket.repay(uint256)](src/RevvFiMarket.sol#L521-L542) uses arbitrary from in transferFrom: [borrowToken.safeTransferFrom(borrower,address(this),amount)](src/RevvFiMarket.sol#L529)

src/RevvFiMarket.sol#L521-L542


## arbitrary-send-eth
Impact: High
Confidence: Medium
 - [ ] ID-2
[RevvFiFactory.deployMarket(address,address,address,address,uint8,uint8,uint256,uint256)](src/RevvFiFactory.sol#L214-L290) sends eth to arbitrary user
	Dangerous calls:
	- [(feeSent,None) = feeRecipient.call{value: deploymentFee}()](src/RevvFiFactory.sol#L236)

src/RevvFiFactory.sol#L214-L290


## incorrect-exp
Impact: High
Confidence: Medium
 - [ ] ID-3
[Math.mulDiv(uint256,uint256,uint256)](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L123-L202) has bitwise-xor operator ^ instead of the exponentiation operator **: 
	 - [inverse = (3 * denominator) ^ 2](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L184)

lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L123-L202


## divide-before-multiply
Impact: Medium
Confidence: Medium
 - [ ] ID-4
[RevvFiMarket._accrueInterest()](src/RevvFiMarket.sol#L217-L241) performs a multiplication on the result of a division:
	- [totalInterestAccrued = (currentPrincipal * weightedAverageAPR * elapsed) / (SECONDS_PER_YEAR * BASIS_POINTS)](src/RevvFiMarket.sol#L230-L231)
	- [indexIncrease = (borrowIndex * totalInterestAccrued) / currentPrincipal](src/RevvFiMarket.sol#L235)

src/RevvFiMarket.sol#L217-L241


 - [ ] ID-5
[RevvFiMarket._distributeRepayment(uint256)](src/RevvFiMarket.sol#L548-L598) performs a multiplication on the result of a division:
	- [positionDebt = (positionScaledPrincipal[posId] * currentIndex) / SCALE](src/RevvFiMarket.sol#L561)
	- [share = (repaymentAmount * positionDebt) / totalDebtBefore](src/RevvFiMarket.sol#L565)

src/RevvFiMarket.sol#L548-L598


 - [ ] ID-6
[Math.mulDiv(uint256,uint256,uint256)](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L123-L202) performs a multiplication on the result of a division:
	- [denominator = denominator / twos](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L169)
	- [inverse *= 2 - denominator * inverse](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L190)

lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L123-L202


 - [ ] ID-7
[Math.mulDiv(uint256,uint256,uint256)](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L123-L202) performs a multiplication on the result of a division:
	- [denominator = denominator / twos](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L169)
	- [inverse *= 2 - denominator * inverse](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L193)

lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L123-L202


 - [ ] ID-8
[Math.mulDiv(uint256,uint256,uint256)](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L123-L202) performs a multiplication on the result of a division:
	- [denominator = denominator / twos](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L169)
	- [inverse *= 2 - denominator * inverse](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L188)

lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L123-L202


 - [ ] ID-9
[RevvFiMarket._getUpdatedBorrowIndex()](src/RevvFiMarket.sol#L247-L259) performs a multiplication on the result of a division:
	- [totalInterestAccrued = (currentPrincipal * weightedAverageAPR * elapsed) / (SECONDS_PER_YEAR * BASIS_POINTS)](src/RevvFiMarket.sol#L254-L255)
	- [indexIncrease = (borrowIndex * totalInterestAccrued) / currentPrincipal](src/RevvFiMarket.sol#L256)

src/RevvFiMarket.sol#L247-L259


 - [ ] ID-10
[Math.mulDiv(uint256,uint256,uint256)](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L123-L202) performs a multiplication on the result of a division:
	- [denominator = denominator / twos](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L169)
	- [inverse = (3 * denominator) ^ 2](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L184)

lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L123-L202


 - [ ] ID-11
[Math.mulDiv(uint256,uint256,uint256)](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L123-L202) performs a multiplication on the result of a division:
	- [prod0 = prod0 / twos](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L172)
	- [result = prod0 * inverse](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L199)

lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L123-L202


 - [ ] ID-12
[RevvFiMarket._accrueInterest()](src/RevvFiMarket.sol#L217-L241) performs a multiplication on the result of a division:
	- [currentPrincipal = (totalScaledPrincipal * borrowIndex) / SCALE](src/RevvFiMarket.sol#L227)
	- [totalInterestAccrued = (currentPrincipal * weightedAverageAPR * elapsed) / (SECONDS_PER_YEAR * BASIS_POINTS)](src/RevvFiMarket.sol#L230-L231)

src/RevvFiMarket.sol#L217-L241


 - [ ] ID-13
[RevvFiLiquidityQueue.processEpoch(uint256,uint256)](src/RevvFiLiquidityQueue.sol#L192-L224) performs a multiplication on the result of a division:
	- [fulfillmentRatio = (availableLiquidity * 1e18) / epoch.totalRequested](src/RevvFiLiquidityQueue.sol#L207)
	- [payout = (request.requestedAmount * fulfillmentRatio) / 1e18](src/RevvFiLiquidityQueue.sol#L216)

src/RevvFiLiquidityQueue.sol#L192-L224


 - [ ] ID-14
[Math.mulDiv(uint256,uint256,uint256)](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L123-L202) performs a multiplication on the result of a division:
	- [denominator = denominator / twos](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L169)
	- [inverse *= 2 - denominator * inverse](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L192)

lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L123-L202


 - [ ] ID-15
[Math.mulDiv(uint256,uint256,uint256)](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L123-L202) performs a multiplication on the result of a division:
	- [denominator = denominator / twos](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L169)
	- [inverse *= 2 - denominator * inverse](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L191)

lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L123-L202


 - [ ] ID-16
[RevvFiMarket._getUpdatedBorrowIndex()](src/RevvFiMarket.sol#L247-L259) performs a multiplication on the result of a division:
	- [currentPrincipal = (totalScaledPrincipal * borrowIndex) / SCALE](src/RevvFiMarket.sol#L253)
	- [totalInterestAccrued = (currentPrincipal * weightedAverageAPR * elapsed) / (SECONDS_PER_YEAR * BASIS_POINTS)](src/RevvFiMarket.sol#L254-L255)

src/RevvFiMarket.sol#L247-L259


 - [ ] ID-17
[RevvFiLiquidator.getCurrentPrice(uint256)](src/RevvFiLiquidator.sol#L177-L191) performs a multiplication on the result of a division:
	- [steps = elapsed / dutchAuctionStepDuration](src/RevvFiLiquidator.sol#L182)
	- [priceDecrement = (auction.debtAmount * dutchAuctionPriceDecrementBps * steps) / (10000)](src/RevvFiLiquidator.sol#L184)

src/RevvFiLiquidator.sol#L177-L191


 - [ ] ID-18
[Math.mulDiv(uint256,uint256,uint256)](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L123-L202) performs a multiplication on the result of a division:
	- [denominator = denominator / twos](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L169)
	- [inverse *= 2 - denominator * inverse](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L189)

lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L123-L202


 - [ ] ID-19
[RevvFiMarket._distributeRepayment(uint256)](src/RevvFiMarket.sol#L548-L598) performs a multiplication on the result of a division:
	- [share = (repaymentAmount * positionDebt) / totalDebtBefore](src/RevvFiMarket.sol#L565)
	- [scaledReduction = (share * SCALE) / currentIndex](src/RevvFiMarket.sol#L572)

src/RevvFiMarket.sol#L548-L598


## incorrect-equality
Impact: Medium
Confidence: High
 - [ ] ID-20
[RevvFiMarket._distributeRepayment(uint256)](src/RevvFiMarket.sol#L548-L598) uses a dangerous strict equality:
	- [positionDebt == 0](src/RevvFiMarket.sol#L562)

src/RevvFiMarket.sol#L548-L598


 - [ ] ID-21
[RevvFiMarket._accrueInterest()](src/RevvFiMarket.sol#L217-L241) uses a dangerous strict equality:
	- [totalScaledPrincipal == 0](src/RevvFiMarket.sol#L218)

src/RevvFiMarket.sol#L217-L241


 - [ ] ID-22
[RevvFiMarket.repay(uint256)](src/RevvFiMarket.sol#L521-L542) uses a dangerous strict equality:
	- [totalDebt == 0](src/RevvFiMarket.sol#L525)

src/RevvFiMarket.sol#L521-L542


 - [ ] ID-23
[RevvFiMarket.repayFull()](src/RevvFiMarket.sol#L603-L636) uses a dangerous strict equality:
	- [totalDebt == 0](src/RevvFiMarket.sol#L605)

src/RevvFiMarket.sol#L603-L636


 - [ ] ID-24
[RevvFiMarket._updateWeightedAverageAPR()](src/RevvFiMarket.sol#L346-L352) uses a dangerous strict equality:
	- [totalScaledPrincipal == 0](src/RevvFiMarket.sol#L347)

src/RevvFiMarket.sol#L346-L352


 - [ ] ID-25
[RevvFiMarket._distributeRepayment(uint256)](src/RevvFiMarket.sol#L548-L598) uses a dangerous strict equality:
	- [share == 0](src/RevvFiMarket.sol#L567)

src/RevvFiMarket.sol#L548-L598


 - [ ] ID-26
[RevvFiMarket._getUpdatedBorrowIndex()](src/RevvFiMarket.sol#L247-L259) uses a dangerous strict equality:
	- [totalScaledPrincipal == 0](src/RevvFiMarket.sol#L248)

src/RevvFiMarket.sol#L247-L259


 - [ ] ID-27
[RevvFiMarket._getPositionDebt(uint256)](src/RevvFiMarket.sol#L266-L270) uses a dangerous strict equality:
	- [! positionActive[positionId] || positionScaledPrincipal[positionId] == 0](src/RevvFiMarket.sol#L267)

src/RevvFiMarket.sol#L266-L270


 - [ ] ID-28
[RevvFiMarket._distributeRepayment(uint256)](src/RevvFiMarket.sol#L548-L598) uses a dangerous strict equality:
	- [totalScaledPrincipal == 0](src/RevvFiMarket.sol#L549)

src/RevvFiMarket.sol#L548-L598


 - [ ] ID-29
[RevvFiMarket._getUpdatedBorrowIndex()](src/RevvFiMarket.sol#L247-L259) uses a dangerous strict equality:
	- [elapsed == 0](src/RevvFiMarket.sol#L251)

src/RevvFiMarket.sol#L247-L259


 - [ ] ID-30
[RevvFiMarket._updateAPROnPrincipalChange(uint256,uint256,uint256)](src/RevvFiMarket.sol#L324-L341) uses a dangerous strict equality:
	- [oldScaledPrincipal == newScaledPrincipal](src/RevvFiMarket.sol#L325)

src/RevvFiMarket.sol#L324-L341


 - [ ] ID-31
[RevvFiMarket._distributeLoss(uint256)](src/RevvFiMarket.sol#L800-L858) uses a dangerous strict equality:
	- [positionDebt == 0](src/RevvFiMarket.sol#L812)

src/RevvFiMarket.sol#L800-L858


 - [ ] ID-32
[RevvFiMarket._distributeLoss(uint256)](src/RevvFiMarket.sol#L800-L858) uses a dangerous strict equality:
	- [positionDebt_scope_2 == 0](src/RevvFiMarket.sol#L839)

src/RevvFiMarket.sol#L800-L858


 - [ ] ID-33
[RevvFiMarket._accrueInterest()](src/RevvFiMarket.sol#L217-L241) uses a dangerous strict equality:
	- [elapsed == 0](src/RevvFiMarket.sol#L224)

src/RevvFiMarket.sol#L217-L241


## reentrancy-no-eth
Impact: Medium
Confidence: Medium
 - [ ] ID-34
Reentrancy in [RevvFiMarket.repayFull()](src/RevvFiMarket.sol#L603-L636):
	External calls:
	- [borrowToken.safeTransferFrom(borrower,address(this),totalDebt)](src/RevvFiMarket.sol#L608)
	- [_settlePosition(posId)](src/RevvFiMarket.sol#L621)
		- [positionNFT.redeemPosition(positionId)](src/RevvFiMarket.sol#L683)
	State variables written after the call(s):
	- [_removePositionWithAPR(posId)](src/RevvFiMarket.sol#L620)
		- [activePositionIds[index] = lastId](src/RevvFiMarket.sol#L379)
		- [activePositionIds.pop()](src/RevvFiMarket.sol#L381)
	[RevvFiMarket.activePositionIds](src/RevvFiMarket.sol#L73) can be used in cross function reentrancies:
	- [RevvFiMarket._distributeLoss(uint256)](src/RevvFiMarket.sol#L800-L858)
	- [RevvFiMarket._distributeRepayment(uint256)](src/RevvFiMarket.sol#L548-L598)
	- [RevvFiMarket._removeActivePosition(uint256)](src/RevvFiMarket.sol#L374-L385)
	- [RevvFiMarket.activePositionIds](src/RevvFiMarket.sol#L73)
	- [RevvFiMarket.getActivePositionsCount()](src/RevvFiMarket.sol#L991-L993)
	- [RevvFiMarket.getActivePositionsPaginated(uint256,uint256)](src/RevvFiMarket.sol#L1001-L1009)
	- [_removePositionWithAPR(posId)](src/RevvFiMarket.sol#L620)
		- [activePositionIndex[lastId] = index](src/RevvFiMarket.sol#L380)
		- [delete activePositionIndex[positionId]](src/RevvFiMarket.sol#L383)
	[RevvFiMarket.activePositionIndex](src/RevvFiMarket.sol#L74) can be used in cross function reentrancies:
	- [RevvFiMarket._removeActivePosition(uint256)](src/RevvFiMarket.sol#L374-L385)
	- [RevvFiMarket.activePositionIndex](src/RevvFiMarket.sol#L74)
	- [_removePositionWithAPR(posId)](src/RevvFiMarket.sol#L620)
		- [positionActive[positionId] = false](src/RevvFiMarket.sol#L384)
	[RevvFiMarket.positionActive](src/RevvFiMarket.sol#L67) can be used in cross function reentrancies:
	- [RevvFiMarket._distributeLoss(uint256)](src/RevvFiMarket.sol#L800-L858)
	- [RevvFiMarket._distributeRepayment(uint256)](src/RevvFiMarket.sol#L548-L598)
	- [RevvFiMarket._removeActivePosition(uint256)](src/RevvFiMarket.sol#L374-L385)
	- [RevvFiMarket.getPositionValue(uint256)](src/RevvFiMarket.sol#L982-L985)
	- [RevvFiMarket.positionActive](src/RevvFiMarket.sol#L67)
	- [positionClaimableAmount[posId] += positionDebt](src/RevvFiMarket.sol#L619)
	[RevvFiMarket.positionClaimableAmount](src/RevvFiMarket.sol#L69) can be used in cross function reentrancies:
	- [RevvFiMarket._distributeRepayment(uint256)](src/RevvFiMarket.sol#L548-L598)
	- [RevvFiMarket.getPositionClaimable(uint256)](src/RevvFiMarket.sol#L973-L975)
	- [RevvFiMarket.positionClaimableAmount](src/RevvFiMarket.sol#L69)
	- [_removePositionWithAPR(posId)](src/RevvFiMarket.sol#L620)
		- [positionScaledPrincipal[positionId] = 0](src/RevvFiMarket.sol#L396)
	[RevvFiMarket.positionScaledPrincipal](src/RevvFiMarket.sol#L64) can be used in cross function reentrancies:
	- [RevvFiMarket._distributeLoss(uint256)](src/RevvFiMarket.sol#L800-L858)
	- [RevvFiMarket._distributeRepayment(uint256)](src/RevvFiMarket.sol#L548-L598)
	- [RevvFiMarket._removePositionWithAPR(uint256)](src/RevvFiMarket.sol#L392-L404)
	- [RevvFiMarket.getPositionValue(uint256)](src/RevvFiMarket.sol#L982-L985)
	- [RevvFiMarket.positionScaledPrincipal](src/RevvFiMarket.sol#L64)
	- [_removePositionWithAPR(posId)](src/RevvFiMarket.sol#L620)
		- [totalScaledPrincipal -= remainingScaled](src/RevvFiMarket.sol#L399)
	[RevvFiMarket.totalScaledPrincipal](src/RevvFiMarket.sol#L55) can be used in cross function reentrancies:
	- [RevvFiMarket._accrueInterest()](src/RevvFiMarket.sol#L217-L241)
	- [RevvFiMarket._distributeLoss(uint256)](src/RevvFiMarket.sol#L800-L858)
	- [RevvFiMarket._distributeRepayment(uint256)](src/RevvFiMarket.sol#L548-L598)
	- [RevvFiMarket._getUpdatedBorrowIndex()](src/RevvFiMarket.sol#L247-L259)
	- [RevvFiMarket._removePositionWithAPR(uint256)](src/RevvFiMarket.sol#L392-L404)
	- [RevvFiMarket._updateWeightedAverageAPR()](src/RevvFiMarket.sol#L346-L352)
	- [RevvFiMarket.getCurrentPrincipal()](src/RevvFiMarket.sol#L285-L287)
	- [RevvFiMarket.getTotalOwed()](src/RevvFiMarket.sol#L276-L279)
	- [RevvFiMarket.totalScaledPrincipal](src/RevvFiMarket.sol#L55)
	- [totalScaledPrincipal = 0](src/RevvFiMarket.sol#L625)
	[RevvFiMarket.totalScaledPrincipal](src/RevvFiMarket.sol#L55) can be used in cross function reentrancies:
	- [RevvFiMarket._accrueInterest()](src/RevvFiMarket.sol#L217-L241)
	- [RevvFiMarket._distributeLoss(uint256)](src/RevvFiMarket.sol#L800-L858)
	- [RevvFiMarket._distributeRepayment(uint256)](src/RevvFiMarket.sol#L548-L598)
	- [RevvFiMarket._getUpdatedBorrowIndex()](src/RevvFiMarket.sol#L247-L259)
	- [RevvFiMarket._removePositionWithAPR(uint256)](src/RevvFiMarket.sol#L392-L404)
	- [RevvFiMarket._updateWeightedAverageAPR()](src/RevvFiMarket.sol#L346-L352)
	- [RevvFiMarket.getCurrentPrincipal()](src/RevvFiMarket.sol#L285-L287)
	- [RevvFiMarket.getTotalOwed()](src/RevvFiMarket.sol#L276-L279)
	- [RevvFiMarket.totalScaledPrincipal](src/RevvFiMarket.sol#L55)
	- [_removePositionWithAPR(posId)](src/RevvFiMarket.sol#L620)
		- [weightedAprNumeratorScaled -= reduction](src/RevvFiMarket.sol#L311)
		- [weightedAprNumeratorScaled = 0](src/RevvFiMarket.sol#L313)
	[RevvFiMarket.weightedAprNumeratorScaled](src/RevvFiMarket.sol#L60) can be used in cross function reentrancies:
	- [RevvFiMarket._updateAPROnPrincipalChange(uint256,uint256,uint256)](src/RevvFiMarket.sol#L324-L341)
	- [RevvFiMarket._updateAPROnRemove(uint256,uint256)](src/RevvFiMarket.sol#L308-L316)
	- [RevvFiMarket._updateWeightedAverageAPR()](src/RevvFiMarket.sol#L346-L352)
	- [RevvFiMarket.weightedAprNumeratorScaled](src/RevvFiMarket.sol#L60)
	- [weightedAprNumeratorScaled = 0](src/RevvFiMarket.sol#L626)
	[RevvFiMarket.weightedAprNumeratorScaled](src/RevvFiMarket.sol#L60) can be used in cross function reentrancies:
	- [RevvFiMarket._updateAPROnPrincipalChange(uint256,uint256,uint256)](src/RevvFiMarket.sol#L324-L341)
	- [RevvFiMarket._updateAPROnRemove(uint256,uint256)](src/RevvFiMarket.sol#L308-L316)
	- [RevvFiMarket._updateWeightedAverageAPR()](src/RevvFiMarket.sol#L346-L352)
	- [RevvFiMarket.weightedAprNumeratorScaled](src/RevvFiMarket.sol#L60)
	- [_removePositionWithAPR(posId)](src/RevvFiMarket.sol#L620)
		- [weightedAverageAPR = 0](src/RevvFiMarket.sol#L348)
		- [weightedAverageAPR = weightedAprNumeratorScaled / totalScaledPrincipal](src/RevvFiMarket.sol#L351)
	[RevvFiMarket.weightedAverageAPR](src/RevvFiMarket.sol#L61) can be used in cross function reentrancies:
	- [RevvFiMarket._accrueInterest()](src/RevvFiMarket.sol#L217-L241)
	- [RevvFiMarket._getUpdatedBorrowIndex()](src/RevvFiMarket.sol#L247-L259)
	- [RevvFiMarket._updateWeightedAverageAPR()](src/RevvFiMarket.sol#L346-L352)
	- [RevvFiMarket.weightedAverageAPR](src/RevvFiMarket.sol#L61)
	- [weightedAverageAPR = 0](src/RevvFiMarket.sol#L627)
	[RevvFiMarket.weightedAverageAPR](src/RevvFiMarket.sol#L61) can be used in cross function reentrancies:
	- [RevvFiMarket._accrueInterest()](src/RevvFiMarket.sol#L217-L241)
	- [RevvFiMarket._getUpdatedBorrowIndex()](src/RevvFiMarket.sol#L247-L259)
	- [RevvFiMarket._updateWeightedAverageAPR()](src/RevvFiMarket.sol#L346-L352)
	- [RevvFiMarket.weightedAverageAPR](src/RevvFiMarket.sol#L61)

src/RevvFiMarket.sol#L603-L636


 - [ ] ID-35
Reentrancy in [RevvFiMarket.repay(uint256)](src/RevvFiMarket.sol#L521-L542):
	External calls:
	- [borrowToken.safeTransferFrom(borrower,address(this),amount)](src/RevvFiMarket.sol#L529)
	- [_distributeRepayment(amount)](src/RevvFiMarket.sol#L531)
		- [positionNFT.redeemPosition(positionId)](src/RevvFiMarket.sol#L683)
	State variables written after the call(s):
	- [_distributeRepayment(amount)](src/RevvFiMarket.sol#L531)
		- [totalScaledPrincipal -= remainingScaled](src/RevvFiMarket.sol#L399)
		- [totalScaledPrincipal -= scaledReduction](src/RevvFiMarket.sol#L573)
	[RevvFiMarket.totalScaledPrincipal](src/RevvFiMarket.sol#L55) can be used in cross function reentrancies:
	- [RevvFiMarket._accrueInterest()](src/RevvFiMarket.sol#L217-L241)
	- [RevvFiMarket._distributeLoss(uint256)](src/RevvFiMarket.sol#L800-L858)
	- [RevvFiMarket._distributeRepayment(uint256)](src/RevvFiMarket.sol#L548-L598)
	- [RevvFiMarket._getUpdatedBorrowIndex()](src/RevvFiMarket.sol#L247-L259)
	- [RevvFiMarket._removePositionWithAPR(uint256)](src/RevvFiMarket.sol#L392-L404)
	- [RevvFiMarket._updateWeightedAverageAPR()](src/RevvFiMarket.sol#L346-L352)
	- [RevvFiMarket.getCurrentPrincipal()](src/RevvFiMarket.sol#L285-L287)
	- [RevvFiMarket.getTotalOwed()](src/RevvFiMarket.sol#L276-L279)
	- [RevvFiMarket.totalScaledPrincipal](src/RevvFiMarket.sol#L55)
	- [_distributeRepayment(amount)](src/RevvFiMarket.sol#L531)
		- [weightedAverageAPR = 0](src/RevvFiMarket.sol#L348)
		- [weightedAverageAPR = weightedAprNumeratorScaled / totalScaledPrincipal](src/RevvFiMarket.sol#L351)
	[RevvFiMarket.weightedAverageAPR](src/RevvFiMarket.sol#L61) can be used in cross function reentrancies:
	- [RevvFiMarket._accrueInterest()](src/RevvFiMarket.sol#L217-L241)
	- [RevvFiMarket._getUpdatedBorrowIndex()](src/RevvFiMarket.sol#L247-L259)
	- [RevvFiMarket._updateWeightedAverageAPR()](src/RevvFiMarket.sol#L346-L352)
	- [RevvFiMarket.weightedAverageAPR](src/RevvFiMarket.sol#L61)

src/RevvFiMarket.sol#L521-L542


 - [ ] ID-36
Reentrancy in [RevvFiMarket.forceCloseMarket()](src/RevvFiMarket.sol#L864-L888):
	External calls:
	- [_settlePosition(posId)](src/RevvFiMarket.sol#L879)
		- [positionNFT.redeemPosition(positionId)](src/RevvFiMarket.sol#L683)
	State variables written after the call(s):
	- [_removePositionWithAPR(posId)](src/RevvFiMarket.sol#L878)
		- [activePositionIds[index] = lastId](src/RevvFiMarket.sol#L379)
		- [activePositionIds.pop()](src/RevvFiMarket.sol#L381)
	[RevvFiMarket.activePositionIds](src/RevvFiMarket.sol#L73) can be used in cross function reentrancies:
	- [RevvFiMarket._distributeLoss(uint256)](src/RevvFiMarket.sol#L800-L858)
	- [RevvFiMarket._distributeRepayment(uint256)](src/RevvFiMarket.sol#L548-L598)
	- [RevvFiMarket._removeActivePosition(uint256)](src/RevvFiMarket.sol#L374-L385)
	- [RevvFiMarket.activePositionIds](src/RevvFiMarket.sol#L73)
	- [RevvFiMarket.getActivePositionsCount()](src/RevvFiMarket.sol#L991-L993)
	- [RevvFiMarket.getActivePositionsPaginated(uint256,uint256)](src/RevvFiMarket.sol#L1001-L1009)
	- [_removePositionWithAPR(posId)](src/RevvFiMarket.sol#L878)
		- [activePositionIndex[lastId] = index](src/RevvFiMarket.sol#L380)
		- [delete activePositionIndex[positionId]](src/RevvFiMarket.sol#L383)
	[RevvFiMarket.activePositionIndex](src/RevvFiMarket.sol#L74) can be used in cross function reentrancies:
	- [RevvFiMarket._removeActivePosition(uint256)](src/RevvFiMarket.sol#L374-L385)
	- [RevvFiMarket.activePositionIndex](src/RevvFiMarket.sol#L74)
	- [_removePositionWithAPR(posId)](src/RevvFiMarket.sol#L878)
		- [positionActive[positionId] = false](src/RevvFiMarket.sol#L384)
	[RevvFiMarket.positionActive](src/RevvFiMarket.sol#L67) can be used in cross function reentrancies:
	- [RevvFiMarket._distributeLoss(uint256)](src/RevvFiMarket.sol#L800-L858)
	- [RevvFiMarket._distributeRepayment(uint256)](src/RevvFiMarket.sol#L548-L598)
	- [RevvFiMarket._removeActivePosition(uint256)](src/RevvFiMarket.sol#L374-L385)
	- [RevvFiMarket.getPositionValue(uint256)](src/RevvFiMarket.sol#L982-L985)
	- [RevvFiMarket.positionActive](src/RevvFiMarket.sol#L67)
	- [positionClaimableAmount[posId] += positionDebt](src/RevvFiMarket.sol#L877)
	[RevvFiMarket.positionClaimableAmount](src/RevvFiMarket.sol#L69) can be used in cross function reentrancies:
	- [RevvFiMarket._distributeRepayment(uint256)](src/RevvFiMarket.sol#L548-L598)
	- [RevvFiMarket.getPositionClaimable(uint256)](src/RevvFiMarket.sol#L973-L975)
	- [RevvFiMarket.positionClaimableAmount](src/RevvFiMarket.sol#L69)
	- [_removePositionWithAPR(posId)](src/RevvFiMarket.sol#L878)
		- [positionScaledPrincipal[positionId] = 0](src/RevvFiMarket.sol#L396)
	[RevvFiMarket.positionScaledPrincipal](src/RevvFiMarket.sol#L64) can be used in cross function reentrancies:
	- [RevvFiMarket._distributeLoss(uint256)](src/RevvFiMarket.sol#L800-L858)
	- [RevvFiMarket._distributeRepayment(uint256)](src/RevvFiMarket.sol#L548-L598)
	- [RevvFiMarket._removePositionWithAPR(uint256)](src/RevvFiMarket.sol#L392-L404)
	- [RevvFiMarket.getPositionValue(uint256)](src/RevvFiMarket.sol#L982-L985)
	- [RevvFiMarket.positionScaledPrincipal](src/RevvFiMarket.sol#L64)
	- [_removePositionWithAPR(posId)](src/RevvFiMarket.sol#L878)
		- [totalScaledPrincipal -= remainingScaled](src/RevvFiMarket.sol#L399)
	[RevvFiMarket.totalScaledPrincipal](src/RevvFiMarket.sol#L55) can be used in cross function reentrancies:
	- [RevvFiMarket._accrueInterest()](src/RevvFiMarket.sol#L217-L241)
	- [RevvFiMarket._distributeLoss(uint256)](src/RevvFiMarket.sol#L800-L858)
	- [RevvFiMarket._distributeRepayment(uint256)](src/RevvFiMarket.sol#L548-L598)
	- [RevvFiMarket._getUpdatedBorrowIndex()](src/RevvFiMarket.sol#L247-L259)
	- [RevvFiMarket._removePositionWithAPR(uint256)](src/RevvFiMarket.sol#L392-L404)
	- [RevvFiMarket._updateWeightedAverageAPR()](src/RevvFiMarket.sol#L346-L352)
	- [RevvFiMarket.getCurrentPrincipal()](src/RevvFiMarket.sol#L285-L287)
	- [RevvFiMarket.getTotalOwed()](src/RevvFiMarket.sol#L276-L279)
	- [RevvFiMarket.totalScaledPrincipal](src/RevvFiMarket.sol#L55)
	- [_removePositionWithAPR(posId)](src/RevvFiMarket.sol#L878)
		- [weightedAprNumeratorScaled -= reduction](src/RevvFiMarket.sol#L311)
		- [weightedAprNumeratorScaled = 0](src/RevvFiMarket.sol#L313)
	[RevvFiMarket.weightedAprNumeratorScaled](src/RevvFiMarket.sol#L60) can be used in cross function reentrancies:
	- [RevvFiMarket._updateAPROnPrincipalChange(uint256,uint256,uint256)](src/RevvFiMarket.sol#L324-L341)
	- [RevvFiMarket._updateAPROnRemove(uint256,uint256)](src/RevvFiMarket.sol#L308-L316)
	- [RevvFiMarket._updateWeightedAverageAPR()](src/RevvFiMarket.sol#L346-L352)
	- [RevvFiMarket.weightedAprNumeratorScaled](src/RevvFiMarket.sol#L60)
	- [_removePositionWithAPR(posId)](src/RevvFiMarket.sol#L878)
		- [weightedAverageAPR = 0](src/RevvFiMarket.sol#L348)
		- [weightedAverageAPR = weightedAprNumeratorScaled / totalScaledPrincipal](src/RevvFiMarket.sol#L351)
	[RevvFiMarket.weightedAverageAPR](src/RevvFiMarket.sol#L61) can be used in cross function reentrancies:
	- [RevvFiMarket._accrueInterest()](src/RevvFiMarket.sol#L217-L241)
	- [RevvFiMarket._getUpdatedBorrowIndex()](src/RevvFiMarket.sol#L247-L259)
	- [RevvFiMarket._updateWeightedAverageAPR()](src/RevvFiMarket.sol#L346-L352)
	- [RevvFiMarket.weightedAverageAPR](src/RevvFiMarket.sol#L61)

src/RevvFiMarket.sol#L864-L888


 - [ ] ID-37
Reentrancy in [RevvFiMarket._distributeLoss(uint256)](src/RevvFiMarket.sol#L800-L858):
	External calls:
	- [_settlePosition(posId)](src/RevvFiMarket.sol#L828)
		- [positionNFT.redeemPosition(positionId)](src/RevvFiMarket.sol#L683)
	- [_settlePosition(posId_scope_1)](src/RevvFiMarket.sol#L855)
		- [positionNFT.redeemPosition(positionId)](src/RevvFiMarket.sol#L683)
	State variables written after the call(s):
	- [_removePositionWithAPR(posId_scope_1)](src/RevvFiMarket.sol#L854)
		- [activePositionIds[index] = lastId](src/RevvFiMarket.sol#L379)
		- [activePositionIds.pop()](src/RevvFiMarket.sol#L381)
	[RevvFiMarket.activePositionIds](src/RevvFiMarket.sol#L73) can be used in cross function reentrancies:
	- [RevvFiMarket._distributeLoss(uint256)](src/RevvFiMarket.sol#L800-L858)
	- [RevvFiMarket._distributeRepayment(uint256)](src/RevvFiMarket.sol#L548-L598)
	- [RevvFiMarket._removeActivePosition(uint256)](src/RevvFiMarket.sol#L374-L385)
	- [RevvFiMarket.activePositionIds](src/RevvFiMarket.sol#L73)
	- [RevvFiMarket.getActivePositionsCount()](src/RevvFiMarket.sol#L991-L993)
	- [RevvFiMarket.getActivePositionsPaginated(uint256,uint256)](src/RevvFiMarket.sol#L1001-L1009)
	- [_removePositionWithAPR(posId_scope_1)](src/RevvFiMarket.sol#L854)
		- [activePositionIndex[lastId] = index](src/RevvFiMarket.sol#L380)
		- [delete activePositionIndex[positionId]](src/RevvFiMarket.sol#L383)
	[RevvFiMarket.activePositionIndex](src/RevvFiMarket.sol#L74) can be used in cross function reentrancies:
	- [RevvFiMarket._removeActivePosition(uint256)](src/RevvFiMarket.sol#L374-L385)
	- [RevvFiMarket.activePositionIndex](src/RevvFiMarket.sol#L74)
	- [_removePositionWithAPR(posId_scope_1)](src/RevvFiMarket.sol#L854)
		- [positionActive[positionId] = false](src/RevvFiMarket.sol#L384)
	[RevvFiMarket.positionActive](src/RevvFiMarket.sol#L67) can be used in cross function reentrancies:
	- [RevvFiMarket._distributeLoss(uint256)](src/RevvFiMarket.sol#L800-L858)
	- [RevvFiMarket._distributeRepayment(uint256)](src/RevvFiMarket.sol#L548-L598)
	- [RevvFiMarket._removeActivePosition(uint256)](src/RevvFiMarket.sol#L374-L385)
	- [RevvFiMarket.getPositionValue(uint256)](src/RevvFiMarket.sol#L982-L985)
	- [RevvFiMarket.positionActive](src/RevvFiMarket.sol#L67)
	- [positionScaledPrincipal[posId_scope_1] -= scaledReduction_scope_4](src/RevvFiMarket.sol#L846)
	[RevvFiMarket.positionScaledPrincipal](src/RevvFiMarket.sol#L64) can be used in cross function reentrancies:
	- [RevvFiMarket._distributeLoss(uint256)](src/RevvFiMarket.sol#L800-L858)
	- [RevvFiMarket._distributeRepayment(uint256)](src/RevvFiMarket.sol#L548-L598)
	- [RevvFiMarket._removePositionWithAPR(uint256)](src/RevvFiMarket.sol#L392-L404)
	- [RevvFiMarket.getPositionValue(uint256)](src/RevvFiMarket.sol#L982-L985)
	- [RevvFiMarket.positionScaledPrincipal](src/RevvFiMarket.sol#L64)
	- [_removePositionWithAPR(posId_scope_1)](src/RevvFiMarket.sol#L854)
		- [positionScaledPrincipal[positionId] = 0](src/RevvFiMarket.sol#L396)
	[RevvFiMarket.positionScaledPrincipal](src/RevvFiMarket.sol#L64) can be used in cross function reentrancies:
	- [RevvFiMarket._distributeLoss(uint256)](src/RevvFiMarket.sol#L800-L858)
	- [RevvFiMarket._distributeRepayment(uint256)](src/RevvFiMarket.sol#L548-L598)
	- [RevvFiMarket._removePositionWithAPR(uint256)](src/RevvFiMarket.sol#L392-L404)
	- [RevvFiMarket.getPositionValue(uint256)](src/RevvFiMarket.sol#L982-L985)
	- [RevvFiMarket.positionScaledPrincipal](src/RevvFiMarket.sol#L64)
	- [_settlePosition(posId_scope_1)](src/RevvFiMarket.sol#L855)
		- [positionSettled[positionId] = true](src/RevvFiMarket.sol#L682)
	[RevvFiMarket.positionSettled](src/RevvFiMarket.sol#L68) can be used in cross function reentrancies:
	- [RevvFiMarket._settlePosition(uint256)](src/RevvFiMarket.sol#L674-L684)
	- [RevvFiMarket.positionSettled](src/RevvFiMarket.sol#L68)
	- [_settlePosition(posId_scope_1)](src/RevvFiMarket.sol#L855)
		- [settledPositionOwner[positionId] = positionNFT.ownerOf(positionId)](src/RevvFiMarket.sol#L679)
	[RevvFiMarket.settledPositionOwner](src/RevvFiMarket.sol#L70) can be used in cross function reentrancies:
	- [RevvFiMarket._distributeRepayment(uint256)](src/RevvFiMarket.sol#L548-L598)
	- [RevvFiMarket._settlePosition(uint256)](src/RevvFiMarket.sol#L674-L684)
	- [RevvFiMarket.settledPositionOwner](src/RevvFiMarket.sol#L70)
	- [totalScaledPrincipal -= scaledReduction_scope_4](src/RevvFiMarket.sol#L845)
	[RevvFiMarket.totalScaledPrincipal](src/RevvFiMarket.sol#L55) can be used in cross function reentrancies:
	- [RevvFiMarket._accrueInterest()](src/RevvFiMarket.sol#L217-L241)
	- [RevvFiMarket._distributeLoss(uint256)](src/RevvFiMarket.sol#L800-L858)
	- [RevvFiMarket._distributeRepayment(uint256)](src/RevvFiMarket.sol#L548-L598)
	- [RevvFiMarket._getUpdatedBorrowIndex()](src/RevvFiMarket.sol#L247-L259)
	- [RevvFiMarket._removePositionWithAPR(uint256)](src/RevvFiMarket.sol#L392-L404)
	- [RevvFiMarket._updateWeightedAverageAPR()](src/RevvFiMarket.sol#L346-L352)
	- [RevvFiMarket.getCurrentPrincipal()](src/RevvFiMarket.sol#L285-L287)
	- [RevvFiMarket.getTotalOwed()](src/RevvFiMarket.sol#L276-L279)
	- [RevvFiMarket.totalScaledPrincipal](src/RevvFiMarket.sol#L55)
	- [_removePositionWithAPR(posId_scope_1)](src/RevvFiMarket.sol#L854)
		- [totalScaledPrincipal -= remainingScaled](src/RevvFiMarket.sol#L399)
	[RevvFiMarket.totalScaledPrincipal](src/RevvFiMarket.sol#L55) can be used in cross function reentrancies:
	- [RevvFiMarket._accrueInterest()](src/RevvFiMarket.sol#L217-L241)
	- [RevvFiMarket._distributeLoss(uint256)](src/RevvFiMarket.sol#L800-L858)
	- [RevvFiMarket._distributeRepayment(uint256)](src/RevvFiMarket.sol#L548-L598)
	- [RevvFiMarket._getUpdatedBorrowIndex()](src/RevvFiMarket.sol#L247-L259)
	- [RevvFiMarket._removePositionWithAPR(uint256)](src/RevvFiMarket.sol#L392-L404)
	- [RevvFiMarket._updateWeightedAverageAPR()](src/RevvFiMarket.sol#L346-L352)
	- [RevvFiMarket.getCurrentPrincipal()](src/RevvFiMarket.sol#L285-L287)
	- [RevvFiMarket.getTotalOwed()](src/RevvFiMarket.sol#L276-L279)
	- [RevvFiMarket.totalScaledPrincipal](src/RevvFiMarket.sol#L55)
	- [_updateAPROnPrincipalChange(oldScaledPrincipal_scope_3,positionScaledPrincipal[posId_scope_1],positionApr[posId_scope_1])](src/RevvFiMarket.sol#L848)
		- [weightedAprNumeratorScaled += newContribution - oldContribution](src/RevvFiMarket.sol#L331)
		- [weightedAprNumeratorScaled -= reduction](src/RevvFiMarket.sol#L335)
		- [weightedAprNumeratorScaled = 0](src/RevvFiMarket.sol#L337)
	[RevvFiMarket.weightedAprNumeratorScaled](src/RevvFiMarket.sol#L60) can be used in cross function reentrancies:
	- [RevvFiMarket._updateAPROnPrincipalChange(uint256,uint256,uint256)](src/RevvFiMarket.sol#L324-L341)
	- [RevvFiMarket._updateAPROnRemove(uint256,uint256)](src/RevvFiMarket.sol#L308-L316)
	- [RevvFiMarket._updateWeightedAverageAPR()](src/RevvFiMarket.sol#L346-L352)
	- [RevvFiMarket.weightedAprNumeratorScaled](src/RevvFiMarket.sol#L60)
	- [_removePositionWithAPR(posId_scope_1)](src/RevvFiMarket.sol#L854)
		- [weightedAprNumeratorScaled -= reduction](src/RevvFiMarket.sol#L311)
		- [weightedAprNumeratorScaled = 0](src/RevvFiMarket.sol#L313)
	[RevvFiMarket.weightedAprNumeratorScaled](src/RevvFiMarket.sol#L60) can be used in cross function reentrancies:
	- [RevvFiMarket._updateAPROnPrincipalChange(uint256,uint256,uint256)](src/RevvFiMarket.sol#L324-L341)
	- [RevvFiMarket._updateAPROnRemove(uint256,uint256)](src/RevvFiMarket.sol#L308-L316)
	- [RevvFiMarket._updateWeightedAverageAPR()](src/RevvFiMarket.sol#L346-L352)
	- [RevvFiMarket.weightedAprNumeratorScaled](src/RevvFiMarket.sol#L60)
	- [_updateAPROnPrincipalChange(oldScaledPrincipal_scope_3,positionScaledPrincipal[posId_scope_1],positionApr[posId_scope_1])](src/RevvFiMarket.sol#L848)
		- [weightedAverageAPR = 0](src/RevvFiMarket.sol#L348)
		- [weightedAverageAPR = weightedAprNumeratorScaled / totalScaledPrincipal](src/RevvFiMarket.sol#L351)
	[RevvFiMarket.weightedAverageAPR](src/RevvFiMarket.sol#L61) can be used in cross function reentrancies:
	- [RevvFiMarket._accrueInterest()](src/RevvFiMarket.sol#L217-L241)
	- [RevvFiMarket._getUpdatedBorrowIndex()](src/RevvFiMarket.sol#L247-L259)
	- [RevvFiMarket._updateWeightedAverageAPR()](src/RevvFiMarket.sol#L346-L352)
	- [RevvFiMarket.weightedAverageAPR](src/RevvFiMarket.sol#L61)
	- [_removePositionWithAPR(posId_scope_1)](src/RevvFiMarket.sol#L854)
		- [weightedAverageAPR = 0](src/RevvFiMarket.sol#L348)
		- [weightedAverageAPR = weightedAprNumeratorScaled / totalScaledPrincipal](src/RevvFiMarket.sol#L351)
	[RevvFiMarket.weightedAverageAPR](src/RevvFiMarket.sol#L61) can be used in cross function reentrancies:
	- [RevvFiMarket._accrueInterest()](src/RevvFiMarket.sol#L217-L241)
	- [RevvFiMarket._getUpdatedBorrowIndex()](src/RevvFiMarket.sol#L247-L259)
	- [RevvFiMarket._updateWeightedAverageAPR()](src/RevvFiMarket.sol#L346-L352)
	- [RevvFiMarket.weightedAverageAPR](src/RevvFiMarket.sol#L61)

src/RevvFiMarket.sol#L800-L858


 - [ ] ID-38
Reentrancy in [RevvFiOfferBook.cleanupExpiredOffers(uint256)](src/RevvFiOfferBook.sol#L354-L379):
	External calls:
	- [token.safeTransfer(offer.lender,offer.remainingAmount)](src/RevvFiOfferBook.sol#L367)
	State variables written after the call(s):
	- [_removeActive(offerId)](src/RevvFiOfferBook.sol#L373)
		- [_activeIds[index] = lastId](src/RevvFiOfferBook.sol#L232)
		- [_activeIds.pop()](src/RevvFiOfferBook.sol#L234)
	[RevvFiOfferBook._activeIds](src/RevvFiOfferBook.sol#L78) can be used in cross function reentrancies:
	- [RevvFiOfferBook.getBestOffers(uint256,bool)](src/RevvFiOfferBook.sol#L389-L467)
	- [_removeActive(offerId)](src/RevvFiOfferBook.sol#L373)
		- [activeOfferCount --](src/RevvFiOfferBook.sol#L238)
	[RevvFiOfferBook.activeOfferCount](src/RevvFiOfferBook.sol#L75) can be used in cross function reentrancies:
	- [RevvFiOfferBook.activeOfferCount](src/RevvFiOfferBook.sol#L75)
	- [RevvFiOfferBook.getActiveOfferCount()](src/RevvFiOfferBook.sol#L570-L572)
	- [_removeActive(offerId)](src/RevvFiOfferBook.sol#L373)
		- [bucket.totalLiquidity -= amountRemoved](src/RevvFiOfferBook.sol#L188)
		- [bucket.offerIds[i] = bucket.offerIds[bucket.offerIds.length - 1]](src/RevvFiOfferBook.sol#L197)
		- [bucket.offerIds.pop()](src/RevvFiOfferBook.sol#L198)
	[RevvFiOfferBook.aprBuckets](src/RevvFiOfferBook.sol#L82) can be used in cross function reentrancies:
	- [RevvFiOfferBook.aprBuckets](src/RevvFiOfferBook.sol#L82)
	- [RevvFiOfferBook.getBestOffers(uint256,bool)](src/RevvFiOfferBook.sol#L389-L467)
	- [_removeActive(offerId)](src/RevvFiOfferBook.sol#L373)
		- [isActiveOffer[offerId] = false](src/RevvFiOfferBook.sol#L237)
	[RevvFiOfferBook.isActiveOffer](src/RevvFiOfferBook.sol#L70) can be used in cross function reentrancies:
	- [RevvFiOfferBook.isActiveOffer](src/RevvFiOfferBook.sol#L70)
	- [offer.remainingAmount = 0](src/RevvFiOfferBook.sol#L369)
	[RevvFiOfferBook.offers](src/RevvFiOfferBook.sol#L68) can be used in cross function reentrancies:
	- [RevvFiOfferBook.getBestOffers(uint256,bool)](src/RevvFiOfferBook.sol#L389-L467)
	- [RevvFiOfferBook.getLenderOffers(address)](src/RevvFiOfferBook.sol#L537-L556)
	- [RevvFiOfferBook.getOffer(uint256)](src/RevvFiOfferBook.sol#L528-L530)
	- [RevvFiOfferBook.offers](src/RevvFiOfferBook.sol#L68)
	- [offer.active = false](src/RevvFiOfferBook.sol#L372)
	[RevvFiOfferBook.offers](src/RevvFiOfferBook.sol#L68) can be used in cross function reentrancies:
	- [RevvFiOfferBook.getBestOffers(uint256,bool)](src/RevvFiOfferBook.sol#L389-L467)
	- [RevvFiOfferBook.getLenderOffers(address)](src/RevvFiOfferBook.sol#L537-L556)
	- [RevvFiOfferBook.getOffer(uint256)](src/RevvFiOfferBook.sol#L528-L530)
	- [RevvFiOfferBook.offers](src/RevvFiOfferBook.sol#L68)
	- [totalLiquidity -= offer.remainingAmount](src/RevvFiOfferBook.sol#L368)
	[RevvFiOfferBook.totalLiquidity](src/RevvFiOfferBook.sol#L74) can be used in cross function reentrancies:
	- [RevvFiOfferBook.getTotalLiquidityAvailable()](src/RevvFiOfferBook.sol#L562-L564)
	- [RevvFiOfferBook.totalLiquidity](src/RevvFiOfferBook.sol#L74)

src/RevvFiOfferBook.sol#L354-L379


 - [ ] ID-39
Reentrancy in [RevvFiOfferBook.executeDrawdown(uint256,bool)](src/RevvFiOfferBook.sol#L476-L521):
	External calls:
	- [IERC20(borrowAsset).safeTransfer(market,take)](src/RevvFiOfferBook.sol#L506)
	State variables written after the call(s):
	- [_removeActive(offer.id)](src/RevvFiOfferBook.sol#L511)
		- [_activeIds[index] = lastId](src/RevvFiOfferBook.sol#L232)
		- [_activeIds.pop()](src/RevvFiOfferBook.sol#L234)
	[RevvFiOfferBook._activeIds](src/RevvFiOfferBook.sol#L78) can be used in cross function reentrancies:
	- [RevvFiOfferBook.getBestOffers(uint256,bool)](src/RevvFiOfferBook.sol#L389-L467)
	- [_removeActive(offer.id)](src/RevvFiOfferBook.sol#L511)
		- [activeOfferCount --](src/RevvFiOfferBook.sol#L238)
	[RevvFiOfferBook.activeOfferCount](src/RevvFiOfferBook.sol#L75) can be used in cross function reentrancies:
	- [RevvFiOfferBook.activeOfferCount](src/RevvFiOfferBook.sol#L75)
	- [RevvFiOfferBook.getActiveOfferCount()](src/RevvFiOfferBook.sol#L570-L572)
	- [_removeFromBucket(offer.apr,offer.id,take)](src/RevvFiOfferBook.sol#L500)
		- [bucket.totalLiquidity -= amountRemoved](src/RevvFiOfferBook.sol#L188)
		- [bucket.offerIds[i] = bucket.offerIds[bucket.offerIds.length - 1]](src/RevvFiOfferBook.sol#L197)
		- [bucket.offerIds.pop()](src/RevvFiOfferBook.sol#L198)
	[RevvFiOfferBook.aprBuckets](src/RevvFiOfferBook.sol#L82) can be used in cross function reentrancies:
	- [RevvFiOfferBook.aprBuckets](src/RevvFiOfferBook.sol#L82)
	- [RevvFiOfferBook.getBestOffers(uint256,bool)](src/RevvFiOfferBook.sol#L389-L467)
	- [_removeActive(offer.id)](src/RevvFiOfferBook.sol#L511)
		- [bucket.totalLiquidity -= amountRemoved](src/RevvFiOfferBook.sol#L188)
		- [bucket.offerIds[i] = bucket.offerIds[bucket.offerIds.length - 1]](src/RevvFiOfferBook.sol#L197)
		- [bucket.offerIds.pop()](src/RevvFiOfferBook.sol#L198)
	[RevvFiOfferBook.aprBuckets](src/RevvFiOfferBook.sol#L82) can be used in cross function reentrancies:
	- [RevvFiOfferBook.aprBuckets](src/RevvFiOfferBook.sol#L82)
	- [RevvFiOfferBook.getBestOffers(uint256,bool)](src/RevvFiOfferBook.sol#L389-L467)
	- [_addToBucket(offer.apr,offer.id)](src/RevvFiOfferBook.sol#L513)
		- [oldBucket.offerIds[i] = oldBucket.offerIds[oldBucket.offerIds.length - 1]](src/RevvFiOfferBook.sol#L159)
		- [oldBucket.offerIds.pop()](src/RevvFiOfferBook.sol#L160)
		- [aprBuckets[bucketId].apr = apr](src/RevvFiOfferBook.sol#L168)
		- [aprBuckets[bucketId].offerIds.push(offerId)](src/RevvFiOfferBook.sol#L174)
		- [aprBuckets[bucketId].totalLiquidity += offers[offerId].remainingAmount](src/RevvFiOfferBook.sol#L175)
	[RevvFiOfferBook.aprBuckets](src/RevvFiOfferBook.sol#L82) can be used in cross function reentrancies:
	- [RevvFiOfferBook.aprBuckets](src/RevvFiOfferBook.sol#L82)
	- [RevvFiOfferBook.getBestOffers(uint256,bool)](src/RevvFiOfferBook.sol#L389-L467)
	- [_addToBucket(offer.apr,offer.id)](src/RevvFiOfferBook.sol#L513)
		- [aprValues.push(bucketId)](src/RevvFiOfferBook.sol#L170)
	[RevvFiOfferBook.aprValues](src/RevvFiOfferBook.sol#L83) can be used in cross function reentrancies:
	- [RevvFiOfferBook.aprValues](src/RevvFiOfferBook.sol#L83)
	- [RevvFiOfferBook.getBestOffers(uint256,bool)](src/RevvFiOfferBook.sol#L389-L467)
	- [_removeActive(offer.id)](src/RevvFiOfferBook.sol#L511)
		- [isActiveOffer[offerId] = false](src/RevvFiOfferBook.sol#L237)
	[RevvFiOfferBook.isActiveOffer](src/RevvFiOfferBook.sol#L70) can be used in cross function reentrancies:
	- [RevvFiOfferBook.isActiveOffer](src/RevvFiOfferBook.sol#L70)
	- [_removeFromBucket(offer.apr,offer.id,take)](src/RevvFiOfferBook.sol#L500)
		- [offerInBucketId[offerId] = 0](src/RevvFiOfferBook.sol#L194)
	[RevvFiOfferBook.offerInBucketId](src/RevvFiOfferBook.sol#L88) can be used in cross function reentrancies:
	- [RevvFiOfferBook.offerInBucketId](src/RevvFiOfferBook.sol#L88)
	- [_removeActive(offer.id)](src/RevvFiOfferBook.sol#L511)
		- [offerInBucketId[offerId] = 0](src/RevvFiOfferBook.sol#L194)
	[RevvFiOfferBook.offerInBucketId](src/RevvFiOfferBook.sol#L88) can be used in cross function reentrancies:
	- [RevvFiOfferBook.offerInBucketId](src/RevvFiOfferBook.sol#L88)
	- [_addToBucket(offer.apr,offer.id)](src/RevvFiOfferBook.sol#L513)
		- [offerInBucketId[offerId] = bucketId](src/RevvFiOfferBook.sol#L176)
	[RevvFiOfferBook.offerInBucketId](src/RevvFiOfferBook.sol#L88) can be used in cross function reentrancies:
	- [RevvFiOfferBook.offerInBucketId](src/RevvFiOfferBook.sol#L88)
	- [offer.remainingAmount -= take](src/RevvFiOfferBook.sol#L496)
	[RevvFiOfferBook.offers](src/RevvFiOfferBook.sol#L68) can be used in cross function reentrancies:
	- [RevvFiOfferBook.getBestOffers(uint256,bool)](src/RevvFiOfferBook.sol#L389-L467)
	- [RevvFiOfferBook.getLenderOffers(address)](src/RevvFiOfferBook.sol#L537-L556)
	- [RevvFiOfferBook.getOffer(uint256)](src/RevvFiOfferBook.sol#L528-L530)
	- [RevvFiOfferBook.offers](src/RevvFiOfferBook.sol#L68)
	- [offer.active = false](src/RevvFiOfferBook.sol#L510)
	[RevvFiOfferBook.offers](src/RevvFiOfferBook.sol#L68) can be used in cross function reentrancies:
	- [RevvFiOfferBook.getBestOffers(uint256,bool)](src/RevvFiOfferBook.sol#L389-L467)
	- [RevvFiOfferBook.getLenderOffers(address)](src/RevvFiOfferBook.sol#L537-L556)
	- [RevvFiOfferBook.getOffer(uint256)](src/RevvFiOfferBook.sol#L528-L530)
	- [RevvFiOfferBook.offers](src/RevvFiOfferBook.sol#L68)
	- [totalLiquidity -= take](src/RevvFiOfferBook.sol#L497)
	[RevvFiOfferBook.totalLiquidity](src/RevvFiOfferBook.sol#L74) can be used in cross function reentrancies:
	- [RevvFiOfferBook.getTotalLiquidityAvailable()](src/RevvFiOfferBook.sol#L562-L564)
	- [RevvFiOfferBook.totalLiquidity](src/RevvFiOfferBook.sol#L74)

src/RevvFiOfferBook.sol#L476-L521


 - [ ] ID-40
Reentrancy in [RevvFiMarket.settleLiquidation(uint256,uint256)](src/RevvFiMarket.sol#L756-L785):
	External calls:
	- [_distributeLoss(loss)](src/RevvFiMarket.sol#L767)
		- [positionNFT.redeemPosition(positionId)](src/RevvFiMarket.sol#L683)
	- [_distributeRepayment(debtRepaid)](src/RevvFiMarket.sol#L772)
		- [positionNFT.redeemPosition(positionId)](src/RevvFiMarket.sol#L683)
	- [reputationRegistry.recordDefault(borrower,currentCycleBorrowedAmount,debtRepaid)](src/RevvFiMarket.sol#L777)
	State variables written after the call(s):
	- [currentCycleBorrowedAmount = 0](src/RevvFiMarket.sol#L778)
	[RevvFiMarket.currentCycleBorrowedAmount](src/RevvFiMarket.sol#L90) can be used in cross function reentrancies:
	- [RevvFiMarket.currentCycleBorrowedAmount](src/RevvFiMarket.sol#L90)
	- [RevvFiMarket.settleLiquidation(uint256,uint256)](src/RevvFiMarket.sol#L756-L785)
	- [isLiquidating = false](src/RevvFiMarket.sol#L781)
	[RevvFiMarket.isLiquidating](src/RevvFiMarket.sol#L79) can be used in cross function reentrancies:
	- [RevvFiMarket.isLiquidating](src/RevvFiMarket.sol#L79)
	- [RevvFiMarket.liquidate()](src/RevvFiMarket.sol#L790-L794)
	- [RevvFiMarket.settleLiquidation(uint256,uint256)](src/RevvFiMarket.sol#L756-L785)
	- [RevvFiMarket.startLiquidation()](src/RevvFiMarket.sol#L715-L736)

src/RevvFiMarket.sol#L756-L785


 - [ ] ID-41
Reentrancy in [RevvFiLiquidator.settleAuction(uint256)](src/RevvFiLiquidator.sol#L258-L289):
	External calls:
	- [borrowToken.safeTransfer(auction.market,auction.highestBid)](src/RevvFiLiquidator.sol#L272)
	- [collateralToken.safeTransfer(auction.highestBidder,auction.collateralAmount)](src/RevvFiLiquidator.sol#L276)
	State variables written after the call(s):
	- [auction.active = false](src/RevvFiLiquidator.sol#L278)
	[RevvFiLiquidator.auctions](src/RevvFiLiquidator.sol#L48) can be used in cross function reentrancies:
	- [RevvFiLiquidator.auctions](src/RevvFiLiquidator.sol#L48)
	- [RevvFiLiquidator.cancelAuction(uint256)](src/RevvFiLiquidator.sol#L321-L333)
	- [RevvFiLiquidator.createAuction(address,address,address,address,uint256,uint256)](src/RevvFiLiquidator.sol#L126-L168)
	- [RevvFiLiquidator.getAuction(uint256)](src/RevvFiLiquidator.sol#L344-L346)
	- [RevvFiLiquidator.getCurrentPrice(uint256)](src/RevvFiLiquidator.sol#L177-L191)
	- [RevvFiLiquidator.getWinningBid(uint256)](src/RevvFiLiquidator.sol#L355-L362)
	- [RevvFiLiquidator.receiveCollateral(uint256)](src/RevvFiLiquidator.sol#L199-L203)
	- [auction.settled = true](src/RevvFiLiquidator.sol#L279)
	[RevvFiLiquidator.auctions](src/RevvFiLiquidator.sol#L48) can be used in cross function reentrancies:
	- [RevvFiLiquidator.auctions](src/RevvFiLiquidator.sol#L48)
	- [RevvFiLiquidator.cancelAuction(uint256)](src/RevvFiLiquidator.sol#L321-L333)
	- [RevvFiLiquidator.createAuction(address,address,address,address,uint256,uint256)](src/RevvFiLiquidator.sol#L126-L168)
	- [RevvFiLiquidator.getAuction(uint256)](src/RevvFiLiquidator.sol#L344-L346)
	- [RevvFiLiquidator.getCurrentPrice(uint256)](src/RevvFiLiquidator.sol#L177-L191)
	- [RevvFiLiquidator.getWinningBid(uint256)](src/RevvFiLiquidator.sol#L355-L362)
	- [RevvFiLiquidator.receiveCollateral(uint256)](src/RevvFiLiquidator.sol#L199-L203)

src/RevvFiLiquidator.sol#L258-L289


 - [ ] ID-42
Reentrancy in [RevvFiLiquidator.cancelAuction(uint256)](src/RevvFiLiquidator.sol#L321-L333):
	External calls:
	- [token.safeTransfer(auction.highestBidder,auction.highestBid)](src/RevvFiLiquidator.sol#L328)
	State variables written after the call(s):
	- [auction.active = false](src/RevvFiLiquidator.sol#L331)
	[RevvFiLiquidator.auctions](src/RevvFiLiquidator.sol#L48) can be used in cross function reentrancies:
	- [RevvFiLiquidator.auctions](src/RevvFiLiquidator.sol#L48)
	- [RevvFiLiquidator.cancelAuction(uint256)](src/RevvFiLiquidator.sol#L321-L333)
	- [RevvFiLiquidator.createAuction(address,address,address,address,uint256,uint256)](src/RevvFiLiquidator.sol#L126-L168)
	- [RevvFiLiquidator.getAuction(uint256)](src/RevvFiLiquidator.sol#L344-L346)
	- [RevvFiLiquidator.getCurrentPrice(uint256)](src/RevvFiLiquidator.sol#L177-L191)
	- [RevvFiLiquidator.getWinningBid(uint256)](src/RevvFiLiquidator.sol#L355-L362)
	- [RevvFiLiquidator.receiveCollateral(uint256)](src/RevvFiLiquidator.sol#L199-L203)

src/RevvFiLiquidator.sol#L321-L333


 - [ ] ID-43
Reentrancy in [RevvFiMarket.repay(uint256)](src/RevvFiMarket.sol#L521-L542):
	External calls:
	- [borrowToken.safeTransferFrom(borrower,address(this),amount)](src/RevvFiMarket.sol#L529)
	- [_distributeRepayment(amount)](src/RevvFiMarket.sol#L531)
		- [positionNFT.redeemPosition(positionId)](src/RevvFiMarket.sol#L683)
	- [reputationRegistry.recordSuccessfulRepayment(borrower,currentCycleBorrowedAmount)](src/RevvFiMarket.sol#L536)
	State variables written after the call(s):
	- [currentCycleBorrowedAmount = 0](src/RevvFiMarket.sol#L537)
	[RevvFiMarket.currentCycleBorrowedAmount](src/RevvFiMarket.sol#L90) can be used in cross function reentrancies:
	- [RevvFiMarket.currentCycleBorrowedAmount](src/RevvFiMarket.sol#L90)
	- [RevvFiMarket.settleLiquidation(uint256,uint256)](src/RevvFiMarket.sol#L756-L785)

src/RevvFiMarket.sol#L521-L542


 - [ ] ID-44
Reentrancy in [RevvFiMarket.repayFull()](src/RevvFiMarket.sol#L603-L636):
	External calls:
	- [borrowToken.safeTransferFrom(borrower,address(this),totalDebt)](src/RevvFiMarket.sol#L608)
	- [_settlePosition(posId)](src/RevvFiMarket.sol#L621)
		- [positionNFT.redeemPosition(positionId)](src/RevvFiMarket.sol#L683)
	- [reputationRegistry.recordSuccessfulRepayment(borrower,currentCycleBorrowedAmount)](src/RevvFiMarket.sol#L631)
	State variables written after the call(s):
	- [currentCycleBorrowedAmount = 0](src/RevvFiMarket.sol#L632)
	[RevvFiMarket.currentCycleBorrowedAmount](src/RevvFiMarket.sol#L90) can be used in cross function reentrancies:
	- [RevvFiMarket.currentCycleBorrowedAmount](src/RevvFiMarket.sol#L90)
	- [RevvFiMarket.settleLiquidation(uint256,uint256)](src/RevvFiMarket.sol#L756-L785)

src/RevvFiMarket.sol#L603-L636


 - [ ] ID-45
Reentrancy in [RevvFiMarket.settleLiquidation(uint256,uint256)](src/RevvFiMarket.sol#L756-L785):
	External calls:
	- [_distributeLoss(loss)](src/RevvFiMarket.sol#L767)
		- [positionNFT.redeemPosition(positionId)](src/RevvFiMarket.sol#L683)
	- [_distributeRepayment(debtRepaid)](src/RevvFiMarket.sol#L772)
		- [positionNFT.redeemPosition(positionId)](src/RevvFiMarket.sol#L683)
	State variables written after the call(s):
	- [_distributeRepayment(debtRepaid)](src/RevvFiMarket.sol#L772)
		- [activePositionIds[index] = lastId](src/RevvFiMarket.sol#L379)
		- [activePositionIds.pop()](src/RevvFiMarket.sol#L381)
	[RevvFiMarket.activePositionIds](src/RevvFiMarket.sol#L73) can be used in cross function reentrancies:
	- [RevvFiMarket._distributeLoss(uint256)](src/RevvFiMarket.sol#L800-L858)
	- [RevvFiMarket._distributeRepayment(uint256)](src/RevvFiMarket.sol#L548-L598)
	- [RevvFiMarket._removeActivePosition(uint256)](src/RevvFiMarket.sol#L374-L385)
	- [RevvFiMarket.activePositionIds](src/RevvFiMarket.sol#L73)
	- [RevvFiMarket.getActivePositionsCount()](src/RevvFiMarket.sol#L991-L993)
	- [RevvFiMarket.getActivePositionsPaginated(uint256,uint256)](src/RevvFiMarket.sol#L1001-L1009)
	- [_distributeRepayment(debtRepaid)](src/RevvFiMarket.sol#L772)
		- [activePositionIndex[lastId] = index](src/RevvFiMarket.sol#L380)
		- [delete activePositionIndex[positionId]](src/RevvFiMarket.sol#L383)
	[RevvFiMarket.activePositionIndex](src/RevvFiMarket.sol#L74) can be used in cross function reentrancies:
	- [RevvFiMarket._removeActivePosition(uint256)](src/RevvFiMarket.sol#L374-L385)
	- [RevvFiMarket.activePositionIndex](src/RevvFiMarket.sol#L74)
	- [_distributeRepayment(debtRepaid)](src/RevvFiMarket.sol#L772)
		- [positionActive[positionId] = false](src/RevvFiMarket.sol#L384)
	[RevvFiMarket.positionActive](src/RevvFiMarket.sol#L67) can be used in cross function reentrancies:
	- [RevvFiMarket._distributeLoss(uint256)](src/RevvFiMarket.sol#L800-L858)
	- [RevvFiMarket._distributeRepayment(uint256)](src/RevvFiMarket.sol#L548-L598)
	- [RevvFiMarket._removeActivePosition(uint256)](src/RevvFiMarket.sol#L374-L385)
	- [RevvFiMarket.getPositionValue(uint256)](src/RevvFiMarket.sol#L982-L985)
	- [RevvFiMarket.positionActive](src/RevvFiMarket.sol#L67)
	- [_distributeRepayment(debtRepaid)](src/RevvFiMarket.sol#L772)
		- [positionScaledPrincipal[positionId] = 0](src/RevvFiMarket.sol#L396)
		- [positionScaledPrincipal[posId] -= scaledReduction](src/RevvFiMarket.sol#L574)
	[RevvFiMarket.positionScaledPrincipal](src/RevvFiMarket.sol#L64) can be used in cross function reentrancies:
	- [RevvFiMarket._distributeLoss(uint256)](src/RevvFiMarket.sol#L800-L858)
	- [RevvFiMarket._distributeRepayment(uint256)](src/RevvFiMarket.sol#L548-L598)
	- [RevvFiMarket._removePositionWithAPR(uint256)](src/RevvFiMarket.sol#L392-L404)
	- [RevvFiMarket.getPositionValue(uint256)](src/RevvFiMarket.sol#L982-L985)
	- [RevvFiMarket.positionScaledPrincipal](src/RevvFiMarket.sol#L64)
	- [_distributeRepayment(debtRepaid)](src/RevvFiMarket.sol#L772)
		- [positionSettled[positionId] = true](src/RevvFiMarket.sol#L682)
	[RevvFiMarket.positionSettled](src/RevvFiMarket.sol#L68) can be used in cross function reentrancies:
	- [RevvFiMarket._settlePosition(uint256)](src/RevvFiMarket.sol#L674-L684)
	- [RevvFiMarket.positionSettled](src/RevvFiMarket.sol#L68)
	- [_distributeRepayment(debtRepaid)](src/RevvFiMarket.sol#L772)
		- [settledPositionOwner[positionId] = positionNFT.ownerOf(positionId)](src/RevvFiMarket.sol#L679)
		- [settledPositionOwner[posId_scope_1] = positionNFT.ownerOf(posId_scope_1)](src/RevvFiMarket.sol#L588)
	[RevvFiMarket.settledPositionOwner](src/RevvFiMarket.sol#L70) can be used in cross function reentrancies:
	- [RevvFiMarket._distributeRepayment(uint256)](src/RevvFiMarket.sol#L548-L598)
	- [RevvFiMarket._settlePosition(uint256)](src/RevvFiMarket.sol#L674-L684)
	- [RevvFiMarket.settledPositionOwner](src/RevvFiMarket.sol#L70)
	- [_distributeRepayment(debtRepaid)](src/RevvFiMarket.sol#L772)
		- [totalScaledPrincipal -= remainingScaled](src/RevvFiMarket.sol#L399)
		- [totalScaledPrincipal -= scaledReduction](src/RevvFiMarket.sol#L573)
	[RevvFiMarket.totalScaledPrincipal](src/RevvFiMarket.sol#L55) can be used in cross function reentrancies:
	- [RevvFiMarket._accrueInterest()](src/RevvFiMarket.sol#L217-L241)
	- [RevvFiMarket._distributeLoss(uint256)](src/RevvFiMarket.sol#L800-L858)
	- [RevvFiMarket._distributeRepayment(uint256)](src/RevvFiMarket.sol#L548-L598)
	- [RevvFiMarket._getUpdatedBorrowIndex()](src/RevvFiMarket.sol#L247-L259)
	- [RevvFiMarket._removePositionWithAPR(uint256)](src/RevvFiMarket.sol#L392-L404)
	- [RevvFiMarket._updateWeightedAverageAPR()](src/RevvFiMarket.sol#L346-L352)
	- [RevvFiMarket.getCurrentPrincipal()](src/RevvFiMarket.sol#L285-L287)
	- [RevvFiMarket.getTotalOwed()](src/RevvFiMarket.sol#L276-L279)
	- [RevvFiMarket.totalScaledPrincipal](src/RevvFiMarket.sol#L55)
	- [_distributeRepayment(debtRepaid)](src/RevvFiMarket.sol#L772)
		- [weightedAprNumeratorScaled -= reduction](src/RevvFiMarket.sol#L311)
		- [weightedAprNumeratorScaled = 0](src/RevvFiMarket.sol#L313)
		- [weightedAprNumeratorScaled += newContribution - oldContribution](src/RevvFiMarket.sol#L331)
		- [weightedAprNumeratorScaled -= reduction](src/RevvFiMarket.sol#L335)
		- [weightedAprNumeratorScaled = 0](src/RevvFiMarket.sol#L337)
	[RevvFiMarket.weightedAprNumeratorScaled](src/RevvFiMarket.sol#L60) can be used in cross function reentrancies:
	- [RevvFiMarket._updateAPROnPrincipalChange(uint256,uint256,uint256)](src/RevvFiMarket.sol#L324-L341)
	- [RevvFiMarket._updateAPROnRemove(uint256,uint256)](src/RevvFiMarket.sol#L308-L316)
	- [RevvFiMarket._updateWeightedAverageAPR()](src/RevvFiMarket.sol#L346-L352)
	- [RevvFiMarket.weightedAprNumeratorScaled](src/RevvFiMarket.sol#L60)
	- [_distributeRepayment(debtRepaid)](src/RevvFiMarket.sol#L772)
		- [weightedAverageAPR = 0](src/RevvFiMarket.sol#L348)
		- [weightedAverageAPR = weightedAprNumeratorScaled / totalScaledPrincipal](src/RevvFiMarket.sol#L351)
	[RevvFiMarket.weightedAverageAPR](src/RevvFiMarket.sol#L61) can be used in cross function reentrancies:
	- [RevvFiMarket._accrueInterest()](src/RevvFiMarket.sol#L217-L241)
	- [RevvFiMarket._getUpdatedBorrowIndex()](src/RevvFiMarket.sol#L247-L259)
	- [RevvFiMarket._updateWeightedAverageAPR()](src/RevvFiMarket.sol#L346-L352)
	- [RevvFiMarket.weightedAverageAPR](src/RevvFiMarket.sol#L61)

src/RevvFiMarket.sol#L756-L785


 - [ ] ID-46
Reentrancy in [RevvFiMarket._distributeRepayment(uint256)](src/RevvFiMarket.sol#L548-L598):
	External calls:
	- [_settlePosition(posId_scope_1)](src/RevvFiMarket.sol#L592)
		- [positionNFT.redeemPosition(positionId)](src/RevvFiMarket.sol#L683)
	- [_settlePosition(posId_scope_1)](src/RevvFiMarket.sol#L595)
		- [positionNFT.redeemPosition(positionId)](src/RevvFiMarket.sol#L683)
	State variables written after the call(s):
	- [_removePositionWithAPR(posId_scope_1)](src/RevvFiMarket.sol#L591)
		- [activePositionIds[index] = lastId](src/RevvFiMarket.sol#L379)
		- [activePositionIds.pop()](src/RevvFiMarket.sol#L381)
	[RevvFiMarket.activePositionIds](src/RevvFiMarket.sol#L73) can be used in cross function reentrancies:
	- [RevvFiMarket._distributeLoss(uint256)](src/RevvFiMarket.sol#L800-L858)
	- [RevvFiMarket._distributeRepayment(uint256)](src/RevvFiMarket.sol#L548-L598)
	- [RevvFiMarket._removeActivePosition(uint256)](src/RevvFiMarket.sol#L374-L385)
	- [RevvFiMarket.activePositionIds](src/RevvFiMarket.sol#L73)
	- [RevvFiMarket.getActivePositionsCount()](src/RevvFiMarket.sol#L991-L993)
	- [RevvFiMarket.getActivePositionsPaginated(uint256,uint256)](src/RevvFiMarket.sol#L1001-L1009)
	- [_removePositionWithAPR(posId_scope_1)](src/RevvFiMarket.sol#L594)
		- [activePositionIds[index] = lastId](src/RevvFiMarket.sol#L379)
		- [activePositionIds.pop()](src/RevvFiMarket.sol#L381)
	[RevvFiMarket.activePositionIds](src/RevvFiMarket.sol#L73) can be used in cross function reentrancies:
	- [RevvFiMarket._distributeLoss(uint256)](src/RevvFiMarket.sol#L800-L858)
	- [RevvFiMarket._distributeRepayment(uint256)](src/RevvFiMarket.sol#L548-L598)
	- [RevvFiMarket._removeActivePosition(uint256)](src/RevvFiMarket.sol#L374-L385)
	- [RevvFiMarket.activePositionIds](src/RevvFiMarket.sol#L73)
	- [RevvFiMarket.getActivePositionsCount()](src/RevvFiMarket.sol#L991-L993)
	- [RevvFiMarket.getActivePositionsPaginated(uint256,uint256)](src/RevvFiMarket.sol#L1001-L1009)
	- [_removePositionWithAPR(posId_scope_1)](src/RevvFiMarket.sol#L591)
		- [activePositionIndex[lastId] = index](src/RevvFiMarket.sol#L380)
		- [delete activePositionIndex[positionId]](src/RevvFiMarket.sol#L383)
	[RevvFiMarket.activePositionIndex](src/RevvFiMarket.sol#L74) can be used in cross function reentrancies:
	- [RevvFiMarket._removeActivePosition(uint256)](src/RevvFiMarket.sol#L374-L385)
	- [RevvFiMarket.activePositionIndex](src/RevvFiMarket.sol#L74)
	- [_removePositionWithAPR(posId_scope_1)](src/RevvFiMarket.sol#L594)
		- [activePositionIndex[lastId] = index](src/RevvFiMarket.sol#L380)
		- [delete activePositionIndex[positionId]](src/RevvFiMarket.sol#L383)
	[RevvFiMarket.activePositionIndex](src/RevvFiMarket.sol#L74) can be used in cross function reentrancies:
	- [RevvFiMarket._removeActivePosition(uint256)](src/RevvFiMarket.sol#L374-L385)
	- [RevvFiMarket.activePositionIndex](src/RevvFiMarket.sol#L74)
	- [_removePositionWithAPR(posId_scope_1)](src/RevvFiMarket.sol#L591)
		- [positionActive[positionId] = false](src/RevvFiMarket.sol#L384)
	[RevvFiMarket.positionActive](src/RevvFiMarket.sol#L67) can be used in cross function reentrancies:
	- [RevvFiMarket._distributeLoss(uint256)](src/RevvFiMarket.sol#L800-L858)
	- [RevvFiMarket._distributeRepayment(uint256)](src/RevvFiMarket.sol#L548-L598)
	- [RevvFiMarket._removeActivePosition(uint256)](src/RevvFiMarket.sol#L374-L385)
	- [RevvFiMarket.getPositionValue(uint256)](src/RevvFiMarket.sol#L982-L985)
	- [RevvFiMarket.positionActive](src/RevvFiMarket.sol#L67)
	- [_removePositionWithAPR(posId_scope_1)](src/RevvFiMarket.sol#L594)
		- [positionActive[positionId] = false](src/RevvFiMarket.sol#L384)
	[RevvFiMarket.positionActive](src/RevvFiMarket.sol#L67) can be used in cross function reentrancies:
	- [RevvFiMarket._distributeLoss(uint256)](src/RevvFiMarket.sol#L800-L858)
	- [RevvFiMarket._distributeRepayment(uint256)](src/RevvFiMarket.sol#L548-L598)
	- [RevvFiMarket._removeActivePosition(uint256)](src/RevvFiMarket.sol#L374-L385)
	- [RevvFiMarket.getPositionValue(uint256)](src/RevvFiMarket.sol#L982-L985)
	- [RevvFiMarket.positionActive](src/RevvFiMarket.sol#L67)
	- [positionClaimableAmount[posId_scope_1] += positionDebt_scope_2](src/RevvFiMarket.sol#L590)
	[RevvFiMarket.positionClaimableAmount](src/RevvFiMarket.sol#L69) can be used in cross function reentrancies:
	- [RevvFiMarket._distributeRepayment(uint256)](src/RevvFiMarket.sol#L548-L598)
	- [RevvFiMarket.getPositionClaimable(uint256)](src/RevvFiMarket.sol#L973-L975)
	- [RevvFiMarket.positionClaimableAmount](src/RevvFiMarket.sol#L69)
	- [_removePositionWithAPR(posId_scope_1)](src/RevvFiMarket.sol#L591)
		- [positionScaledPrincipal[positionId] = 0](src/RevvFiMarket.sol#L396)
	[RevvFiMarket.positionScaledPrincipal](src/RevvFiMarket.sol#L64) can be used in cross function reentrancies:
	- [RevvFiMarket._distributeLoss(uint256)](src/RevvFiMarket.sol#L800-L858)
	- [RevvFiMarket._distributeRepayment(uint256)](src/RevvFiMarket.sol#L548-L598)
	- [RevvFiMarket._removePositionWithAPR(uint256)](src/RevvFiMarket.sol#L392-L404)
	- [RevvFiMarket.getPositionValue(uint256)](src/RevvFiMarket.sol#L982-L985)
	- [RevvFiMarket.positionScaledPrincipal](src/RevvFiMarket.sol#L64)
	- [_removePositionWithAPR(posId_scope_1)](src/RevvFiMarket.sol#L594)
		- [positionScaledPrincipal[positionId] = 0](src/RevvFiMarket.sol#L396)
	[RevvFiMarket.positionScaledPrincipal](src/RevvFiMarket.sol#L64) can be used in cross function reentrancies:
	- [RevvFiMarket._distributeLoss(uint256)](src/RevvFiMarket.sol#L800-L858)
	- [RevvFiMarket._distributeRepayment(uint256)](src/RevvFiMarket.sol#L548-L598)
	- [RevvFiMarket._removePositionWithAPR(uint256)](src/RevvFiMarket.sol#L392-L404)
	- [RevvFiMarket.getPositionValue(uint256)](src/RevvFiMarket.sol#L982-L985)
	- [RevvFiMarket.positionScaledPrincipal](src/RevvFiMarket.sol#L64)
	- [_settlePosition(posId_scope_1)](src/RevvFiMarket.sol#L592)
		- [positionSettled[positionId] = true](src/RevvFiMarket.sol#L682)
	[RevvFiMarket.positionSettled](src/RevvFiMarket.sol#L68) can be used in cross function reentrancies:
	- [RevvFiMarket._settlePosition(uint256)](src/RevvFiMarket.sol#L674-L684)
	- [RevvFiMarket.positionSettled](src/RevvFiMarket.sol#L68)
	- [_settlePosition(posId_scope_1)](src/RevvFiMarket.sol#L595)
		- [positionSettled[positionId] = true](src/RevvFiMarket.sol#L682)
	[RevvFiMarket.positionSettled](src/RevvFiMarket.sol#L68) can be used in cross function reentrancies:
	- [RevvFiMarket._settlePosition(uint256)](src/RevvFiMarket.sol#L674-L684)
	- [RevvFiMarket.positionSettled](src/RevvFiMarket.sol#L68)
	- [settledPositionOwner[posId_scope_1] = positionNFT.ownerOf(posId_scope_1)](src/RevvFiMarket.sol#L588)
	[RevvFiMarket.settledPositionOwner](src/RevvFiMarket.sol#L70) can be used in cross function reentrancies:
	- [RevvFiMarket._distributeRepayment(uint256)](src/RevvFiMarket.sol#L548-L598)
	- [RevvFiMarket._settlePosition(uint256)](src/RevvFiMarket.sol#L674-L684)
	- [RevvFiMarket.settledPositionOwner](src/RevvFiMarket.sol#L70)
	- [_settlePosition(posId_scope_1)](src/RevvFiMarket.sol#L592)
		- [settledPositionOwner[positionId] = positionNFT.ownerOf(positionId)](src/RevvFiMarket.sol#L679)
	[RevvFiMarket.settledPositionOwner](src/RevvFiMarket.sol#L70) can be used in cross function reentrancies:
	- [RevvFiMarket._distributeRepayment(uint256)](src/RevvFiMarket.sol#L548-L598)
	- [RevvFiMarket._settlePosition(uint256)](src/RevvFiMarket.sol#L674-L684)
	- [RevvFiMarket.settledPositionOwner](src/RevvFiMarket.sol#L70)
	- [_settlePosition(posId_scope_1)](src/RevvFiMarket.sol#L595)
		- [settledPositionOwner[positionId] = positionNFT.ownerOf(positionId)](src/RevvFiMarket.sol#L679)
	[RevvFiMarket.settledPositionOwner](src/RevvFiMarket.sol#L70) can be used in cross function reentrancies:
	- [RevvFiMarket._distributeRepayment(uint256)](src/RevvFiMarket.sol#L548-L598)
	- [RevvFiMarket._settlePosition(uint256)](src/RevvFiMarket.sol#L674-L684)
	- [RevvFiMarket.settledPositionOwner](src/RevvFiMarket.sol#L70)
	- [_removePositionWithAPR(posId_scope_1)](src/RevvFiMarket.sol#L591)
		- [totalScaledPrincipal -= remainingScaled](src/RevvFiMarket.sol#L399)
	[RevvFiMarket.totalScaledPrincipal](src/RevvFiMarket.sol#L55) can be used in cross function reentrancies:
	- [RevvFiMarket._accrueInterest()](src/RevvFiMarket.sol#L217-L241)
	- [RevvFiMarket._distributeLoss(uint256)](src/RevvFiMarket.sol#L800-L858)
	- [RevvFiMarket._distributeRepayment(uint256)](src/RevvFiMarket.sol#L548-L598)
	- [RevvFiMarket._getUpdatedBorrowIndex()](src/RevvFiMarket.sol#L247-L259)
	- [RevvFiMarket._removePositionWithAPR(uint256)](src/RevvFiMarket.sol#L392-L404)
	- [RevvFiMarket._updateWeightedAverageAPR()](src/RevvFiMarket.sol#L346-L352)
	- [RevvFiMarket.getCurrentPrincipal()](src/RevvFiMarket.sol#L285-L287)
	- [RevvFiMarket.getTotalOwed()](src/RevvFiMarket.sol#L276-L279)
	- [RevvFiMarket.totalScaledPrincipal](src/RevvFiMarket.sol#L55)
	- [_removePositionWithAPR(posId_scope_1)](src/RevvFiMarket.sol#L594)
		- [totalScaledPrincipal -= remainingScaled](src/RevvFiMarket.sol#L399)
	[RevvFiMarket.totalScaledPrincipal](src/RevvFiMarket.sol#L55) can be used in cross function reentrancies:
	- [RevvFiMarket._accrueInterest()](src/RevvFiMarket.sol#L217-L241)
	- [RevvFiMarket._distributeLoss(uint256)](src/RevvFiMarket.sol#L800-L858)
	- [RevvFiMarket._distributeRepayment(uint256)](src/RevvFiMarket.sol#L548-L598)
	- [RevvFiMarket._getUpdatedBorrowIndex()](src/RevvFiMarket.sol#L247-L259)
	- [RevvFiMarket._removePositionWithAPR(uint256)](src/RevvFiMarket.sol#L392-L404)
	- [RevvFiMarket._updateWeightedAverageAPR()](src/RevvFiMarket.sol#L346-L352)
	- [RevvFiMarket.getCurrentPrincipal()](src/RevvFiMarket.sol#L285-L287)
	- [RevvFiMarket.getTotalOwed()](src/RevvFiMarket.sol#L276-L279)
	- [RevvFiMarket.totalScaledPrincipal](src/RevvFiMarket.sol#L55)
	- [_removePositionWithAPR(posId_scope_1)](src/RevvFiMarket.sol#L591)
		- [weightedAprNumeratorScaled -= reduction](src/RevvFiMarket.sol#L311)
		- [weightedAprNumeratorScaled = 0](src/RevvFiMarket.sol#L313)
	[RevvFiMarket.weightedAprNumeratorScaled](src/RevvFiMarket.sol#L60) can be used in cross function reentrancies:
	- [RevvFiMarket._updateAPROnPrincipalChange(uint256,uint256,uint256)](src/RevvFiMarket.sol#L324-L341)
	- [RevvFiMarket._updateAPROnRemove(uint256,uint256)](src/RevvFiMarket.sol#L308-L316)
	- [RevvFiMarket._updateWeightedAverageAPR()](src/RevvFiMarket.sol#L346-L352)
	- [RevvFiMarket.weightedAprNumeratorScaled](src/RevvFiMarket.sol#L60)
	- [_removePositionWithAPR(posId_scope_1)](src/RevvFiMarket.sol#L594)
		- [weightedAprNumeratorScaled -= reduction](src/RevvFiMarket.sol#L311)
		- [weightedAprNumeratorScaled = 0](src/RevvFiMarket.sol#L313)
	[RevvFiMarket.weightedAprNumeratorScaled](src/RevvFiMarket.sol#L60) can be used in cross function reentrancies:
	- [RevvFiMarket._updateAPROnPrincipalChange(uint256,uint256,uint256)](src/RevvFiMarket.sol#L324-L341)
	- [RevvFiMarket._updateAPROnRemove(uint256,uint256)](src/RevvFiMarket.sol#L308-L316)
	- [RevvFiMarket._updateWeightedAverageAPR()](src/RevvFiMarket.sol#L346-L352)
	- [RevvFiMarket.weightedAprNumeratorScaled](src/RevvFiMarket.sol#L60)
	- [_removePositionWithAPR(posId_scope_1)](src/RevvFiMarket.sol#L591)
		- [weightedAverageAPR = 0](src/RevvFiMarket.sol#L348)
		- [weightedAverageAPR = weightedAprNumeratorScaled / totalScaledPrincipal](src/RevvFiMarket.sol#L351)
	[RevvFiMarket.weightedAverageAPR](src/RevvFiMarket.sol#L61) can be used in cross function reentrancies:
	- [RevvFiMarket._accrueInterest()](src/RevvFiMarket.sol#L217-L241)
	- [RevvFiMarket._getUpdatedBorrowIndex()](src/RevvFiMarket.sol#L247-L259)
	- [RevvFiMarket._updateWeightedAverageAPR()](src/RevvFiMarket.sol#L346-L352)
	- [RevvFiMarket.weightedAverageAPR](src/RevvFiMarket.sol#L61)
	- [_removePositionWithAPR(posId_scope_1)](src/RevvFiMarket.sol#L594)
		- [weightedAverageAPR = 0](src/RevvFiMarket.sol#L348)
		- [weightedAverageAPR = weightedAprNumeratorScaled / totalScaledPrincipal](src/RevvFiMarket.sol#L351)
	[RevvFiMarket.weightedAverageAPR](src/RevvFiMarket.sol#L61) can be used in cross function reentrancies:
	- [RevvFiMarket._accrueInterest()](src/RevvFiMarket.sol#L217-L241)
	- [RevvFiMarket._getUpdatedBorrowIndex()](src/RevvFiMarket.sol#L247-L259)
	- [RevvFiMarket._updateWeightedAverageAPR()](src/RevvFiMarket.sol#L346-L352)
	- [RevvFiMarket.weightedAverageAPR](src/RevvFiMarket.sol#L61)

src/RevvFiMarket.sol#L548-L598


 - [ ] ID-47
Reentrancy in [RevvFiMarket._distributeLoss(uint256)](src/RevvFiMarket.sol#L800-L858):
	External calls:
	- [_settlePosition(posId)](src/RevvFiMarket.sol#L828)
		- [positionNFT.redeemPosition(positionId)](src/RevvFiMarket.sol#L683)
	State variables written after the call(s):
	- [_removePositionWithAPR(posId)](src/RevvFiMarket.sol#L827)
		- [activePositionIds[index] = lastId](src/RevvFiMarket.sol#L379)
		- [activePositionIds.pop()](src/RevvFiMarket.sol#L381)
	[RevvFiMarket.activePositionIds](src/RevvFiMarket.sol#L73) can be used in cross function reentrancies:
	- [RevvFiMarket._distributeLoss(uint256)](src/RevvFiMarket.sol#L800-L858)
	- [RevvFiMarket._distributeRepayment(uint256)](src/RevvFiMarket.sol#L548-L598)
	- [RevvFiMarket._removeActivePosition(uint256)](src/RevvFiMarket.sol#L374-L385)
	- [RevvFiMarket.activePositionIds](src/RevvFiMarket.sol#L73)
	- [RevvFiMarket.getActivePositionsCount()](src/RevvFiMarket.sol#L991-L993)
	- [RevvFiMarket.getActivePositionsPaginated(uint256,uint256)](src/RevvFiMarket.sol#L1001-L1009)
	- [_removePositionWithAPR(posId)](src/RevvFiMarket.sol#L827)
		- [activePositionIndex[lastId] = index](src/RevvFiMarket.sol#L380)
		- [delete activePositionIndex[positionId]](src/RevvFiMarket.sol#L383)
	[RevvFiMarket.activePositionIndex](src/RevvFiMarket.sol#L74) can be used in cross function reentrancies:
	- [RevvFiMarket._removeActivePosition(uint256)](src/RevvFiMarket.sol#L374-L385)
	- [RevvFiMarket.activePositionIndex](src/RevvFiMarket.sol#L74)
	- [_removePositionWithAPR(posId)](src/RevvFiMarket.sol#L827)
		- [positionActive[positionId] = false](src/RevvFiMarket.sol#L384)
	[RevvFiMarket.positionActive](src/RevvFiMarket.sol#L67) can be used in cross function reentrancies:
	- [RevvFiMarket._distributeLoss(uint256)](src/RevvFiMarket.sol#L800-L858)
	- [RevvFiMarket._distributeRepayment(uint256)](src/RevvFiMarket.sol#L548-L598)
	- [RevvFiMarket._removeActivePosition(uint256)](src/RevvFiMarket.sol#L374-L385)
	- [RevvFiMarket.getPositionValue(uint256)](src/RevvFiMarket.sol#L982-L985)
	- [RevvFiMarket.positionActive](src/RevvFiMarket.sol#L67)
	- [positionScaledPrincipal[posId] -= scaledReduction](src/RevvFiMarket.sol#L819)
	[RevvFiMarket.positionScaledPrincipal](src/RevvFiMarket.sol#L64) can be used in cross function reentrancies:
	- [RevvFiMarket._distributeLoss(uint256)](src/RevvFiMarket.sol#L800-L858)
	- [RevvFiMarket._distributeRepayment(uint256)](src/RevvFiMarket.sol#L548-L598)
	- [RevvFiMarket._removePositionWithAPR(uint256)](src/RevvFiMarket.sol#L392-L404)
	- [RevvFiMarket.getPositionValue(uint256)](src/RevvFiMarket.sol#L982-L985)
	- [RevvFiMarket.positionScaledPrincipal](src/RevvFiMarket.sol#L64)
	- [_removePositionWithAPR(posId)](src/RevvFiMarket.sol#L827)
		- [positionScaledPrincipal[positionId] = 0](src/RevvFiMarket.sol#L396)
	[RevvFiMarket.positionScaledPrincipal](src/RevvFiMarket.sol#L64) can be used in cross function reentrancies:
	- [RevvFiMarket._distributeLoss(uint256)](src/RevvFiMarket.sol#L800-L858)
	- [RevvFiMarket._distributeRepayment(uint256)](src/RevvFiMarket.sol#L548-L598)
	- [RevvFiMarket._removePositionWithAPR(uint256)](src/RevvFiMarket.sol#L392-L404)
	- [RevvFiMarket.getPositionValue(uint256)](src/RevvFiMarket.sol#L982-L985)
	- [RevvFiMarket.positionScaledPrincipal](src/RevvFiMarket.sol#L64)
	- [totalScaledPrincipal -= scaledReduction](src/RevvFiMarket.sol#L818)
	[RevvFiMarket.totalScaledPrincipal](src/RevvFiMarket.sol#L55) can be used in cross function reentrancies:
	- [RevvFiMarket._accrueInterest()](src/RevvFiMarket.sol#L217-L241)
	- [RevvFiMarket._distributeLoss(uint256)](src/RevvFiMarket.sol#L800-L858)
	- [RevvFiMarket._distributeRepayment(uint256)](src/RevvFiMarket.sol#L548-L598)
	- [RevvFiMarket._getUpdatedBorrowIndex()](src/RevvFiMarket.sol#L247-L259)
	- [RevvFiMarket._removePositionWithAPR(uint256)](src/RevvFiMarket.sol#L392-L404)
	- [RevvFiMarket._updateWeightedAverageAPR()](src/RevvFiMarket.sol#L346-L352)
	- [RevvFiMarket.getCurrentPrincipal()](src/RevvFiMarket.sol#L285-L287)
	- [RevvFiMarket.getTotalOwed()](src/RevvFiMarket.sol#L276-L279)
	- [RevvFiMarket.totalScaledPrincipal](src/RevvFiMarket.sol#L55)
	- [_removePositionWithAPR(posId)](src/RevvFiMarket.sol#L827)
		- [totalScaledPrincipal -= remainingScaled](src/RevvFiMarket.sol#L399)
	[RevvFiMarket.totalScaledPrincipal](src/RevvFiMarket.sol#L55) can be used in cross function reentrancies:
	- [RevvFiMarket._accrueInterest()](src/RevvFiMarket.sol#L217-L241)
	- [RevvFiMarket._distributeLoss(uint256)](src/RevvFiMarket.sol#L800-L858)
	- [RevvFiMarket._distributeRepayment(uint256)](src/RevvFiMarket.sol#L548-L598)
	- [RevvFiMarket._getUpdatedBorrowIndex()](src/RevvFiMarket.sol#L247-L259)
	- [RevvFiMarket._removePositionWithAPR(uint256)](src/RevvFiMarket.sol#L392-L404)
	- [RevvFiMarket._updateWeightedAverageAPR()](src/RevvFiMarket.sol#L346-L352)
	- [RevvFiMarket.getCurrentPrincipal()](src/RevvFiMarket.sol#L285-L287)
	- [RevvFiMarket.getTotalOwed()](src/RevvFiMarket.sol#L276-L279)
	- [RevvFiMarket.totalScaledPrincipal](src/RevvFiMarket.sol#L55)
	- [_updateAPROnPrincipalChange(oldScaledPrincipal,positionScaledPrincipal[posId],positionApr[posId])](src/RevvFiMarket.sol#L821)
		- [weightedAprNumeratorScaled += newContribution - oldContribution](src/RevvFiMarket.sol#L331)
		- [weightedAprNumeratorScaled -= reduction](src/RevvFiMarket.sol#L335)
		- [weightedAprNumeratorScaled = 0](src/RevvFiMarket.sol#L337)
	[RevvFiMarket.weightedAprNumeratorScaled](src/RevvFiMarket.sol#L60) can be used in cross function reentrancies:
	- [RevvFiMarket._updateAPROnPrincipalChange(uint256,uint256,uint256)](src/RevvFiMarket.sol#L324-L341)
	- [RevvFiMarket._updateAPROnRemove(uint256,uint256)](src/RevvFiMarket.sol#L308-L316)
	- [RevvFiMarket._updateWeightedAverageAPR()](src/RevvFiMarket.sol#L346-L352)
	- [RevvFiMarket.weightedAprNumeratorScaled](src/RevvFiMarket.sol#L60)
	- [_removePositionWithAPR(posId)](src/RevvFiMarket.sol#L827)
		- [weightedAprNumeratorScaled -= reduction](src/RevvFiMarket.sol#L311)
		- [weightedAprNumeratorScaled = 0](src/RevvFiMarket.sol#L313)
	[RevvFiMarket.weightedAprNumeratorScaled](src/RevvFiMarket.sol#L60) can be used in cross function reentrancies:
	- [RevvFiMarket._updateAPROnPrincipalChange(uint256,uint256,uint256)](src/RevvFiMarket.sol#L324-L341)
	- [RevvFiMarket._updateAPROnRemove(uint256,uint256)](src/RevvFiMarket.sol#L308-L316)
	- [RevvFiMarket._updateWeightedAverageAPR()](src/RevvFiMarket.sol#L346-L352)
	- [RevvFiMarket.weightedAprNumeratorScaled](src/RevvFiMarket.sol#L60)
	- [_updateAPROnPrincipalChange(oldScaledPrincipal,positionScaledPrincipal[posId],positionApr[posId])](src/RevvFiMarket.sol#L821)
		- [weightedAverageAPR = 0](src/RevvFiMarket.sol#L348)
		- [weightedAverageAPR = weightedAprNumeratorScaled / totalScaledPrincipal](src/RevvFiMarket.sol#L351)
	[RevvFiMarket.weightedAverageAPR](src/RevvFiMarket.sol#L61) can be used in cross function reentrancies:
	- [RevvFiMarket._accrueInterest()](src/RevvFiMarket.sol#L217-L241)
	- [RevvFiMarket._getUpdatedBorrowIndex()](src/RevvFiMarket.sol#L247-L259)
	- [RevvFiMarket._updateWeightedAverageAPR()](src/RevvFiMarket.sol#L346-L352)
	- [RevvFiMarket.weightedAverageAPR](src/RevvFiMarket.sol#L61)
	- [_removePositionWithAPR(posId)](src/RevvFiMarket.sol#L827)
		- [weightedAverageAPR = 0](src/RevvFiMarket.sol#L348)
		- [weightedAverageAPR = weightedAprNumeratorScaled / totalScaledPrincipal](src/RevvFiMarket.sol#L351)
	[RevvFiMarket.weightedAverageAPR](src/RevvFiMarket.sol#L61) can be used in cross function reentrancies:
	- [RevvFiMarket._accrueInterest()](src/RevvFiMarket.sol#L217-L241)
	- [RevvFiMarket._getUpdatedBorrowIndex()](src/RevvFiMarket.sol#L247-L259)
	- [RevvFiMarket._updateWeightedAverageAPR()](src/RevvFiMarket.sol#L346-L352)
	- [RevvFiMarket.weightedAverageAPR](src/RevvFiMarket.sol#L61)

src/RevvFiMarket.sol#L800-L858


 - [ ] ID-48
Reentrancy in [RevvFiMarket.borrow(uint256,bool,uint256)](src/RevvFiMarket.sol#L449-L515):
	External calls:
	- [(filledOffers,weightedApr) = offerBook.executeDrawdown(amount,useSeniorOnly)](src/RevvFiMarket.sol#L464-L465)
	- [tokenId = positionNFT.mintPosition(filledOffers[i].lender,address(this),filledOffers[i].remainingAmount,filledOffers[i].apr,filledOffers[i].seniority)](src/RevvFiMarket.sol#L482-L488)
	State variables written after the call(s):
	- [_addActivePosition(tokenId)](src/RevvFiMarket.sol#L501)
		- [activePositionIds.push(positionId)](src/RevvFiMarket.sol#L364)
	[RevvFiMarket.activePositionIds](src/RevvFiMarket.sol#L73) can be used in cross function reentrancies:
	- [RevvFiMarket._distributeLoss(uint256)](src/RevvFiMarket.sol#L800-L858)
	- [RevvFiMarket._distributeRepayment(uint256)](src/RevvFiMarket.sol#L548-L598)
	- [RevvFiMarket._removeActivePosition(uint256)](src/RevvFiMarket.sol#L374-L385)
	- [RevvFiMarket.activePositionIds](src/RevvFiMarket.sol#L73)
	- [RevvFiMarket.getActivePositionsCount()](src/RevvFiMarket.sol#L991-L993)
	- [RevvFiMarket.getActivePositionsPaginated(uint256,uint256)](src/RevvFiMarket.sol#L1001-L1009)
	- [lenderPositions[filledOffers[i].lender].push(tokenId)](src/RevvFiMarket.sol#L490)
	[RevvFiMarket.lenderPositions](src/RevvFiMarket.sol#L85) can be used in cross function reentrancies:
	- [RevvFiMarket.lenderPositions](src/RevvFiMarket.sol#L85)
	- [positionApr[tokenId] = filledOffers[i].apr](src/RevvFiMarket.sol#L495)
	[RevvFiMarket.positionApr](src/RevvFiMarket.sol#L65) can be used in cross function reentrancies:
	- [RevvFiMarket._distributeLoss(uint256)](src/RevvFiMarket.sol#L800-L858)
	- [RevvFiMarket._distributeRepayment(uint256)](src/RevvFiMarket.sol#L548-L598)
	- [RevvFiMarket._removePositionWithAPR(uint256)](src/RevvFiMarket.sol#L392-L404)
	- [RevvFiMarket.positionApr](src/RevvFiMarket.sol#L65)
	- [positionScaledPrincipal[tokenId] = scaledPrincipal](src/RevvFiMarket.sol#L494)
	[RevvFiMarket.positionScaledPrincipal](src/RevvFiMarket.sol#L64) can be used in cross function reentrancies:
	- [RevvFiMarket._distributeLoss(uint256)](src/RevvFiMarket.sol#L800-L858)
	- [RevvFiMarket._distributeRepayment(uint256)](src/RevvFiMarket.sol#L548-L598)
	- [RevvFiMarket._removePositionWithAPR(uint256)](src/RevvFiMarket.sol#L392-L404)
	- [RevvFiMarket.getPositionValue(uint256)](src/RevvFiMarket.sol#L982-L985)
	- [RevvFiMarket.positionScaledPrincipal](src/RevvFiMarket.sol#L64)
	- [totalScaledPrincipal += scaledPrincipal](src/RevvFiMarket.sol#L500)
	[RevvFiMarket.totalScaledPrincipal](src/RevvFiMarket.sol#L55) can be used in cross function reentrancies:
	- [RevvFiMarket._accrueInterest()](src/RevvFiMarket.sol#L217-L241)
	- [RevvFiMarket._distributeLoss(uint256)](src/RevvFiMarket.sol#L800-L858)
	- [RevvFiMarket._distributeRepayment(uint256)](src/RevvFiMarket.sol#L548-L598)
	- [RevvFiMarket._getUpdatedBorrowIndex()](src/RevvFiMarket.sol#L247-L259)
	- [RevvFiMarket._removePositionWithAPR(uint256)](src/RevvFiMarket.sol#L392-L404)
	- [RevvFiMarket._updateWeightedAverageAPR()](src/RevvFiMarket.sol#L346-L352)
	- [RevvFiMarket.getCurrentPrincipal()](src/RevvFiMarket.sol#L285-L287)
	- [RevvFiMarket.getTotalOwed()](src/RevvFiMarket.sol#L276-L279)
	- [RevvFiMarket.totalScaledPrincipal](src/RevvFiMarket.sol#L55)
	- [_addActivePosition(tokenId)](src/RevvFiMarket.sol#L501)
		- [weightedAprNumeratorScaled += scaledPrincipal * apr](src/RevvFiMarket.sol#L299)
	[RevvFiMarket.weightedAprNumeratorScaled](src/RevvFiMarket.sol#L60) can be used in cross function reentrancies:
	- [RevvFiMarket._updateAPROnPrincipalChange(uint256,uint256,uint256)](src/RevvFiMarket.sol#L324-L341)
	- [RevvFiMarket._updateAPROnRemove(uint256,uint256)](src/RevvFiMarket.sol#L308-L316)
	- [RevvFiMarket._updateWeightedAverageAPR()](src/RevvFiMarket.sol#L346-L352)
	- [RevvFiMarket.weightedAprNumeratorScaled](src/RevvFiMarket.sol#L60)
	- [_addActivePosition(tokenId)](src/RevvFiMarket.sol#L501)
		- [weightedAverageAPR = 0](src/RevvFiMarket.sol#L348)
		- [weightedAverageAPR = weightedAprNumeratorScaled / totalScaledPrincipal](src/RevvFiMarket.sol#L351)
	[RevvFiMarket.weightedAverageAPR](src/RevvFiMarket.sol#L61) can be used in cross function reentrancies:
	- [RevvFiMarket._accrueInterest()](src/RevvFiMarket.sol#L217-L241)
	- [RevvFiMarket._getUpdatedBorrowIndex()](src/RevvFiMarket.sol#L247-L259)
	- [RevvFiMarket._updateWeightedAverageAPR()](src/RevvFiMarket.sol#L346-L352)
	- [RevvFiMarket.weightedAverageAPR](src/RevvFiMarket.sol#L61)

src/RevvFiMarket.sol#L449-L515


 - [ ] ID-49
Reentrancy in [RevvFiLiquidator.placeBid(uint256,uint256)](src/RevvFiLiquidator.sol#L216-L249):
	External calls:
	- [token.safeTransfer(auction.highestBidder,auction.highestBid)](src/RevvFiLiquidator.sol#L234)
	- [token.safeTransferFrom(msg.sender,address(this),bidAmount)](src/RevvFiLiquidator.sol#L238)
	State variables written after the call(s):
	- [auction.highestBid = bidAmount](src/RevvFiLiquidator.sol#L240)
	[RevvFiLiquidator.auctions](src/RevvFiLiquidator.sol#L48) can be used in cross function reentrancies:
	- [RevvFiLiquidator.auctions](src/RevvFiLiquidator.sol#L48)
	- [RevvFiLiquidator.cancelAuction(uint256)](src/RevvFiLiquidator.sol#L321-L333)
	- [RevvFiLiquidator.createAuction(address,address,address,address,uint256,uint256)](src/RevvFiLiquidator.sol#L126-L168)
	- [RevvFiLiquidator.getAuction(uint256)](src/RevvFiLiquidator.sol#L344-L346)
	- [RevvFiLiquidator.getCurrentPrice(uint256)](src/RevvFiLiquidator.sol#L177-L191)
	- [RevvFiLiquidator.getWinningBid(uint256)](src/RevvFiLiquidator.sol#L355-L362)
	- [RevvFiLiquidator.receiveCollateral(uint256)](src/RevvFiLiquidator.sol#L199-L203)
	- [auction.highestBidder = msg.sender](src/RevvFiLiquidator.sol#L241)
	[RevvFiLiquidator.auctions](src/RevvFiLiquidator.sol#L48) can be used in cross function reentrancies:
	- [RevvFiLiquidator.auctions](src/RevvFiLiquidator.sol#L48)
	- [RevvFiLiquidator.cancelAuction(uint256)](src/RevvFiLiquidator.sol#L321-L333)
	- [RevvFiLiquidator.createAuction(address,address,address,address,uint256,uint256)](src/RevvFiLiquidator.sol#L126-L168)
	- [RevvFiLiquidator.getAuction(uint256)](src/RevvFiLiquidator.sol#L344-L346)
	- [RevvFiLiquidator.getCurrentPrice(uint256)](src/RevvFiLiquidator.sol#L177-L191)
	- [RevvFiLiquidator.getWinningBid(uint256)](src/RevvFiLiquidator.sol#L355-L362)
	- [RevvFiLiquidator.receiveCollateral(uint256)](src/RevvFiLiquidator.sol#L199-L203)
	- [auction.endTime = block.timestamp + auctionExtensionWindow](src/RevvFiLiquidator.sol#L245)
	[RevvFiLiquidator.auctions](src/RevvFiLiquidator.sol#L48) can be used in cross function reentrancies:
	- [RevvFiLiquidator.auctions](src/RevvFiLiquidator.sol#L48)
	- [RevvFiLiquidator.cancelAuction(uint256)](src/RevvFiLiquidator.sol#L321-L333)
	- [RevvFiLiquidator.createAuction(address,address,address,address,uint256,uint256)](src/RevvFiLiquidator.sol#L126-L168)
	- [RevvFiLiquidator.getAuction(uint256)](src/RevvFiLiquidator.sol#L344-L346)
	- [RevvFiLiquidator.getCurrentPrice(uint256)](src/RevvFiLiquidator.sol#L177-L191)
	- [RevvFiLiquidator.getWinningBid(uint256)](src/RevvFiLiquidator.sol#L355-L362)
	- [RevvFiLiquidator.receiveCollateral(uint256)](src/RevvFiLiquidator.sol#L199-L203)

src/RevvFiLiquidator.sol#L216-L249


 - [ ] ID-50
Reentrancy in [RevvFiOfferBook.modifyOffer(uint256,uint256,uint256,uint256)](src/RevvFiOfferBook.sol#L307-L348):
	External calls:
	- [token.safeTransferFrom(msg.sender,address(this),delta)](src/RevvFiOfferBook.sol#L330)
	- [token.safeTransfer(msg.sender,delta_scope_0)](src/RevvFiOfferBook.sol#L334)
	State variables written after the call(s):
	- [_addToBucket(newApr,offerId)](src/RevvFiOfferBook.sol#L345)
		- [oldBucket.offerIds[i] = oldBucket.offerIds[oldBucket.offerIds.length - 1]](src/RevvFiOfferBook.sol#L159)
		- [oldBucket.offerIds.pop()](src/RevvFiOfferBook.sol#L160)
		- [aprBuckets[bucketId].apr = apr](src/RevvFiOfferBook.sol#L168)
		- [aprBuckets[bucketId].offerIds.push(offerId)](src/RevvFiOfferBook.sol#L174)
		- [aprBuckets[bucketId].totalLiquidity += offers[offerId].remainingAmount](src/RevvFiOfferBook.sol#L175)
	[RevvFiOfferBook.aprBuckets](src/RevvFiOfferBook.sol#L82) can be used in cross function reentrancies:
	- [RevvFiOfferBook.aprBuckets](src/RevvFiOfferBook.sol#L82)
	- [RevvFiOfferBook.getBestOffers(uint256,bool)](src/RevvFiOfferBook.sol#L389-L467)
	- [offer.amount = newAmount](src/RevvFiOfferBook.sol#L339)
	[RevvFiOfferBook.offers](src/RevvFiOfferBook.sol#L68) can be used in cross function reentrancies:
	- [RevvFiOfferBook.getBestOffers(uint256,bool)](src/RevvFiOfferBook.sol#L389-L467)
	- [RevvFiOfferBook.getLenderOffers(address)](src/RevvFiOfferBook.sol#L537-L556)
	- [RevvFiOfferBook.getOffer(uint256)](src/RevvFiOfferBook.sol#L528-L530)
	- [RevvFiOfferBook.offers](src/RevvFiOfferBook.sol#L68)
	- [offer.remainingAmount = newRemaining](src/RevvFiOfferBook.sol#L340)
	[RevvFiOfferBook.offers](src/RevvFiOfferBook.sol#L68) can be used in cross function reentrancies:
	- [RevvFiOfferBook.getBestOffers(uint256,bool)](src/RevvFiOfferBook.sol#L389-L467)
	- [RevvFiOfferBook.getLenderOffers(address)](src/RevvFiOfferBook.sol#L537-L556)
	- [RevvFiOfferBook.getOffer(uint256)](src/RevvFiOfferBook.sol#L528-L530)
	- [RevvFiOfferBook.offers](src/RevvFiOfferBook.sol#L68)
	- [offer.apr = newApr](src/RevvFiOfferBook.sol#L341)
	[RevvFiOfferBook.offers](src/RevvFiOfferBook.sol#L68) can be used in cross function reentrancies:
	- [RevvFiOfferBook.getBestOffers(uint256,bool)](src/RevvFiOfferBook.sol#L389-L467)
	- [RevvFiOfferBook.getLenderOffers(address)](src/RevvFiOfferBook.sol#L537-L556)
	- [RevvFiOfferBook.getOffer(uint256)](src/RevvFiOfferBook.sol#L528-L530)
	- [RevvFiOfferBook.offers](src/RevvFiOfferBook.sol#L68)
	- [offer.expiry = block.timestamp + newDuration](src/RevvFiOfferBook.sol#L342)
	[RevvFiOfferBook.offers](src/RevvFiOfferBook.sol#L68) can be used in cross function reentrancies:
	- [RevvFiOfferBook.getBestOffers(uint256,bool)](src/RevvFiOfferBook.sol#L389-L467)
	- [RevvFiOfferBook.getLenderOffers(address)](src/RevvFiOfferBook.sol#L537-L556)
	- [RevvFiOfferBook.getOffer(uint256)](src/RevvFiOfferBook.sol#L528-L530)
	- [RevvFiOfferBook.offers](src/RevvFiOfferBook.sol#L68)

src/RevvFiOfferBook.sol#L307-L348


 - [ ] ID-51
Reentrancy in [RevvFiOfferBook.cancelOffer(uint256)](src/RevvFiOfferBook.sol#L283-L298):
	External calls:
	- [IERC20(borrowAsset).safeTransfer(msg.sender,offer.remainingAmount)](src/RevvFiOfferBook.sol#L293)
	State variables written after the call(s):
	- [offer.remainingAmount = 0](src/RevvFiOfferBook.sol#L294)
	[RevvFiOfferBook.offers](src/RevvFiOfferBook.sol#L68) can be used in cross function reentrancies:
	- [RevvFiOfferBook.getBestOffers(uint256,bool)](src/RevvFiOfferBook.sol#L389-L467)
	- [RevvFiOfferBook.getLenderOffers(address)](src/RevvFiOfferBook.sol#L537-L556)
	- [RevvFiOfferBook.getOffer(uint256)](src/RevvFiOfferBook.sol#L528-L530)
	- [RevvFiOfferBook.offers](src/RevvFiOfferBook.sol#L68)

src/RevvFiOfferBook.sol#L283-L298


 - [ ] ID-52
Reentrancy in [RevvFiMarket.startLiquidation()](src/RevvFiMarket.sol#L715-L736):
	External calls:
	- [collateralEscrow.startLiquidation()](src/RevvFiMarket.sol#L722)
	State variables written after the call(s):
	- [isLiquidating = true](src/RevvFiMarket.sol#L723)
	[RevvFiMarket.isLiquidating](src/RevvFiMarket.sol#L79) can be used in cross function reentrancies:
	- [RevvFiMarket.isLiquidating](src/RevvFiMarket.sol#L79)
	- [RevvFiMarket.liquidate()](src/RevvFiMarket.sol#L790-L794)
	- [RevvFiMarket.settleLiquidation(uint256,uint256)](src/RevvFiMarket.sol#L756-L785)
	- [RevvFiMarket.startLiquidation()](src/RevvFiMarket.sol#L715-L736)

src/RevvFiMarket.sol#L715-L736


 - [ ] ID-53
Reentrancy in [RevvFiOfferBook.submitOffer(uint256,uint256,uint8,uint256)](src/RevvFiOfferBook.sol#L252-L277):
	External calls:
	- [IERC20(borrowAsset).safeTransferFrom(msg.sender,address(this),amount)](src/RevvFiOfferBook.sol#L265)
	State variables written after the call(s):
	- [_addActive(offerId)](src/RevvFiOfferBook.sol#L272)
		- [activeOfferCount ++](src/RevvFiOfferBook.sol#L215)
	[RevvFiOfferBook.activeOfferCount](src/RevvFiOfferBook.sol#L75) can be used in cross function reentrancies:
	- [RevvFiOfferBook.activeOfferCount](src/RevvFiOfferBook.sol#L75)
	- [RevvFiOfferBook.getActiveOfferCount()](src/RevvFiOfferBook.sol#L570-L572)
	- [lenderOfferIds[msg.sender].push(offerId)](src/RevvFiOfferBook.sol#L271)
	[RevvFiOfferBook.lenderOfferIds](src/RevvFiOfferBook.sol#L69) can be used in cross function reentrancies:
	- [RevvFiOfferBook.getLenderOffers(address)](src/RevvFiOfferBook.sol#L537-L556)
	- [RevvFiOfferBook.lenderOfferIds](src/RevvFiOfferBook.sol#L69)

src/RevvFiOfferBook.sol#L252-L277


## unused-return
Impact: Medium
Confidence: Medium
 - [ ] ID-54
[RevvFiMarket.startLiquidation()](src/RevvFiMarket.sol#L715-L736) ignores return value by [collateralEscrow.liquidate(borrower,collateral,debt,address(liquidator))](src/RevvFiMarket.sol#L728)

src/RevvFiMarket.sol#L715-L736


 - [ ] ID-55
[RevvFiMarket.submitOffer(uint256,uint256,uint8,uint256)](src/RevvFiMarket.sol#L693-L702) ignores return value by [offerBook.submitOffer(amount,apr,seniority,duration)](src/RevvFiMarket.sol#L701)

src/RevvFiMarket.sol#L693-L702


 - [ ] ID-56
[RevvFiCollateralEscrow._getLatestPrice()](src/RevvFiCollateralEscrow.sol#L247-L256) ignores return value by [(roundId,price,None,updatedAt,answeredInRound) = IAggregatorV3Interface(collateralOracle).latestRoundData()](src/RevvFiCollateralEscrow.sol#L248-L249)

src/RevvFiCollateralEscrow.sol#L247-L256


## shadowing-local
Impact: Low
Confidence: High
 - [ ] ID-57
[RevvFiCollateralEscrow.getCollateralValue(address).borrower](src/RevvFiCollateralEscrow.sol#L328) shadows:
	- [RevvFiCollateralEscrow.borrower](src/RevvFiCollateralEscrow.sol#L47) (state variable)

src/RevvFiCollateralEscrow.sol#L328


 - [ ] ID-58
[RevvFiPositionNFT.getPositionMetadata(uint256).name](src/RevvFiPositionNFT.sol#L295) shadows:
	- [ERC721.name()](lib/openzeppelin-contracts/contracts/token/ERC721/ERC721.sol#L74-L76) (function)
	- [IERC721Metadata.name()](lib/openzeppelin-contracts/contracts/token/ERC721/extensions/IERC721Metadata.sol#L16) (function)

src/RevvFiPositionNFT.sol#L295


 - [ ] ID-59
[RevvFiMarket.getMaxBorrowable().totalDebt](src/RevvFiMarket.sol#L963) shadows:
	- [RevvFiMarket.totalDebt()](src/RevvFiMarket.sol#L1015-L1017) (function)

src/RevvFiMarket.sol#L963


 - [ ] ID-60
[RevvFiMarket.repayFull().totalDebt](src/RevvFiMarket.sol#L604) shadows:
	- [RevvFiMarket.totalDebt()](src/RevvFiMarket.sol#L1015-L1017) (function)

src/RevvFiMarket.sol#L604


 - [ ] ID-61
[RevvFiMarket.repay(uint256).totalDebt](src/RevvFiMarket.sol#L524) shadows:
	- [RevvFiMarket.totalDebt()](src/RevvFiMarket.sol#L1015-L1017) (function)

src/RevvFiMarket.sol#L524


## events-maths
Impact: Low
Confidence: Medium
 - [ ] ID-62
[RevvFiLiquidator.setMinBidIncrementBps(uint256)](src/RevvFiLiquidator.sol#L380-L382) should emit an event for: 
	- [minBidIncrementBps = newIncrementBps](src/RevvFiLiquidator.sol#L381) 

src/RevvFiLiquidator.sol#L380-L382


 - [ ] ID-63
[RevvFiLiquidator.setAuctionExtensionWindow(uint256)](src/RevvFiLiquidator.sol#L388-L390) should emit an event for: 
	- [auctionExtensionWindow = newWindow](src/RevvFiLiquidator.sol#L389) 

src/RevvFiLiquidator.sol#L388-L390


 - [ ] ID-64
[RevvFiLiquidator.setDutchAuctionParams(uint256,uint256)](src/RevvFiLiquidator.sol#L397-L400) should emit an event for: 
	- [dutchAuctionStepDuration = stepDuration](src/RevvFiLiquidator.sol#L398) 
	- [dutchAuctionPriceDecrementBps = decrementBps](src/RevvFiLiquidator.sol#L399) 

src/RevvFiLiquidator.sol#L397-L400


## calls-loop
Impact: Low
Confidence: Medium
 - [ ] ID-65
[RevvFiMarket._settlePosition(uint256)](src/RevvFiMarket.sol#L674-L684) has external calls inside a loop: [settledPositionOwner[positionId] = positionNFT.ownerOf(positionId)](src/RevvFiMarket.sol#L679)
	Calls stack containing the loop:
		RevvFiMarket.repay(uint256)
		RevvFiMarket._distributeRepayment(uint256)

src/RevvFiMarket.sol#L674-L684


 - [ ] ID-66
[RevvFiMarket.borrow(uint256,bool,uint256)](src/RevvFiMarket.sol#L449-L515) has external calls inside a loop: [tokenId = positionNFT.mintPosition(filledOffers[i].lender,address(this),filledOffers[i].remainingAmount,filledOffers[i].apr,filledOffers[i].seniority)](src/RevvFiMarket.sol#L482-L488)

src/RevvFiMarket.sol#L449-L515


 - [ ] ID-67
[RevvFiMarket._settlePosition(uint256)](src/RevvFiMarket.sol#L674-L684) has external calls inside a loop: [positionNFT.redeemPosition(positionId)](src/RevvFiMarket.sol#L683)
	Calls stack containing the loop:
		RevvFiMarket.repayFull()

src/RevvFiMarket.sol#L674-L684


 - [ ] ID-68
[RevvFiMarket._settlePosition(uint256)](src/RevvFiMarket.sol#L674-L684) has external calls inside a loop: [positionNFT.redeemPosition(positionId)](src/RevvFiMarket.sol#L683)
	Calls stack containing the loop:
		RevvFiMarket.settleLiquidation(uint256,uint256)
		RevvFiMarket._distributeLoss(uint256)

src/RevvFiMarket.sol#L674-L684


 - [ ] ID-69
[RevvFiMarket._settlePosition(uint256)](src/RevvFiMarket.sol#L674-L684) has external calls inside a loop: [positionNFT.redeemPosition(positionId)](src/RevvFiMarket.sol#L683)
	Calls stack containing the loop:
		RevvFiMarket.forceCloseMarket()

src/RevvFiMarket.sol#L674-L684


 - [ ] ID-70
[RevvFiMarket._distributeRepayment(uint256)](src/RevvFiMarket.sol#L548-L598) has external calls inside a loop: [settledPositionOwner[posId_scope_1] = positionNFT.ownerOf(posId_scope_1)](src/RevvFiMarket.sol#L588)
	Calls stack containing the loop:
		RevvFiMarket.repay(uint256)

src/RevvFiMarket.sol#L548-L598


 - [ ] ID-71
[RevvFiMarket._settlePosition(uint256)](src/RevvFiMarket.sol#L674-L684) has external calls inside a loop: [positionNFT.redeemPosition(positionId)](src/RevvFiMarket.sol#L683)
	Calls stack containing the loop:
		RevvFiMarket.repay(uint256)
		RevvFiMarket._distributeRepayment(uint256)

src/RevvFiMarket.sol#L674-L684


 - [ ] ID-72
[RevvFiMarket._settlePosition(uint256)](src/RevvFiMarket.sol#L674-L684) has external calls inside a loop: [settledPositionOwner[positionId] = positionNFT.ownerOf(positionId)](src/RevvFiMarket.sol#L679)
	Calls stack containing the loop:
		RevvFiMarket.repayFull()

src/RevvFiMarket.sol#L674-L684


 - [ ] ID-73
[RevvFiMarket._settlePosition(uint256)](src/RevvFiMarket.sol#L674-L684) has external calls inside a loop: [settledPositionOwner[positionId] = positionNFT.ownerOf(positionId)](src/RevvFiMarket.sol#L679)
	Calls stack containing the loop:
		RevvFiMarket.forceCloseMarket()

src/RevvFiMarket.sol#L674-L684


 - [ ] ID-74
[RevvFiMarket._settlePosition(uint256)](src/RevvFiMarket.sol#L674-L684) has external calls inside a loop: [settledPositionOwner[positionId] = positionNFT.ownerOf(positionId)](src/RevvFiMarket.sol#L679)
	Calls stack containing the loop:
		RevvFiMarket.settleLiquidation(uint256,uint256)
		RevvFiMarket._distributeLoss(uint256)

src/RevvFiMarket.sol#L674-L684


 - [ ] ID-75
[RevvFiMarket._distributeRepayment(uint256)](src/RevvFiMarket.sol#L548-L598) has external calls inside a loop: [settledPositionOwner[posId_scope_1] = positionNFT.ownerOf(posId_scope_1)](src/RevvFiMarket.sol#L588)
	Calls stack containing the loop:
		RevvFiMarket.settleLiquidation(uint256,uint256)

src/RevvFiMarket.sol#L548-L598


## reentrancy-benign
Impact: Low
Confidence: Medium
 - [ ] ID-76
Reentrancy in [RevvFiOfferBook.modifyOffer(uint256,uint256,uint256,uint256)](src/RevvFiOfferBook.sol#L307-L348):
	External calls:
	- [token.safeTransfer(msg.sender,delta_scope_0)](src/RevvFiOfferBook.sol#L334)
	State variables written after the call(s):
	- [totalLiquidity -= delta_scope_0](src/RevvFiOfferBook.sol#L335)

src/RevvFiOfferBook.sol#L307-L348


 - [ ] ID-77
Reentrancy in [RevvFiMarket.startLiquidation()](src/RevvFiMarket.sol#L715-L736):
	External calls:
	- [collateralEscrow.startLiquidation()](src/RevvFiMarket.sol#L722)
	- [collateralToken.forceApprove(address(liquidator),collateral)](src/RevvFiMarket.sol#L727)
	- [collateralEscrow.liquidate(borrower,collateral,debt,address(liquidator))](src/RevvFiMarket.sol#L728)
	- [liquidationAuctionId = liquidator.createAuction(address(this),borrower,borrowAsset,collateralAsset,collateral,debt)](src/RevvFiMarket.sol#L731-L732)
	State variables written after the call(s):
	- [liquidationAuctionId = liquidator.createAuction(address(this),borrower,borrowAsset,collateralAsset,collateral,debt)](src/RevvFiMarket.sol#L731-L732)

src/RevvFiMarket.sol#L715-L736


 - [ ] ID-78
Reentrancy in [RevvFiOfferBook.cleanupExpiredOffers(uint256)](src/RevvFiOfferBook.sol#L354-L379):
	External calls:
	- [token.safeTransfer(offer.lender,offer.remainingAmount)](src/RevvFiOfferBook.sol#L367)
	State variables written after the call(s):
	- [_removeActive(offerId)](src/RevvFiOfferBook.sol#L373)
		- [offerInBucketId[offerId] = 0](src/RevvFiOfferBook.sol#L194)

src/RevvFiOfferBook.sol#L354-L379


 - [ ] ID-79
Reentrancy in [RevvFiOfferBook.modifyOffer(uint256,uint256,uint256,uint256)](src/RevvFiOfferBook.sol#L307-L348):
	External calls:
	- [token.safeTransferFrom(msg.sender,address(this),delta)](src/RevvFiOfferBook.sol#L330)
	- [token.safeTransfer(msg.sender,delta_scope_0)](src/RevvFiOfferBook.sol#L334)
	State variables written after the call(s):
	- [_addToBucket(newApr,offerId)](src/RevvFiOfferBook.sol#L345)
		- [aprToIndex[bucketId] = aprValues.length](src/RevvFiOfferBook.sol#L169)
	- [_addToBucket(newApr,offerId)](src/RevvFiOfferBook.sol#L345)
		- [aprValues.push(bucketId)](src/RevvFiOfferBook.sol#L170)
	- [_addToBucket(newApr,offerId)](src/RevvFiOfferBook.sol#L345)
		- [offerInBucketId[offerId] = bucketId](src/RevvFiOfferBook.sol#L176)

src/RevvFiOfferBook.sol#L307-L348


 - [ ] ID-80
Reentrancy in [RevvFiOfferBook.modifyOffer(uint256,uint256,uint256,uint256)](src/RevvFiOfferBook.sol#L307-L348):
	External calls:
	- [token.safeTransferFrom(msg.sender,address(this),delta)](src/RevvFiOfferBook.sol#L330)
	State variables written after the call(s):
	- [totalLiquidity += delta](src/RevvFiOfferBook.sol#L331)

src/RevvFiOfferBook.sol#L307-L348


 - [ ] ID-81
Reentrancy in [RevvFiMarket.borrow(uint256,bool,uint256)](src/RevvFiMarket.sol#L449-L515):
	External calls:
	- [(filledOffers,weightedApr) = offerBook.executeDrawdown(amount,useSeniorOnly)](src/RevvFiMarket.sol#L464-L465)
	- [tokenId = positionNFT.mintPosition(filledOffers[i].lender,address(this),filledOffers[i].remainingAmount,filledOffers[i].apr,filledOffers[i].seniority)](src/RevvFiMarket.sol#L482-L488)
	State variables written after the call(s):
	- [_addActivePosition(tokenId)](src/RevvFiMarket.sol#L501)
		- [activePositionIndex[positionId] = activePositionIds.length](src/RevvFiMarket.sol#L363)
	- [_addActivePosition(tokenId)](src/RevvFiMarket.sol#L501)
		- [positionActive[positionId] = true](src/RevvFiMarket.sol#L365)
	- [positionClaimableAmount[tokenId] = 0](src/RevvFiMarket.sol#L498)
	- [positionSeniority[tokenId] = filledOffers[i].seniority](src/RevvFiMarket.sol#L496)
	- [positionSettled[tokenId] = false](src/RevvFiMarket.sol#L497)

src/RevvFiMarket.sol#L449-L515


 - [ ] ID-82
Reentrancy in [RevvFiCollateralEscrow.depositCollateral(address,uint256)](src/RevvFiCollateralEscrow.sol#L169-L178):
	External calls:
	- [IERC20(collateralAsset).safeTransferFrom(msg.sender,address(this),amount)](src/RevvFiCollateralEscrow.sol#L173)
	State variables written after the call(s):
	- [collateralBalance[borrowerAddr] += amount](src/RevvFiCollateralEscrow.sol#L174)
	- [totalCollateral += amount](src/RevvFiCollateralEscrow.sol#L175)

src/RevvFiCollateralEscrow.sol#L169-L178


 - [ ] ID-83
Reentrancy in [RevvFiMarket.forceCloseMarket()](src/RevvFiMarket.sol#L864-L888):
	External calls:
	- [_settlePosition(posId)](src/RevvFiMarket.sol#L879)
		- [positionNFT.redeemPosition(positionId)](src/RevvFiMarket.sol#L683)
	State variables written after the call(s):
	- [isClosed = true](src/RevvFiMarket.sol#L886)

src/RevvFiMarket.sol#L864-L888


 - [ ] ID-84
Reentrancy in [RevvFiMarket.borrow(uint256,bool,uint256)](src/RevvFiMarket.sol#L449-L515):
	External calls:
	- [(filledOffers,weightedApr) = offerBook.executeDrawdown(amount,useSeniorOnly)](src/RevvFiMarket.sol#L464-L465)
	State variables written after the call(s):
	- [currentCycleBorrowedAmount += amount](src/RevvFiMarket.sol#L476)

src/RevvFiMarket.sol#L449-L515


 - [ ] ID-85
Reentrancy in [RevvFiOfferBook.submitOffer(uint256,uint256,uint8,uint256)](src/RevvFiOfferBook.sol#L252-L277):
	External calls:
	- [IERC20(borrowAsset).safeTransferFrom(msg.sender,address(this),amount)](src/RevvFiOfferBook.sol#L265)
	State variables written after the call(s):
	- [_addActive(offerId)](src/RevvFiOfferBook.sol#L272)
		- [_activeIds.push(offerId)](src/RevvFiOfferBook.sol#L214)
	- [_addActive(offerId)](src/RevvFiOfferBook.sol#L272)
		- [_activeIndex[offerId] = _activeIds.length](src/RevvFiOfferBook.sol#L213)
	- [_addActive(offerId)](src/RevvFiOfferBook.sol#L272)
		- [oldBucket.offerIds[i] = oldBucket.offerIds[oldBucket.offerIds.length - 1]](src/RevvFiOfferBook.sol#L159)
		- [oldBucket.offerIds.pop()](src/RevvFiOfferBook.sol#L160)
		- [aprBuckets[bucketId].apr = apr](src/RevvFiOfferBook.sol#L168)
		- [aprBuckets[bucketId].offerIds.push(offerId)](src/RevvFiOfferBook.sol#L174)
		- [aprBuckets[bucketId].totalLiquidity += offers[offerId].remainingAmount](src/RevvFiOfferBook.sol#L175)
	- [_addActive(offerId)](src/RevvFiOfferBook.sol#L272)
		- [aprToIndex[bucketId] = aprValues.length](src/RevvFiOfferBook.sol#L169)
	- [_addActive(offerId)](src/RevvFiOfferBook.sol#L272)
		- [aprValues.push(bucketId)](src/RevvFiOfferBook.sol#L170)
	- [_addActive(offerId)](src/RevvFiOfferBook.sol#L272)
		- [isActiveOffer[offerId] = true](src/RevvFiOfferBook.sol#L212)
	- [offerId = nextOfferId ++](src/RevvFiOfferBook.sol#L268)
	- [_addActive(offerId)](src/RevvFiOfferBook.sol#L272)
		- [offerInBucketId[offerId] = bucketId](src/RevvFiOfferBook.sol#L176)
	- [offers[offerId] = Offer(offerId,msg.sender,amount,amount,apr,seniority,block.timestamp + duration,true)](src/RevvFiOfferBook.sol#L269)
	- [totalLiquidity += amount](src/RevvFiOfferBook.sol#L273)

src/RevvFiOfferBook.sol#L252-L277


 - [ ] ID-86
Reentrancy in [RevvFiOfferBook.executeDrawdown(uint256,bool)](src/RevvFiOfferBook.sol#L476-L521):
	External calls:
	- [IERC20(borrowAsset).safeTransfer(market,take)](src/RevvFiOfferBook.sol#L506)
	State variables written after the call(s):
	- [_addToBucket(offer.apr,offer.id)](src/RevvFiOfferBook.sol#L513)
		- [aprToIndex[bucketId] = aprValues.length](src/RevvFiOfferBook.sol#L169)

src/RevvFiOfferBook.sol#L476-L521


## reentrancy-events
Impact: Low
Confidence: Medium
 - [ ] ID-87
Reentrancy in [RevvFiMarket.startLiquidation()](src/RevvFiMarket.sol#L715-L736):
	External calls:
	- [collateralEscrow.startLiquidation()](src/RevvFiMarket.sol#L722)
	- [collateralToken.forceApprove(address(liquidator),collateral)](src/RevvFiMarket.sol#L727)
	- [collateralEscrow.liquidate(borrower,collateral,debt,address(liquidator))](src/RevvFiMarket.sol#L728)
	- [liquidationAuctionId = liquidator.createAuction(address(this),borrower,borrowAsset,collateralAsset,collateral,debt)](src/RevvFiMarket.sol#L731-L732)
	- [liquidator.receiveCollateral(liquidationAuctionId)](src/RevvFiMarket.sol#L733)
	Event emitted after the call(s):
	- [RevvFiEvents.LiquidationStartedMarket(borrower)](src/RevvFiMarket.sol#L735)

src/RevvFiMarket.sol#L715-L736


 - [ ] ID-88
Reentrancy in [RevvFiPositionNFT.mintPosition(address,address,uint256,uint256,uint8)](src/RevvFiPositionNFT.sol#L113-L142):
	External calls:
	- [_safeMint(lender,tokenId)](src/RevvFiPositionNFT.sol#L138)
		- [retval = IERC721Receiver(to).onERC721Received(_msgSender(),from,tokenId,data)](lib/openzeppelin-contracts/contracts/token/ERC721/ERC721.sol#L467-L480)
	Event emitted after the call(s):
	- [RevvFiEvents.PositionMinted(tokenId,lender,market,principal,apr,seniority)](src/RevvFiPositionNFT.sol#L140)

src/RevvFiPositionNFT.sol#L113-L142


 - [ ] ID-89
Reentrancy in [RevvFiMarket.settleLiquidation(uint256,uint256)](src/RevvFiMarket.sol#L756-L785):
	External calls:
	- [_distributeLoss(loss)](src/RevvFiMarket.sol#L767)
		- [positionNFT.redeemPosition(positionId)](src/RevvFiMarket.sol#L683)
	- [_distributeRepayment(debtRepaid)](src/RevvFiMarket.sol#L772)
		- [positionNFT.redeemPosition(positionId)](src/RevvFiMarket.sol#L683)
	- [reputationRegistry.recordDefault(borrower,currentCycleBorrowedAmount,debtRepaid)](src/RevvFiMarket.sol#L777)
	- [collateralEscrow.endLiquidation()](src/RevvFiMarket.sol#L782)
	Event emitted after the call(s):
	- [RevvFiEvents.LiquidationEndedMarket(borrower)](src/RevvFiMarket.sol#L784)

src/RevvFiMarket.sol#L756-L785


 - [ ] ID-90
Reentrancy in [RevvFiLiquidator.cancelAuction(uint256)](src/RevvFiLiquidator.sol#L321-L333):
	External calls:
	- [token.safeTransfer(auction.highestBidder,auction.highestBid)](src/RevvFiLiquidator.sol#L328)
	Event emitted after the call(s):
	- [RevvFiEvents.AuctionCancelled(auctionId)](src/RevvFiLiquidator.sol#L332)

src/RevvFiLiquidator.sol#L321-L333


## timestamp
Impact: Low
Confidence: Medium
 - [ ] ID-91
[ReputationRegistry.getRiskLabel(address)](src/ReputationRegistry.sol#L202-L212) uses timestamp for comparisons
	Dangerous comparisons:
	- [score >= 900](src/ReputationRegistry.sol#L206)
	- [score >= 800](src/ReputationRegistry.sol#L207)
	- [score >= 700](src/ReputationRegistry.sol#L208)
	- [score >= 500](src/ReputationRegistry.sol#L209)
	- [score >= 300](src/ReputationRegistry.sol#L210)

src/ReputationRegistry.sol#L202-L212


 - [ ] ID-92
[RevvFiLiquidator.placeBid(uint256,uint256)](src/RevvFiLiquidator.sol#L216-L249) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp > auction.endTime](src/RevvFiLiquidator.sol#L219)
	- [bidAmount < minBid](src/RevvFiLiquidator.sol#L227)
	- [auction.endTime - block.timestamp < auctionExtensionWindow](src/RevvFiLiquidator.sol#L244)

src/RevvFiLiquidator.sol#L216-L249


 - [ ] ID-93
[RevvFiFactory.executeArchControllerUpdate()](src/RevvFiFactory.sol#L341-L351) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp < archControllerUpdateTimelock](src/RevvFiFactory.sol#L343)

src/RevvFiFactory.sol#L341-L351


 - [ ] ID-94
[RevvFiMarket.repay(uint256)](src/RevvFiMarket.sol#L521-L542) uses timestamp for comparisons
	Dangerous comparisons:
	- [amount == 0](src/RevvFiMarket.sol#L522)
	- [totalDebt == 0](src/RevvFiMarket.sol#L525)
	- [amount > totalDebt](src/RevvFiMarket.sol#L526)
	- [totalScaledPrincipal == 0](src/RevvFiMarket.sol#L534)

src/RevvFiMarket.sol#L521-L542


 - [ ] ID-95
[RevvFiMarket._distributeRepayment(uint256)](src/RevvFiMarket.sol#L548-L598) uses timestamp for comparisons
	Dangerous comparisons:
	- [totalScaledPrincipal == 0](src/RevvFiMarket.sol#L549)
	- [i < positions.length && remainingRepayment > 0](src/RevvFiMarket.sol#L557)
	- [positionDebt == 0](src/RevvFiMarket.sol#L562)
	- [share > remainingRepayment](src/RevvFiMarket.sol#L566)
	- [share == 0](src/RevvFiMarket.sol#L567)
	- [positionScaledPrincipal[posId_scope_1] > 0 && positionDebt_scope_2 < DUST_THRESHOLD](src/RevvFiMarket.sol#L586)

src/RevvFiMarket.sol#L548-L598


 - [ ] ID-96
[RevvFiMarket.repayFull()](src/RevvFiMarket.sol#L603-L636) uses timestamp for comparisons
	Dangerous comparisons:
	- [totalDebt == 0](src/RevvFiMarket.sol#L605)

src/RevvFiMarket.sol#L603-L636


 - [ ] ID-97
[RevvFiOfferBook.cleanupExpiredOffers(uint256)](src/RevvFiOfferBook.sol#L354-L379) uses timestamp for comparisons
	Dangerous comparisons:
	- [offer.expiry <= block.timestamp](src/RevvFiOfferBook.sol#L363)

src/RevvFiOfferBook.sol#L354-L379


 - [ ] ID-98
[RevvFiMarket._distributeLoss(uint256)](src/RevvFiMarket.sol#L800-L858) uses timestamp for comparisons
	Dangerous comparisons:
	- [i < positions.length && remainingLoss > 0](src/RevvFiMarket.sol#L806)
	- [positionDebt == 0](src/RevvFiMarket.sol#L812)
	- [positionDebt >= remainingLoss](src/RevvFiMarket.sol#L814)
	- [i_scope_0 < positions.length && remainingLoss > 0](src/RevvFiMarket.sol#L833)
	- [positionDebt_scope_2 == 0](src/RevvFiMarket.sol#L839)
	- [positionDebt_scope_2 >= remainingLoss](src/RevvFiMarket.sol#L841)

src/RevvFiMarket.sol#L800-L858


 - [ ] ID-99
[RevvFiMarket.settleLiquidation(uint256,uint256)](src/RevvFiMarket.sol#L756-L785) uses timestamp for comparisons
	Dangerous comparisons:
	- [debtRepaid < originalDebt](src/RevvFiMarket.sol#L763)

src/RevvFiMarket.sol#L756-L785


 - [ ] ID-100
[RevvFiLiquidityQueue.processEpoch(uint256,uint256)](src/RevvFiLiquidityQueue.sol#L192-L224) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp < epoch.endTime](src/RevvFiLiquidityQueue.sol#L195)

src/RevvFiLiquidityQueue.sol#L192-L224


 - [ ] ID-101
[RevvFiMarket._updateAPROnPrincipalChange(uint256,uint256,uint256)](src/RevvFiMarket.sol#L324-L341) uses timestamp for comparisons
	Dangerous comparisons:
	- [oldScaledPrincipal == newScaledPrincipal](src/RevvFiMarket.sol#L325)
	- [newContribution >= oldContribution](src/RevvFiMarket.sol#L330)
	- [reduction <= weightedAprNumeratorScaled](src/RevvFiMarket.sol#L334)

src/RevvFiMarket.sol#L324-L341


 - [ ] ID-102
[RevvFiLiquidityQueue._advanceEpochIfNeeded()](src/RevvFiLiquidityQueue.sol#L281-L302) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp >= currentEpochData.endTime](src/RevvFiLiquidityQueue.sol#L285)

src/RevvFiLiquidityQueue.sol#L281-L302


 - [ ] ID-103
[RevvFiMarket.borrow(uint256,bool,uint256)](src/RevvFiMarket.sol#L449-L515) uses timestamp for comparisons
	Dangerous comparisons:
	- [amount > maxBorrowable](src/RevvFiMarket.sol#L461)

src/RevvFiMarket.sol#L449-L515


 - [ ] ID-104
[RevvFiLiquidityQueue.timeUntilEpochEnd()](src/RevvFiLiquidityQueue.sol#L367-L371) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp >= epochData.endTime](src/RevvFiLiquidityQueue.sol#L369)

src/RevvFiLiquidityQueue.sol#L367-L371


 - [ ] ID-105
[RevvFiMarket._accrueInterest()](src/RevvFiMarket.sol#L217-L241) uses timestamp for comparisons
	Dangerous comparisons:
	- [totalScaledPrincipal == 0](src/RevvFiMarket.sol#L218)
	- [elapsed == 0](src/RevvFiMarket.sol#L224)
	- [totalInterestAccrued > 0](src/RevvFiMarket.sol#L233)

src/RevvFiMarket.sol#L217-L241


 - [ ] ID-106
[RevvFiMarket.getMaxBorrowable()](src/RevvFiMarket.sol#L961-L966) uses timestamp for comparisons
	Dangerous comparisons:
	- [maxFromCollateral <= totalDebt](src/RevvFiMarket.sol#L964)

src/RevvFiMarket.sol#L961-L966


 - [ ] ID-107
[RevvFiMarket._updateWeightedAverageAPR()](src/RevvFiMarket.sol#L346-L352) uses timestamp for comparisons
	Dangerous comparisons:
	- [totalScaledPrincipal == 0](src/RevvFiMarket.sol#L347)

src/RevvFiMarket.sol#L346-L352


 - [ ] ID-108
[RevvFiCollateralEscrow._getLatestPrice()](src/RevvFiCollateralEscrow.sol#L247-L256) uses timestamp for comparisons
	Dangerous comparisons:
	- [price <= 0 || updatedAt == 0 || block.timestamp > updatedAt + STALE_PRICE || answeredInRound < roundId](src/RevvFiCollateralEscrow.sol#L251)

src/RevvFiCollateralEscrow.sol#L247-L256


 - [ ] ID-109
[RevvFiMarket.forceCloseMarket()](src/RevvFiMarket.sol#L864-L888) uses timestamp for comparisons
	Dangerous comparisons:
	- [require(bool,string)(totalScaledPrincipal == 0 || (totalScaledPrincipal * borrowIndex) / SCALE < FORCED_CLEANUP_THRESHOLD,Debt too high to force close)](src/RevvFiMarket.sol#L865-L868)
	- [totalScaledPrincipal > 0](src/RevvFiMarket.sol#L884)

src/RevvFiMarket.sol#L864-L888


 - [ ] ID-110
[RevvFiOfferBook.getBestOffers(uint256,bool)](src/RevvFiOfferBook.sol#L389-L467) uses timestamp for comparisons
	Dangerous comparisons:
	- [! offer.active || offer.remainingAmount == 0 || offer.expiry <= block.timestamp](src/RevvFiOfferBook.sol#L430)

src/RevvFiOfferBook.sol#L389-L467


 - [ ] ID-111
[RevvFiMarket._getUpdatedBorrowIndex()](src/RevvFiMarket.sol#L247-L259) uses timestamp for comparisons
	Dangerous comparisons:
	- [totalScaledPrincipal == 0](src/RevvFiMarket.sol#L248)
	- [elapsed == 0](src/RevvFiMarket.sol#L251)

src/RevvFiMarket.sol#L247-L259


 - [ ] ID-112
[RevvFiMarket._updateAPROnRemove(uint256,uint256)](src/RevvFiMarket.sol#L308-L316) uses timestamp for comparisons
	Dangerous comparisons:
	- [reduction <= weightedAprNumeratorScaled](src/RevvFiMarket.sol#L310)

src/RevvFiMarket.sol#L308-L316


 - [ ] ID-113
[RevvFiLiquidityQueue.getCurrentEpoch()](src/RevvFiLiquidityQueue.sol#L308-L314) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp >= epochData.endTime](src/RevvFiLiquidityQueue.sol#L310)

src/RevvFiLiquidityQueue.sol#L308-L314


 - [ ] ID-114
[RevvFiMarket._getPositionDebt(uint256)](src/RevvFiMarket.sol#L266-L270) uses timestamp for comparisons
	Dangerous comparisons:
	- [! positionActive[positionId] || positionScaledPrincipal[positionId] == 0](src/RevvFiMarket.sol#L267)

src/RevvFiMarket.sol#L266-L270


 - [ ] ID-115
[RevvFiLiquidator.getCurrentPrice(uint256)](src/RevvFiLiquidator.sol#L177-L191) uses timestamp for comparisons
	Dangerous comparisons:
	- [priceDecrement >= auction.debtAmount - auction.reservePrice](src/RevvFiLiquidator.sol#L186)

src/RevvFiLiquidator.sol#L177-L191


 - [ ] ID-116
[RevvFiMarket._removePositionWithAPR(uint256)](src/RevvFiMarket.sol#L392-L404) uses timestamp for comparisons
	Dangerous comparisons:
	- [remainingScaled > 0](src/RevvFiMarket.sol#L398)

src/RevvFiMarket.sol#L392-L404


 - [ ] ID-117
[RevvFiMarket.closeMarket()](src/RevvFiMarket.sol#L918-L923) uses timestamp for comparisons
	Dangerous comparisons:
	- [totalScaledPrincipal > 0](src/RevvFiMarket.sol#L919)

src/RevvFiMarket.sol#L918-L923


 - [ ] ID-118
[RevvFiLiquidator.settleAuction(uint256)](src/RevvFiLiquidator.sol#L258-L289) uses timestamp for comparisons
	Dangerous comparisons:
	- [block.timestamp <= auction.endTime](src/RevvFiLiquidator.sol#L261)

src/RevvFiLiquidator.sol#L258-L289


## assembly
Impact: Informational
Confidence: High
 - [ ] ID-119
[Strings.toString(uint256)](lib/openzeppelin-contracts/contracts/utils/Strings.sol#L24-L44) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/Strings.sol#L30-L32)
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/Strings.sol#L36-L38)

lib/openzeppelin-contracts/contracts/utils/Strings.sol#L24-L44


 - [ ] ID-120
[Clones.cloneDeterministic(address,bytes32)](lib/openzeppelin-contracts/contracts/proxy/Clones.sol#L50-L63) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/proxy/Clones.sol#L52-L59)

lib/openzeppelin-contracts/contracts/proxy/Clones.sol#L50-L63


 - [ ] ID-121
[Math.mulDiv(uint256,uint256,uint256)](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L123-L202) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L130-L133)
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L154-L161)
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L167-L176)

lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L123-L202


 - [ ] ID-122
[EnumerableSet.values(EnumerableSet.Bytes32Set)](lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol#L219-L229) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol#L224-L226)

lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol#L219-L229


 - [ ] ID-123
[AddressUpgradeable._revert(bytes,string)](lib/openzeppelin-contracts-upgradeable/contracts/utils/AddressUpgradeable.sol#L231-L243) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts-upgradeable/contracts/utils/AddressUpgradeable.sol#L236-L239)

lib/openzeppelin-contracts-upgradeable/contracts/utils/AddressUpgradeable.sol#L231-L243


 - [ ] ID-124
[Address._revert(bytes)](lib/openzeppelin-contracts/contracts/utils/Address.sol#L146-L158) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/Address.sol#L151-L154)

lib/openzeppelin-contracts/contracts/utils/Address.sol#L146-L158


 - [ ] ID-125
[EnumerableSet.values(EnumerableSet.AddressSet)](lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol#L293-L303) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol#L298-L300)

lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol#L293-L303


 - [ ] ID-126
[Clones.predictDeterministicAddress(address,bytes32,address)](lib/openzeppelin-contracts/contracts/proxy/Clones.sol#L68-L84) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/proxy/Clones.sol#L74-L83)

lib/openzeppelin-contracts/contracts/proxy/Clones.sol#L68-L84


 - [ ] ID-127
[Clones.clone(address)](lib/openzeppelin-contracts/contracts/proxy/Clones.sol#L28-L41) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/proxy/Clones.sol#L30-L37)

lib/openzeppelin-contracts/contracts/proxy/Clones.sol#L28-L41


 - [ ] ID-128
[EnumerableSet.values(EnumerableSet.UintSet)](lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol#L367-L377) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol#L372-L374)

lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol#L367-L377


 - [ ] ID-129
[ERC721._checkOnERC721Received(address,address,uint256,bytes)](lib/openzeppelin-contracts/contracts/token/ERC721/ERC721.sol#L465-L482) uses assembly
	- [INLINE ASM](lib/openzeppelin-contracts/contracts/token/ERC721/ERC721.sol#L476-L478)

lib/openzeppelin-contracts/contracts/token/ERC721/ERC721.sol#L465-L482


## pragma
Impact: Informational
Confidence: High
 - [ ] ID-130
4 different versions of Solidity are used:
	- Version constraint ^0.8.20 is used by:
		-[^0.8.20](lib/openzeppelin-contracts/contracts/access/Ownable.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/interfaces/draft-IERC6093.sol#L3)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/proxy/Clones.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Permit.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/token/ERC721/ERC721.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/token/ERC721/IERC721.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/token/ERC721/IERC721Receiver.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/token/ERC721/extensions/ERC721Enumerable.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/token/ERC721/extensions/IERC721Enumerable.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/token/ERC721/extensions/IERC721Metadata.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/utils/Address.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/utils/Context.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/utils/Strings.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/utils/introspection/ERC165.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/utils/introspection/IERC165.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/utils/math/SignedMath.sol#L4)
		-[^0.8.20](lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol#L5)
	- Version constraint ^0.8.2 is used by:
		-[^0.8.2](lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol#L4)
	- Version constraint ^0.8.1 is used by:
		-[^0.8.1](lib/openzeppelin-contracts-upgradeable/contracts/utils/AddressUpgradeable.sol#L4)
	- Version constraint 0.8.33 is used by:
		-[0.8.33](src/ReputationRegistry.sol#L2)
		-[0.8.33](src/RevvFiArchController.sol#L2)
		-[0.8.33](src/RevvFiCollateralEscrow.sol#L2)
		-[0.8.33](src/RevvFiFactory.sol#L2)
		-[0.8.33](src/RevvFiLiquidator.sol#L2)
		-[0.8.33](src/RevvFiLiquidityQueue.sol#L2)
		-[0.8.33](src/RevvFiMarket.sol#L2)
		-[0.8.33](src/RevvFiOfferBook.sol#L2)
		-[0.8.33](src/RevvFiPositionNFT.sol#L2)
		-[0.8.33](src/interfaces/IAggregatorV3Interface.sol#L2)
		-[0.8.33](src/interfaces/IReputationRegistry.sol#L2)
		-[0.8.33](src/interfaces/IRevvFiArchController.sol#L2)
		-[0.8.33](src/interfaces/IRevvFiCollateralEscrow.sol#L2)
		-[0.8.33](src/interfaces/IRevvFiLiquidator.sol#L2)
		-[0.8.33](src/interfaces/IRevvFiLiquidityQueue.sol#L2)
		-[0.8.33](src/interfaces/IRevvFiMarket.sol#L2)
		-[0.8.33](src/interfaces/IRevvFiOfferBook.sol#L2)
		-[0.8.33](src/interfaces/IRevvFiPositionNFT.sol#L2)
		-[0.8.33](src/libraries/RevvFiDebtAccounting.sol#L2)
		-[0.8.33](src/libraries/RevvFiErrors.sol#L2)
		-[0.8.33](src/libraries/RevvFiEvents.sol#L2)

lib/openzeppelin-contracts/contracts/access/Ownable.sol#L4


## costly-loop
Impact: Informational
Confidence: Medium
 - [ ] ID-131
[RevvFiMarket._updateAPROnRemove(uint256,uint256)](src/RevvFiMarket.sol#L308-L316) has costly operations inside a loop:
	- [weightedAprNumeratorScaled -= reduction](src/RevvFiMarket.sol#L311)
	Calls stack containing the loop:
		RevvFiMarket.forceCloseMarket()
		RevvFiMarket._removePositionWithAPR(uint256)

src/RevvFiMarket.sol#L308-L316


 - [ ] ID-132
[RevvFiMarket._updateAPROnRemove(uint256,uint256)](src/RevvFiMarket.sol#L308-L316) has costly operations inside a loop:
	- [weightedAprNumeratorScaled -= reduction](src/RevvFiMarket.sol#L311)
	Calls stack containing the loop:
		RevvFiMarket.repayFull()
		RevvFiMarket._removePositionWithAPR(uint256)

src/RevvFiMarket.sol#L308-L316


 - [ ] ID-133
[RevvFiMarket._updateWeightedAverageAPR()](src/RevvFiMarket.sol#L346-L352) has costly operations inside a loop:
	- [weightedAverageAPR = weightedAprNumeratorScaled / totalScaledPrincipal](src/RevvFiMarket.sol#L351)
	Calls stack containing the loop:
		RevvFiMarket.repayFull()
		RevvFiMarket._removePositionWithAPR(uint256)
		RevvFiMarket._updateAPROnRemove(uint256,uint256)

src/RevvFiMarket.sol#L346-L352


 - [ ] ID-134
[RevvFiMarket._updateAPROnRemove(uint256,uint256)](src/RevvFiMarket.sol#L308-L316) has costly operations inside a loop:
	- [weightedAprNumeratorScaled = 0](src/RevvFiMarket.sol#L313)
	Calls stack containing the loop:
		RevvFiMarket.forceCloseMarket()
		RevvFiMarket._removePositionWithAPR(uint256)

src/RevvFiMarket.sol#L308-L316


 - [ ] ID-135
[RevvFiOfferBook._removeActive(uint256)](src/RevvFiOfferBook.sol#L225-L242) has costly operations inside a loop:
	- [delete _activeIndex[offerId]](src/RevvFiOfferBook.sol#L236)
	Calls stack containing the loop:
		RevvFiOfferBook.executeDrawdown(uint256,bool)

src/RevvFiOfferBook.sol#L225-L242


 - [ ] ID-136
[RevvFiOfferBook._removeActive(uint256)](src/RevvFiOfferBook.sol#L225-L242) has costly operations inside a loop:
	- [_activeIds.pop()](src/RevvFiOfferBook.sol#L234)
	Calls stack containing the loop:
		RevvFiOfferBook.executeDrawdown(uint256,bool)

src/RevvFiOfferBook.sol#L225-L242


 - [ ] ID-137
[RevvFiMarket._removePositionWithAPR(uint256)](src/RevvFiMarket.sol#L392-L404) has costly operations inside a loop:
	- [totalScaledPrincipal -= remainingScaled](src/RevvFiMarket.sol#L399)
	Calls stack containing the loop:
		RevvFiMarket.forceCloseMarket()

src/RevvFiMarket.sol#L392-L404


 - [ ] ID-138
[RevvFiMarket._updateAPROnAdd(uint256,uint256)](src/RevvFiMarket.sol#L298-L301) has costly operations inside a loop:
	- [weightedAprNumeratorScaled += scaledPrincipal * apr](src/RevvFiMarket.sol#L299)
	Calls stack containing the loop:
		RevvFiMarket.borrow(uint256,bool,uint256)
		RevvFiMarket._addActivePosition(uint256)

src/RevvFiMarket.sol#L298-L301


 - [ ] ID-139
[RevvFiOfferBook.cleanupExpiredOffers(uint256)](src/RevvFiOfferBook.sol#L354-L379) has costly operations inside a loop:
	- [totalLiquidity -= offer.remainingAmount](src/RevvFiOfferBook.sol#L368)

src/RevvFiOfferBook.sol#L354-L379


 - [ ] ID-140
[RevvFiOfferBook._removeActive(uint256)](src/RevvFiOfferBook.sol#L225-L242) has costly operations inside a loop:
	- [delete _activeIndex[offerId]](src/RevvFiOfferBook.sol#L236)
	Calls stack containing the loop:
		RevvFiOfferBook.cleanupExpiredOffers(uint256)

src/RevvFiOfferBook.sol#L225-L242


 - [ ] ID-141
[RevvFiMarket._removeActivePosition(uint256)](src/RevvFiMarket.sol#L374-L385) has costly operations inside a loop:
	- [activePositionIds.pop()](src/RevvFiMarket.sol#L381)
	Calls stack containing the loop:
		RevvFiMarket.repayFull()
		RevvFiMarket._removePositionWithAPR(uint256)

src/RevvFiMarket.sol#L374-L385


 - [ ] ID-142
[RevvFiMarket._removeActivePosition(uint256)](src/RevvFiMarket.sol#L374-L385) has costly operations inside a loop:
	- [activePositionIds.pop()](src/RevvFiMarket.sol#L381)
	Calls stack containing the loop:
		RevvFiMarket.forceCloseMarket()
		RevvFiMarket._removePositionWithAPR(uint256)

src/RevvFiMarket.sol#L374-L385


 - [ ] ID-143
[RevvFiMarket._removeActivePosition(uint256)](src/RevvFiMarket.sol#L374-L385) has costly operations inside a loop:
	- [delete activePositionIndex[positionId]](src/RevvFiMarket.sol#L383)
	Calls stack containing the loop:
		RevvFiMarket.forceCloseMarket()
		RevvFiMarket._removePositionWithAPR(uint256)

src/RevvFiMarket.sol#L374-L385


 - [ ] ID-144
[RevvFiMarket._updateWeightedAverageAPR()](src/RevvFiMarket.sol#L346-L352) has costly operations inside a loop:
	- [weightedAverageAPR = weightedAprNumeratorScaled / totalScaledPrincipal](src/RevvFiMarket.sol#L351)
	Calls stack containing the loop:
		RevvFiMarket.forceCloseMarket()
		RevvFiMarket._removePositionWithAPR(uint256)
		RevvFiMarket._updateAPROnRemove(uint256,uint256)

src/RevvFiMarket.sol#L346-L352


 - [ ] ID-145
[RevvFiMarket._updateWeightedAverageAPR()](src/RevvFiMarket.sol#L346-L352) has costly operations inside a loop:
	- [weightedAverageAPR = 0](src/RevvFiMarket.sol#L348)
	Calls stack containing the loop:
		RevvFiMarket.borrow(uint256,bool,uint256)
		RevvFiMarket._addActivePosition(uint256)
		RevvFiMarket._updateAPROnAdd(uint256,uint256)

src/RevvFiMarket.sol#L346-L352


 - [ ] ID-146
[RevvFiOfferBook.executeDrawdown(uint256,bool)](src/RevvFiOfferBook.sol#L476-L521) has costly operations inside a loop:
	- [totalLiquidity -= take](src/RevvFiOfferBook.sol#L497)

src/RevvFiOfferBook.sol#L476-L521


 - [ ] ID-147
[RevvFiOfferBook._removeActive(uint256)](src/RevvFiOfferBook.sol#L225-L242) has costly operations inside a loop:
	- [_activeIds.pop()](src/RevvFiOfferBook.sol#L234)
	Calls stack containing the loop:
		RevvFiOfferBook.cleanupExpiredOffers(uint256)

src/RevvFiOfferBook.sol#L225-L242


 - [ ] ID-148
[RevvFiMarket._updateWeightedAverageAPR()](src/RevvFiMarket.sol#L346-L352) has costly operations inside a loop:
	- [weightedAverageAPR = 0](src/RevvFiMarket.sol#L348)
	Calls stack containing the loop:
		RevvFiMarket.forceCloseMarket()
		RevvFiMarket._removePositionWithAPR(uint256)
		RevvFiMarket._updateAPROnRemove(uint256,uint256)

src/RevvFiMarket.sol#L346-L352


 - [ ] ID-149
[RevvFiMarket.borrow(uint256,bool,uint256)](src/RevvFiMarket.sol#L449-L515) has costly operations inside a loop:
	- [totalScaledPrincipal += scaledPrincipal](src/RevvFiMarket.sol#L500)

src/RevvFiMarket.sol#L449-L515


 - [ ] ID-150
[RevvFiOfferBook._removeActive(uint256)](src/RevvFiOfferBook.sol#L225-L242) has costly operations inside a loop:
	- [activeOfferCount --](src/RevvFiOfferBook.sol#L238)
	Calls stack containing the loop:
		RevvFiOfferBook.executeDrawdown(uint256,bool)

src/RevvFiOfferBook.sol#L225-L242


 - [ ] ID-151
[RevvFiMarket._updateAPROnRemove(uint256,uint256)](src/RevvFiMarket.sol#L308-L316) has costly operations inside a loop:
	- [weightedAprNumeratorScaled = 0](src/RevvFiMarket.sol#L313)
	Calls stack containing the loop:
		RevvFiMarket.repayFull()
		RevvFiMarket._removePositionWithAPR(uint256)

src/RevvFiMarket.sol#L308-L316


 - [ ] ID-152
[RevvFiMarket._updateWeightedAverageAPR()](src/RevvFiMarket.sol#L346-L352) has costly operations inside a loop:
	- [weightedAverageAPR = 0](src/RevvFiMarket.sol#L348)
	Calls stack containing the loop:
		RevvFiMarket.repayFull()
		RevvFiMarket._removePositionWithAPR(uint256)
		RevvFiMarket._updateAPROnRemove(uint256,uint256)

src/RevvFiMarket.sol#L346-L352


 - [ ] ID-153
[RevvFiMarket._updateWeightedAverageAPR()](src/RevvFiMarket.sol#L346-L352) has costly operations inside a loop:
	- [weightedAverageAPR = weightedAprNumeratorScaled / totalScaledPrincipal](src/RevvFiMarket.sol#L351)
	Calls stack containing the loop:
		RevvFiMarket.borrow(uint256,bool,uint256)
		RevvFiMarket._addActivePosition(uint256)
		RevvFiMarket._updateAPROnAdd(uint256,uint256)

src/RevvFiMarket.sol#L346-L352


 - [ ] ID-154
[RevvFiOfferBook._removeActive(uint256)](src/RevvFiOfferBook.sol#L225-L242) has costly operations inside a loop:
	- [activeOfferCount --](src/RevvFiOfferBook.sol#L238)
	Calls stack containing the loop:
		RevvFiOfferBook.cleanupExpiredOffers(uint256)

src/RevvFiOfferBook.sol#L225-L242


 - [ ] ID-155
[RevvFiMarket._removeActivePosition(uint256)](src/RevvFiMarket.sol#L374-L385) has costly operations inside a loop:
	- [delete activePositionIndex[positionId]](src/RevvFiMarket.sol#L383)
	Calls stack containing the loop:
		RevvFiMarket.repayFull()
		RevvFiMarket._removePositionWithAPR(uint256)

src/RevvFiMarket.sol#L374-L385


 - [ ] ID-156
[RevvFiMarket._removePositionWithAPR(uint256)](src/RevvFiMarket.sol#L392-L404) has costly operations inside a loop:
	- [totalScaledPrincipal -= remainingScaled](src/RevvFiMarket.sol#L399)
	Calls stack containing the loop:
		RevvFiMarket.repayFull()

src/RevvFiMarket.sol#L392-L404


## dead-code
Impact: Informational
Confidence: Medium
 - [ ] ID-157
[RevvFiMarket._getPositionDebt(uint256)](src/RevvFiMarket.sol#L266-L270) is never used and should be removed

src/RevvFiMarket.sol#L266-L270


## solc-version
Impact: Informational
Confidence: High
 - [ ] ID-158
Version constraint ^0.8.1 contains known severe issues (https://solidity.readthedocs.io/en/latest/bugs.html)
	- FullInlinerNonExpressionSplitArgumentEvaluationOrder
	- MissingSideEffectsOnSelectorAccess
	- AbiReencodingHeadOverflowWithStaticArrayCleanup
	- DirtyBytesArrayToStorage
	- DataLocationChangeInInternalOverride
	- NestedCalldataArrayAbiReencodingSizeValidation
	- SignedImmutables
	- ABIDecodeTwoDimensionalArrayMemory
	- KeccakCaching.
It is used by:
	- [^0.8.1](lib/openzeppelin-contracts-upgradeable/contracts/utils/AddressUpgradeable.sol#L4)

lib/openzeppelin-contracts-upgradeable/contracts/utils/AddressUpgradeable.sol#L4


 - [ ] ID-159
Version constraint ^0.8.2 contains known severe issues (https://solidity.readthedocs.io/en/latest/bugs.html)
	- FullInlinerNonExpressionSplitArgumentEvaluationOrder
	- MissingSideEffectsOnSelectorAccess
	- AbiReencodingHeadOverflowWithStaticArrayCleanup
	- DirtyBytesArrayToStorage
	- DataLocationChangeInInternalOverride
	- NestedCalldataArrayAbiReencodingSizeValidation
	- SignedImmutables
	- ABIDecodeTwoDimensionalArrayMemory
	- KeccakCaching.
It is used by:
	- [^0.8.2](lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol#L4)

lib/openzeppelin-contracts-upgradeable/contracts/proxy/utils/Initializable.sol#L4


 - [ ] ID-160
Version constraint ^0.8.20 contains known severe issues (https://solidity.readthedocs.io/en/latest/bugs.html)
	- VerbatimInvalidDeduplication
	- FullInlinerNonExpressionSplitArgumentEvaluationOrder
	- MissingSideEffectsOnSelectorAccess.
It is used by:
	- [^0.8.20](lib/openzeppelin-contracts/contracts/access/Ownable.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/interfaces/draft-IERC6093.sol#L3)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/proxy/Clones.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Permit.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/token/ERC721/ERC721.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/token/ERC721/IERC721.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/token/ERC721/IERC721Receiver.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/token/ERC721/extensions/ERC721Enumerable.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/token/ERC721/extensions/IERC721Enumerable.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/token/ERC721/extensions/IERC721Metadata.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/utils/Address.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/utils/Context.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/utils/Strings.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/utils/introspection/ERC165.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/utils/introspection/IERC165.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/utils/math/Math.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/utils/math/SignedMath.sol#L4)
	- [^0.8.20](lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol#L5)

lib/openzeppelin-contracts/contracts/access/Ownable.sol#L4


## low-level-calls
Impact: Informational
Confidence: High
 - [ ] ID-161
Low level call in [Address.functionStaticCall(address,bytes)](lib/openzeppelin-contracts/contracts/utils/Address.sol#L95-L98):
	- [(success,returndata) = target.staticcall(data)](lib/openzeppelin-contracts/contracts/utils/Address.sol#L96)

lib/openzeppelin-contracts/contracts/utils/Address.sol#L95-L98


 - [ ] ID-162
Low level call in [Address.functionDelegateCall(address,bytes)](lib/openzeppelin-contracts/contracts/utils/Address.sol#L104-L107):
	- [(success,returndata) = target.delegatecall(data)](lib/openzeppelin-contracts/contracts/utils/Address.sol#L105)

lib/openzeppelin-contracts/contracts/utils/Address.sol#L104-L107


 - [ ] ID-163
Low level call in [RevvFiFactory.deployMarket(address,address,address,address,uint8,uint8,uint256,uint256)](src/RevvFiFactory.sol#L214-L290):
	- [(feeSent,None) = feeRecipient.call{value: deploymentFee}()](src/RevvFiFactory.sol#L236)

src/RevvFiFactory.sol#L214-L290


 - [ ] ID-164
Low level call in [AddressUpgradeable.functionStaticCall(address,bytes,string)](lib/openzeppelin-contracts-upgradeable/contracts/utils/AddressUpgradeable.sol#L155-L162):
	- [(success,returndata) = target.staticcall(data)](lib/openzeppelin-contracts-upgradeable/contracts/utils/AddressUpgradeable.sol#L160)

lib/openzeppelin-contracts-upgradeable/contracts/utils/AddressUpgradeable.sol#L155-L162


 - [ ] ID-165
Low level call in [AddressUpgradeable.functionCallWithValue(address,bytes,uint256,string)](lib/openzeppelin-contracts-upgradeable/contracts/utils/AddressUpgradeable.sol#L128-L137):
	- [(success,returndata) = target.call{value: value}(data)](lib/openzeppelin-contracts-upgradeable/contracts/utils/AddressUpgradeable.sol#L135)

lib/openzeppelin-contracts-upgradeable/contracts/utils/AddressUpgradeable.sol#L128-L137


 - [ ] ID-166
Low level call in [AddressUpgradeable.functionDelegateCall(address,bytes,string)](lib/openzeppelin-contracts-upgradeable/contracts/utils/AddressUpgradeable.sol#L180-L187):
	- [(success,returndata) = target.delegatecall(data)](lib/openzeppelin-contracts-upgradeable/contracts/utils/AddressUpgradeable.sol#L185)

lib/openzeppelin-contracts-upgradeable/contracts/utils/AddressUpgradeable.sol#L180-L187


 - [ ] ID-167
Low level call in [SafeERC20._callOptionalReturnBool(IERC20,bytes)](lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol#L110-L117):
	- [(success,returndata) = address(token).call(data)](lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol#L115)

lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol#L110-L117


 - [ ] ID-168
Low level call in [Address.sendValue(address,uint256)](lib/openzeppelin-contracts/contracts/utils/Address.sol#L41-L50):
	- [(success,None) = recipient.call{value: amount}()](lib/openzeppelin-contracts/contracts/utils/Address.sol#L46)

lib/openzeppelin-contracts/contracts/utils/Address.sol#L41-L50


 - [ ] ID-169
Low level call in [AddressUpgradeable.sendValue(address,uint256)](lib/openzeppelin-contracts-upgradeable/contracts/utils/AddressUpgradeable.sol#L64-L69):
	- [(success,None) = recipient.call{value: amount}()](lib/openzeppelin-contracts-upgradeable/contracts/utils/AddressUpgradeable.sol#L67)

lib/openzeppelin-contracts-upgradeable/contracts/utils/AddressUpgradeable.sol#L64-L69


 - [ ] ID-170
Low level call in [Address.functionCallWithValue(address,bytes,uint256)](lib/openzeppelin-contracts/contracts/utils/Address.sol#L83-L89):
	- [(success,returndata) = target.call{value: value}(data)](lib/openzeppelin-contracts/contracts/utils/Address.sol#L87)

lib/openzeppelin-contracts/contracts/utils/Address.sol#L83-L89


## missing-inheritance
Impact: Informational
Confidence: High
 - [ ] ID-171
[RevvFiPositionNFT](src/RevvFiPositionNFT.sol#L16-L319) should inherit from [IRevvFiPositionNFT](src/interfaces/IRevvFiPositionNFT.sol#L4-L27)

src/RevvFiPositionNFT.sol#L16-L319


 - [ ] ID-172
[RevvFiArchController](src/RevvFiArchController.sol#L21-L413) should inherit from [IRevvFiArchController](src/interfaces/IRevvFiArchController.sol#L4-L39)

src/RevvFiArchController.sol#L21-L413


 - [ ] ID-173
[RevvFiLiquidityQueue](src/RevvFiLiquidityQueue.sol#L18-L381) should inherit from [IRevvFiLiquidityQueue](src/interfaces/IRevvFiLiquidityQueue.sol#L4-L45)

src/RevvFiLiquidityQueue.sol#L18-L381


 - [ ] ID-174
[RevvFiOfferBook](src/RevvFiOfferBook.sol#L18-L573) should inherit from [IRevvFiOfferBook](src/interfaces/IRevvFiOfferBook.sol#L4-L37)

src/RevvFiOfferBook.sol#L18-L573


## naming-convention
Impact: Informational
Confidence: High
 - [ ] ID-175
Parameter [RevvFiFactory.setCoreContracts(address,address,address,address)._reputationRegistry](src/RevvFiFactory.sol#L161) is not in mixedCase

src/RevvFiFactory.sol#L161


 - [ ] ID-176
Parameter [RevvFiLiquidityQueue.initialize(address,address,address)._factory](src/RevvFiLiquidityQueue.sol#L112) is not in mixedCase

src/RevvFiLiquidityQueue.sol#L112


 - [ ] ID-177
Parameter [RevvFiFactory.setCoreContracts(address,address,address,address)._archController](src/RevvFiFactory.sol#L158) is not in mixedCase

src/RevvFiFactory.sol#L158


 - [ ] ID-178
Parameter [RevvFiOfferBook.initialize(address,address,address)._borrowAsset](src/RevvFiOfferBook.sol#L119) is not in mixedCase

src/RevvFiOfferBook.sol#L119


 - [ ] ID-179
Parameter [RevvFiCollateralEscrow.initialize(address,address,address,address,address,address,uint8,uint8)._borrowDecimals](src/RevvFiCollateralEscrow.sol#L135) is not in mixedCase

src/RevvFiCollateralEscrow.sol#L135


 - [ ] ID-180
Parameter [RevvFiLiquidityQueue.initialize(address,address,address)._positionNFT](src/RevvFiLiquidityQueue.sol#L112) is not in mixedCase

src/RevvFiLiquidityQueue.sol#L112


 - [ ] ID-181
Parameter [RevvFiMarket.setContracts(address,address,address,address,address)._liquidator](src/RevvFiMarket.sol#L194) is not in mixedCase

src/RevvFiMarket.sol#L194


 - [ ] ID-182
Parameter [RevvFiLiquidityQueue.initialize(address,address,address)._market](src/RevvFiLiquidityQueue.sol#L112) is not in mixedCase

src/RevvFiLiquidityQueue.sol#L112


 - [ ] ID-183
Parameter [RevvFiCollateralEscrow.initialize(address,address,address,address,address,address,uint8,uint8)._market](src/RevvFiCollateralEscrow.sol#L129) is not in mixedCase

src/RevvFiCollateralEscrow.sol#L129


 - [ ] ID-184
Parameter [RevvFiMarket.setContracts(address,address,address,address,address)._positionNFT](src/RevvFiMarket.sol#L193) is not in mixedCase

src/RevvFiMarket.sol#L193


 - [ ] ID-185
Parameter [RevvFiMarket.initialize(address,address,address,address,address)._collateralAsset](src/RevvFiMarket.sol#L162) is not in mixedCase

src/RevvFiMarket.sol#L162


 - [ ] ID-186
Parameter [RevvFiFactory.setCoreContracts(address,address,address,address)._positionNFT](src/RevvFiFactory.sol#L159) is not in mixedCase

src/RevvFiFactory.sol#L159


 - [ ] ID-187
Parameter [RevvFiCollateralEscrow.initialize(address,address,address,address,address,address,uint8,uint8)._factory](src/RevvFiCollateralEscrow.sol#L128) is not in mixedCase

src/RevvFiCollateralEscrow.sol#L128


 - [ ] ID-188
Parameter [RevvFiCollateralEscrow.initialize(address,address,address,address,address,address,uint8,uint8)._collateralOracle](src/RevvFiCollateralEscrow.sol#L133) is not in mixedCase

src/RevvFiCollateralEscrow.sol#L133


 - [ ] ID-189
Parameter [RevvFiMarket.setContracts(address,address,address,address,address)._collateralEscrow](src/RevvFiMarket.sol#L191) is not in mixedCase

src/RevvFiMarket.sol#L191


 - [ ] ID-190
Function [IERC20Permit.DOMAIN_SEPARATOR()](lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Permit.sol#L89) is not in mixedCase

lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Permit.sol#L89


 - [ ] ID-191
Parameter [RevvFiMarket.initialize(address,address,address,address,address)._archController](src/RevvFiMarket.sol#L159) is not in mixedCase

src/RevvFiMarket.sol#L159


 - [ ] ID-192
Parameter [RevvFiCollateralEscrow.initialize(address,address,address,address,address,address,uint8,uint8)._collateralDecimals](src/RevvFiCollateralEscrow.sol#L134) is not in mixedCase

src/RevvFiCollateralEscrow.sol#L134


 - [ ] ID-193
Parameter [RevvFiCollateralEscrow.initialize(address,address,address,address,address,address,uint8,uint8)._borrower](src/RevvFiCollateralEscrow.sol#L130) is not in mixedCase

src/RevvFiCollateralEscrow.sol#L130


 - [ ] ID-194
Parameter [RevvFiFactory.setCoreContracts(address,address,address,address)._liquidator](src/RevvFiFactory.sol#L160) is not in mixedCase

src/RevvFiFactory.sol#L160


 - [ ] ID-195
Parameter [RevvFiMarket.setContracts(address,address,address,address,address)._reputationRegistry](src/RevvFiMarket.sol#L195) is not in mixedCase

src/RevvFiMarket.sol#L195


 - [ ] ID-196
Parameter [RevvFiCollateralEscrow.initialize(address,address,address,address,address,address,uint8,uint8)._borrowAsset](src/RevvFiCollateralEscrow.sol#L131) is not in mixedCase

src/RevvFiCollateralEscrow.sol#L131


 - [ ] ID-197
Parameter [RevvFiOfferBook.initialize(address,address,address)._market](src/RevvFiOfferBook.sol#L119) is not in mixedCase

src/RevvFiOfferBook.sol#L119


 - [ ] ID-198
Parameter [RevvFiMarket.initialize(address,address,address,address,address)._borrower](src/RevvFiMarket.sol#L160) is not in mixedCase

src/RevvFiMarket.sol#L160


 - [ ] ID-199
Parameter [RevvFiMarket.initialize(address,address,address,address,address)._borrowAsset](src/RevvFiMarket.sol#L161) is not in mixedCase

src/RevvFiMarket.sol#L161


 - [ ] ID-200
Parameter [RevvFiMarket.initialize(address,address,address,address,address)._factory](src/RevvFiMarket.sol#L158) is not in mixedCase

src/RevvFiMarket.sol#L158


 - [ ] ID-201
Parameter [RevvFiMarket.setContracts(address,address,address,address,address)._offerBook](src/RevvFiMarket.sol#L192) is not in mixedCase

src/RevvFiMarket.sol#L192


 - [ ] ID-202
Parameter [RevvFiCollateralEscrow.initialize(address,address,address,address,address,address,uint8,uint8)._collateralAsset](src/RevvFiCollateralEscrow.sol#L132) is not in mixedCase

src/RevvFiCollateralEscrow.sol#L132


 - [ ] ID-203
Parameter [RevvFiOfferBook.initialize(address,address,address)._factory](src/RevvFiOfferBook.sol#L119) is not in mixedCase

src/RevvFiOfferBook.sol#L119


## too-many-digits
Impact: Informational
Confidence: Medium
 - [ ] ID-204
[Clones.cloneDeterministic(address,bytes32)](lib/openzeppelin-contracts/contracts/proxy/Clones.sol#L50-L63) uses literals with too many digits:
	- [mstore(uint256,uint256)(0x00,implementation << 0x60 >> 0xe8 | 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000)](lib/openzeppelin-contracts/contracts/proxy/Clones.sol#L55)

lib/openzeppelin-contracts/contracts/proxy/Clones.sol#L50-L63


 - [ ] ID-205
[Clones.clone(address)](lib/openzeppelin-contracts/contracts/proxy/Clones.sol#L28-L41) uses literals with too many digits:
	- [mstore(uint256,uint256)(0x00,implementation << 0x60 >> 0xe8 | 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000)](lib/openzeppelin-contracts/contracts/proxy/Clones.sol#L33)

lib/openzeppelin-contracts/contracts/proxy/Clones.sol#L28-L41


## unindexed-event-address
Impact: Informational
Confidence: High
 - [ ] ID-206
Event [RevvFiFactory.ImplementationsSet(address,address,address,address)](src/RevvFiFactory.sol#L109) has address parameters but no indexed parameters

src/RevvFiFactory.sol#L109


 - [ ] ID-207
Event [RevvFiEvents.ControllerRemoved(address)](src/libraries/RevvFiEvents.sol#L18) has address parameters but no indexed parameters

src/libraries/RevvFiEvents.sol#L18


 - [ ] ID-208
Event [RevvFiEvents.AssetPermitted(address)](src/libraries/RevvFiEvents.sol#L16) has address parameters but no indexed parameters

src/libraries/RevvFiEvents.sol#L16


 - [ ] ID-209
Event [RevvFiEvents.AssetBlacklisted(address)](src/libraries/RevvFiEvents.sol#L15) has address parameters but no indexed parameters

src/libraries/RevvFiEvents.sol#L15


 - [ ] ID-210
Event [RevvFiEvents.MarketRemoved(address)](src/libraries/RevvFiEvents.sol#L10) has address parameters but no indexed parameters

src/libraries/RevvFiEvents.sol#L10


 - [ ] ID-211
Event [RevvFiEvents.ControllerFactoryRemoved(address)](src/libraries/RevvFiEvents.sol#L12) has address parameters but no indexed parameters

src/libraries/RevvFiEvents.sol#L12


 - [ ] ID-212
Event [RevvFiFactory.CoreContractsSet(address,address,address,address)](src/RevvFiFactory.sol#L108) has address parameters but no indexed parameters

src/RevvFiFactory.sol#L108


 - [ ] ID-213
Event [RevvFiEvents.BorrowerRemoved(address)](src/libraries/RevvFiEvents.sol#L14) has address parameters but no indexed parameters

src/libraries/RevvFiEvents.sol#L14


 - [ ] ID-214
Event [RevvFiEvents.ControllerFactoryAdded(address)](src/libraries/RevvFiEvents.sol#L11) has address parameters but no indexed parameters

src/libraries/RevvFiEvents.sol#L11


 - [ ] ID-215
Event [RevvFiEvents.BorrowerAdded(address)](src/libraries/RevvFiEvents.sol#L13) has address parameters but no indexed parameters

src/libraries/RevvFiEvents.sol#L13


## cache-array-length
Impact: Optimization
Confidence: High
 - [ ] ID-216
Loop condition [i < aprValues.length](src/RevvFiOfferBook.sol#L398) should use cached array length instead of referencing `length` member of the storage array.
 
src/RevvFiOfferBook.sol#L398


