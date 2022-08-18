;;ERROR CODES
(define-constant err-not-contract-owner (err u100))
(define-constant err-untrusted-oracle (err u101))
(define-constant err-stale-data (err u102))
(define-constant err-unauthorised (err u2001))
(define-constant err-dlc-already-added (err u2002))
(define-constant err-unknown-dlc (err u2003))
(define-constant err-not-reached-closing-time (err u2004))
(define-constant err-already-closed (err u2005))
(define-constant err-already-passed-closing-time (err u2006))
(define-constant err-not-closed (err u2007))
(define-constant err-not-the-same-assets (err u2008))
(define-constant err-does-not-need-liquidation (err u3000))

(define-constant value-shift u100000000)
(define-constant value-shift-squared u10000000000000000)

;; Contract owner
(define-constant contract-owner tx-sender)

;; Current contract's name
(define-constant dlc-manager-contract .dlc-manager-pricefeed-v2-01)

;; Importing the trait to use it as a type
(use-trait cb-trait .dlc-link-callback-trait.dlc-link-callback-trait)

;; A map of all trusted oracles, indexed by their 33 byte compressed public key.
(define-map trusted-oracles (buff 33) bool)

;; NFT to keep track of the open dlcs easily
(define-non-fungible-token open-dlc (buff 8))

;; NFT to keep track of registered contracts
(define-non-fungible-token registered-contract principal)


(define-map dlcs
  (buff 8)
  {
    uuid: (buff 8),
    vault-loan-amount: uint,
    liquidation-ratio: uint,
    liquidation-fee: uint,
    strike-price: uint,
    btc-deposit: uint,
    closing-price: (optional uint), ;; none means it is still open
    actual-closing-time: uint,
    emergency-refund-time: uint,
    creator: principal
  })

(define-read-only (get-last-block-timestamp)
  (default-to u0 (get-block-info? time (- block-height u1))))

(define-read-only (get-dlc (uuid (buff 8)))
  (map-get? dlcs uuid))

;;emits an event - see README for more details
;;vault-loan-amount : the borrowed USDA amount in the vault
;;btc-deposit : the deposited BTC amount, in Sats (shifted by 10**8)
;;liquidation-ratio: e.g. 140
;;liquidation-fee : e.g. 10
;;emergency-refund-time: the time at which the DLC will be available for refund
;;callback-contract: the contract-principal where the create-dlc-internal will call back to
;;nonce provided for the dlc by the sample-protocol-contract to connect it to the resulting uuid
(define-public (create-dlc (vault-loan-amount uint) (btc-deposit uint) (liquidation-ratio uint) (liquidation-fee uint) (emergency-refund-time uint) (callback-contract principal) (nonce uint))
  (let (
    (strike-price (/ (* vault-loan-amount liquidation-ratio) u100))
    ) 
    (begin
      (asserts! (is-eq callback-contract tx-sender) err-unauthorised)
      (print {
        vault-loan-amount: vault-loan-amount, 
        btc-deposit: btc-deposit,
        liquidation-ratio: liquidation-ratio,
        liquidation-fee: liquidation-fee,
        strike-price: strike-price,
        emergency-refund-time: emergency-refund-time,
        creator: tx-sender,
        callback-contract: callback-contract,
        nonce: nonce,
        event-source: "dlclink:create-dlc:v2" 
      })
      (ok true)
    )
  ) 
)

;;opens a new dlc - called by the DLC Oracle system
(define-public (create-dlc-internal (uuid (buff 8)) (vault-loan-amount uint) (btc-deposit uint) (liquidation-ratio uint) (liquidation-fee uint) (strike-price uint) (emergency-refund-time uint) (creator principal) (callback-contract <cb-trait>) (nonce uint))
  (begin
    (asserts! (is-eq contract-owner tx-sender) err-unauthorised)
    (asserts! (is-none (map-get? dlcs uuid)) err-dlc-already-added)
    (map-set dlcs uuid {
      uuid: uuid, 
      vault-loan-amount: vault-loan-amount,
      liquidation-ratio: liquidation-ratio,
      liquidation-fee: liquidation-fee,
      strike-price: strike-price,
      btc-deposit: btc-deposit,
      closing-price: none, 
      actual-closing-time: u0, 
      emergency-refund-time: emergency-refund-time,
      creator: creator })
    (print {
      uuid: uuid, 
      vault-loan-amount: vault-loan-amount, 
      liquidation-ratio: liquidation-ratio,
      liquidation-fee: liquidation-fee,
      strike-price: strike-price,
      btc-deposit: btc-deposit,
      emergency-refund-time: emergency-refund-time,
      creator: creator,
      event-source: "dlclink:create-dlc-internal:v2" 
    })
    (try! (contract-call? callback-contract post-create-dlc-handler nonce uuid))
    (nft-mint? open-dlc uuid dlc-manager-contract))) ;;mint an open-dlc nft to keep track of open dlcs

;; Regular, repaid loan closing 
(define-public (close-dlc (uuid (buff 8)))
  (let (
      (dlc (unwrap! (get-dlc uuid) err-unknown-dlc))
    )
    (asserts! (or (is-eq contract-owner tx-sender) (is-eq (get creator dlc) tx-sender)) err-unauthorised)
    (asserts! (is-none (get closing-price dlc)) err-already-closed)
    (print { 
      uuid: uuid, 
      vault-loan-amount: (get vault-loan-amount dlc),
      event-source: "dlclink:close-dlc:v2"
      })
    (ok true)
  ))

;; Liquidating close request
(define-public (close-dlc-liquidate (uuid (buff 8))) 
  (let (
    (dlc (unwrap! (get-dlc uuid) err-unknown-dlc))
    )
    ;; (asserts! (or (is-eq contract-owner tx-sender) (is-eq (get creator dlc) tx-sender)) err-unauthorised)
    (asserts! (is-none (get closing-price dlc)) err-already-closed)
    (print { 
      uuid: uuid, 
      vault-loan-amount: (get vault-loan-amount dlc),
      liquidation-ratio: (get liquidation-ratio dlc),
      caller: tx-sender,
      event-source: "dlclink:early-close-dlc:v2" 
      })
    (ok true)
  ))

;;Close the dlc with the oracle data. This is called by the DLC Oracle service
;; TODO: call back to the closecallback
;; TODO: check if liquidation should happen
(define-public (close-dlc-internal (uuid (buff 8)) (timestamp uint) (entries (list 10 {symbol: (buff 32), value: uint})) (signature (buff 65)))
  (let (
    ;; Recover the pubkey of the signer.
    (signer (try! (contract-call? 'STDBEG5X8XD50SPM1JJH0E5CTXGDV5NJTJTTH7YB.redstone-verify recover-signer timestamp entries signature)))
    (dlc (unwrap! (get-dlc uuid) err-unknown-dlc))
    (block-timestamp (get-last-block-timestamp))
    )
    (asserts! (is-eq contract-owner tx-sender) err-unauthorised)
    ;; Check if the signer is a trusted oracle.
    (asserts! (is-trusted-oracle signer) err-untrusted-oracle)
    ;; Check if the data is not stale, depending on how the app is designed.
    (asserts! (> timestamp block-timestamp) err-stale-data) ;; timestamp should be larger than the last block timestamp.
    ;;DLC related checks
    ;; (asserts! (is-eq (unwrap-panic (get symbol (element-at entries u0))) (get asset dlc)) err-not-the-same-assets) ;;check if the submitted asset is the same what was logged in the DLC
    (asserts! (is-none (get closing-price dlc)) err-already-closed)
    (map-set dlcs uuid (merge dlc { closing-price: (get value (element-at entries u0)), actual-closing-time: (/ timestamp u1000) })) ;;timestamp is in milliseconds so we have to convert it to seconds to keep the timestamps consistent
    (print {
      uuid: uuid,
      closing-price: (get value (element-at entries u0)),
      ;; TODO: print payout-ratio
      actual-closing-time: (/ timestamp u1000),
      event-source: "dlclink:close-dlc-internal:v2" })
    (nft-burn? open-dlc uuid dlc-manager-contract))) ;;burn the open-dlc nft related to the UUID

;;Checks if a given DLC needs liquidation at the given btc-price (shifted by 10**8)
(define-read-only (check-liquidation (uuid (buff 8)) (btc-price uint)) 
  (let (
    (dlc (unwrap! (get-dlc uuid) err-unknown-dlc))
    (collateral-value (get-collateral-value (get btc-deposit dlc) btc-price))
    )
    (ok (<= collateral-value (get strike-price dlc)))
  )
)

;; TODO: return back to read-only
;; Return the resulting payout-curve-value at the given btc-price (shifted by 10**8)
;; using uints, this means return values between 0-10000000000
(define-public (get-payout-curve-value (uuid (buff 8)) (btc-price uint))
  (let (
    (dlc (unwrap! (get-dlc uuid) err-unknown-dlc))
    (collateral-value (get-collateral-value (get btc-deposit dlc) btc-price))
    (sell-to-liquidators-ratio (/ (shift-value (shift-value (get vault-loan-amount dlc))) collateral-value))

    ;; (to-protocol (* sell-to-liquidators-ratio (unshift-value (get btc-deposit dlc))))
    ;; (total-to-protocol (+ to-protocol (* (/ to-protocol u100) (get liquidation-fee dlc))))
    ;; (to-user (- (unshift-value (get btc-deposit dlc)) total-to-protocol))
    
    (payout-curve-value (* sell-to-liquidators-ratio (+ u100 (get liquidation-fee dlc))))
    (payout-curve-unshifted (unshift-value payout-curve-value))
    
    )
    (begin 
      (print {
        collateral-value: collateral-value,
        sell-to-liquidators-ratio: sell-to-liquidators-ratio,
        ;; to-protocol: to-protocol,
        ;; total-to-protocol: total-to-protocol,
        ;; to-user: to-user,
        payout-curve-unshifted: payout-curve-unshifted })

      (if (<= collateral-value (get strike-price dlc))
          (if (>= payout-curve-unshifted (shift-value u100)) 
            (ok (shift-value u100)) 
            (ok payout-curve-unshifted))
        (ok u0)
      )  
    )
  )
)

;; FOR TESTING, TODO: REMOVE BEFORE PRODUCTION
(define-public (add-dlc (uuid (buff 8)) (vault-loan-amount uint) (btc-deposit uint) (liquidation-ratio uint) (liquidation-fee uint) (strike-price uint) (emergency-refund-time uint)) 
  (begin (map-set dlcs uuid {
      uuid: uuid, 
      vault-loan-amount: vault-loan-amount,
      liquidation-ratio: liquidation-ratio,
      liquidation-fee: liquidation-fee,
      strike-price: strike-price,
      btc-deposit: btc-deposit,
      closing-price: none, 
      actual-closing-time: u0, 
      emergency-refund-time: u0,
      creator: tx-sender }) 
    (ok true)
  )
)

(define-private (get-collateral-value (btc-deposit uint) (btc-price uint))
  (/ (* btc-deposit btc-price) value-shift-squared)
)

(define-private (shift-value (value uint))
  (* value value-shift)
)

(define-private (unshift-value (value uint))
  (/ value value-shift)
)

;; get the closing price of the DLC by UUID
;; (define-read-only (get-dlc-closing-price-and-time (uuid (buff 8)))
;; (let (
;;     (dlc (unwrap! (get-dlc uuid) err-unknown-dlc))
;;     )
;;     (asserts! (is-some (get closing-price dlc)) err-not-closed)
;;     (ok {
;;       closing-price: (get closing-price dlc),
;;       closing-time: (get closing-time dlc)
;;     })))


(define-read-only (is-trusted-oracle (pubkey (buff 33)))
  (default-to false (map-get? trusted-oracles pubkey))
)

;; #[allow(unchecked_data)]
(define-public (set-trusted-oracle (pubkey (buff 33)) (trusted bool))
  (begin
    (asserts! (is-eq contract-owner tx-sender) err-not-contract-owner)
    (ok (map-set trusted-oracles pubkey trusted))
  )
)

;; Admin function to register a protocol/user-contract
;; This is picked up by the Observer infrastructure to start listening to contract-calls of our public functions.
(define-public (register-contract (contract-address <cb-trait>))
  (begin
    (asserts! (is-eq contract-owner tx-sender) err-not-contract-owner)
    (print { 
      contract-address: contract-address,
      event-source: "dlclink:register-contract:v2" })
    (nft-mint? registered-contract (contract-of contract-address) dlc-manager-contract)
  )
)

(define-public (unregister-contract (contract-address <cb-trait>))
  (begin
    (asserts! (is-eq contract-owner tx-sender) err-not-contract-owner)
    (print { 
      contract-address: contract-address,
      event-source: "dlclink:unregister-contract:v2" })
    (nft-burn? registered-contract (contract-of contract-address) dlc-manager-contract)
  )
)

(define-read-only (is-contract-registered (contract-address principal))
  (is-some (nft-get-owner? registered-contract contract-address))
)
